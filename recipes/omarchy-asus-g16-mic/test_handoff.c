/* SPDX-License-Identifier: MIT */
/* test_handoff.c: the capture -> outputs hand-off (handoff.c) on a simulated
 * graph schedule, with a real engine (uncalibrated omni, 2 channels) and
 * synthetic signals only (speech-like noise, -40 dBFS tone bursts, sample
 * markers); no PipeWire.
 *
 * RED -> GREEN, two baselines:
 *   - the scenarios of the original fix run through two hand-offs at once,
 *     fed the same input and the same schedule: a faithful model of the
 *     two-slot same-cycle hand-off the queue replaced (capture_process /
 *     out_process / retire_engine of the host before it: the capture fills
 *     slot[seq & 1], an output takes the newest slot, a cycle it never saw
 *     (s - last_seq > 1) is lost, a slot rewritten during the copy
 *     (wseq >= s + 2) is torn, the engine tail is never flushed), and
 *     g16mic_handoff. Each prints "RED (old hand-off): lost N" and
 *     "GREEN (queue): lost M" and checks both;
 *   - the exact-quantum cases (a) to (g) fail on round 1's catch-up queue
 *     (several whole cycles in one output buffer, the newest cycle dropped
 *     at overflow, no read position inside an entry, no eos_pad, no
 *     drained()); each case says what that queue did instead;
 *   - (j) to (o) fail on round 2's queue: a late listener PipeWire first
 *     ran before the capture stayed a cycle behind for good, and nothing
 *     ever brought added latency back (no latency trim, no
 *     latency_trimmed counter).
 *   - (p) guards the round-4 threshold finding: quiet speech at the live
 *     test's step-10 level (test_pw_helper --quiet, peak 0.1 * 2^-5 =
 *     0.003125, about -50 dBFS) is never trimmed, even one sample of it in
 *     an otherwise -80 dBFS cycle, while -66 dBFS noise is. It fails if the
 *     quiet threshold is raised to that level (e.g. 0.004).
 *
 * Every output buffer must carry exactly the requested quantum: PipeWire's
 * output adapter keeps the rest of a larger buffer hidden, so audio the
 * queue counted as delivered would sit outside every counter.
 *
 * Schedule letters (sim_sched): C capture cycle, P processed output runs,
 * R raw output runs, T both output triggers refused (-EBUSY), S stop.
 */
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"
#include "g16mic_handoff.h"
#include "test_util.h"
#include "test_signals.h"

#define RATE G16MIC_RATE
#define Q 1024                /* the simulated graph quantum, frames */
#define CH 2                  /* capture channels */
#define DST_MAX 4096          /* an output buffer, frames */
#define OUT_P G16MIC_HF_PROCESSED
#define OUT_R G16MIC_HF_RAW
#define STREAM_CAP (128 * Q)  /* frames a test stream can collect */

static const int och[G16MIC_HF_NOUT] = { 1, CH };

static g16mic_engine *make_engine(void)
{
	g16mic_params p;

	g16mic_params_default(&p);
	p.mode = G16MIC_MODE_OMNI;
	g16mic_engine *e = g16mic_engine_create(CH, RATE, NULL, G16MIC_CAL_MISSING, &p);
	if (!e) {
		fprintf(stderr, "engine create failed\n");
		exit(1);
	}
	return e;
}

/* ---- the old two-slot hand-off (the host before the queue) --------------- */

#define OLD_SCRATCH 8192

struct old_slot {
	float mono[OLD_SCRATCH];
	float raw[OLD_SCRATCH * CH];
	size_t frames;
	int channels;
};

struct old_out {
	int active, resync, ch, is_raw;
	uint64_t last_seq;
};

struct old_hf {
	struct old_slot slot[2];
	uint64_t seq, wseq;
	struct old_out out[G16MIC_HF_NOUT];
	/* overflow: everything the old host counted as lost (ring_overflow);
	 * the parts: skipped cycles, torn copies, the unflushed tail */
	uint64_t overflow, underflow, skipped, torn, tail_lost;
};

static void old_init(struct old_hf *o)
{
	memset(o, 0, sizeof *o);
	o->out[OUT_P] = (struct old_out){ .active = 1, .resync = 1, .ch = 1, .is_raw = 0 };
	o->out[OUT_R] = (struct old_out){ .active = 1, .resync = 1, .ch = CH, .is_raw = 1 };
}

/* capture_process: fill the slot of the next sequence number and publish it
 * (the triggers are the schedule's next letters). */
static void old_capture(struct old_hf *o, g16mic_engine *e, const float *in, size_t frames, int ch)
{
	uint64_t next = o->seq + 1;
	struct old_slot *sl = &o->slot[next & 1];

	o->wseq = next;
	sl->frames = 0;
	sl->channels = 0;
	if (e && in) {
		size_t first = frames < OLD_SCRATCH ? frames : OLD_SCRATCH;
		g16mic_engine_process(e, in, first, sl->raw, sl->mono);
		sl->frames = first;
		sl->channels = ch;
	}
	o->seq = next;
}

/* out_process: returns the frames written to dst; *audio is how many of them
 * carried audio (0 for zeros). */
static size_t old_output(struct old_hf *o, int out, float *dst, size_t maxframes, size_t requested, size_t *audio)
{
	struct old_out *oo = &o->out[out];
	size_t ch = (size_t)oo->ch, frames;
	uint64_t s = o->seq;
	const struct old_slot *sl = &o->slot[s & 1];
	int rs = oo->resync;

	*audio = 0;
	oo->resync = 0;
	if (rs && s > 0)
		oo->last_seq = s - 1;
	if (s == 0 || s == oo->last_seq) {
		frames = requested ? requested : s > 0 ? sl->frames : 0;
		if (frames > maxframes)
			frames = maxframes;
		memset(dst, 0, frames * ch * sizeof(float));
		o->underflow += frames * ch;
		return frames;
	}
	size_t avail = sl->frames;
	int chs = sl->channels;
	frames = avail < maxframes ? avail : maxframes;
	if (s - oo->last_seq > 1) {
		uint64_t n = (s - oo->last_seq - 1) * (uint64_t)avail * ch;
		o->overflow += n;
		o->skipped += n;
	}
	oo->last_seq = s;
	if (avail > frames)
		o->overflow += (uint64_t)(avail - frames) * ch;
	if (!oo->is_raw) {
		memcpy(dst, sl->mono, frames * sizeof(float));
	} else if ((size_t)chs == ch) {
		memcpy(dst, sl->raw, frames * ch * sizeof(float));
	} else {
		memset(dst, 0, frames * ch * sizeof(float));
		o->underflow += frames * ch;
		avail = 0;
	}
	if (avail > 0 && o->wseq >= s + 2) {
		memset(dst, 0, frames * ch * sizeof(float));
		o->overflow += (uint64_t)frames * ch;
		o->torn += (uint64_t)frames * ch;
	} else if (avail > 0) {
		*audio = frames;
	}
	return frames;
}

/* retire_engine: the tail is not flushed; it counts as lost on each active
 * output. */
static void old_retire(struct old_hf *o, g16mic_engine *e)
{
	uint64_t tail = (uint64_t)g16mic_engine_latency(e), lost = 0;

	if (o->out[OUT_P].active)
		lost += tail;
	if (o->out[OUT_R].active)
		lost += tail * CH;
	o->overflow += lost;
	o->tail_lost += lost;
}

/* ---- the simulated graph ------------------------------------------------- */

typedef struct {
	float *buf;
	size_t n, cap;  /* frames */
	int ch;
} stream_t;

static void st_init(stream_t *s, int ch)
{
	s->buf = g16s_xcalloc((size_t)STREAM_CAP * (size_t)ch, sizeof(float));
	s->n = 0;
	s->cap = STREAM_CAP;
	s->ch = ch;
}

static void st_append(stream_t *s, const float *x, size_t frames)
{
	CHECK(s->n + frames <= s->cap, "test stream capacity");
	if (s->n + frames > s->cap)
		frames = s->cap - s->n;
	memcpy(s->buf + s->n * (size_t)s->ch, x, frames * (size_t)s->ch * sizeof(float));
	s->n += frames;
}

typedef struct {
	g16mic_handoff *hf;
	g16mic_engine *e;     /* the queue's engine */
	g16mic_engine *eo;    /* the old model's engine (same input, same output) */
	struct old_hf *old;
	int stopped, old_stopped;
	stream_t got[G16MIC_HF_NOUT], ogot[G16MIC_HF_NOUT];
	uint64_t ticks;
	float *dst, *junk;
} sim_t;

static void sim_init(sim_t *s, size_t max_frames)
{
	memset(s, 0, sizeof *s);
	s->hf = g16mic_handoff_create(CH, G16MIC_HF_CAP_CYCLES, max_frames);
	if (!s->hf) {
		fprintf(stderr, "handoff create failed\n");
		exit(1);
	}
	g16mic_handoff_new_epoch(s->hf);
	g16mic_handoff_set_consuming(s->hf, OUT_P, 1);
	g16mic_handoff_set_consuming(s->hf, OUT_R, 1);
	s->e = make_engine();
	s->eo = make_engine();
	s->old = g16s_xcalloc(1, sizeof *s->old);
	old_init(s->old);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		st_init(&s->got[o], och[o]);
		st_init(&s->ogot[o], och[o]);
	}
	s->dst = g16s_xcalloc((size_t)DST_MAX * CH, sizeof(float));
	/* what arrives after the stop instant: loud, and must never come out */
	s->junk = g16s_xcalloc((size_t)Q * CH, sizeof(float));
	for (size_t i = 0; i < (size_t)Q * CH; i++)
		s->junk[i] = 0.9f;
}

static void sim_free(sim_t *s)
{
	g16mic_handoff_destroy(s->hf);
	g16mic_engine_destroy(s->e);
	g16mic_engine_destroy(s->eo);
	free(s->old);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		free(s->got[o].buf);
		free(s->ogot[o].buf);
	}
	free(s->dst);
	free(s->junk);
}

/* One capture cycle of Q frames into both hand-offs. After the stop the
 * queue's capture gets junk (it must accept none of it); the old host is
 * gone by then. */
static void sim_capture_t(sim_t *s, const float *in, int have_ticks)
{
	g16mic_handoff_capture(s->hf, s->e, s->stopped ? s->junk : in, Q, CH, s->ticks, have_ticks);
	s->ticks += Q;
	if (!s->old_stopped && s->eo)
		old_capture(s->old, s->eo, in, Q, CH);
}

static void sim_capture(sim_t *s, const float *in)
{
	sim_capture_t(s, in, 1);
}

/* One run of output `out` asking for `req` frames, in both hand-offs;
 * returns the queue's frames. */
static size_t sim_run_req(sim_t *s, int out, size_t req)
{
	size_t n = g16mic_handoff_output(s->hf, out, s->dst, DST_MAX, och[out], req);

	st_append(&s->got[out], s->dst, n);
	if (!s->old_stopped) {
		size_t audio;
		old_output(s->old, out, s->dst, DST_MAX, req, &audio);
		st_append(&s->ogot[out], s->dst, audio);
	}
	return n;
}

/* One run of output `out` at the graph quantum. */
static size_t sim_run(sim_t *s, int out)
{
	return sim_run_req(s, out, Q);
}

/* SIGTERM: the queue begins its drain; the old host retired the engine and
 * tore the outputs down. */
static void sim_stop(sim_t *s)
{
	g16mic_handoff_begin_stop(s->hf);
	s->stopped = 1;
	if (!s->old_stopped)
		old_retire(s->old, s->eo);
	s->old_stopped = 1;
}

/* Runs a schedule; 'C' takes the next input cycle in[*cyc] (not after the
 * stop). */
static void sim_sched(sim_t *s, const char *sched, const float *in, size_t *cyc)
{
	for (const char *c = sched; *c; c++) {
		switch (*c) {
		case 'C':
			if (s->stopped) {
				sim_capture(s, NULL);
			} else {
				sim_capture(s, in + *cyc * (size_t)Q * CH);
				(*cyc)++;
			}
			break;
		case 'P':
			sim_run(s, OUT_P);
			break;
		case 'R':
			sim_run(s, OUT_R);
			break;
		case 'T':
			g16mic_handoff_note_trigger(s->hf, OUT_P, -EBUSY);
			g16mic_handoff_note_trigger(s->hf, OUT_R, -EBUSY);
			break;
		case 'S':
			sim_stop(s);
			break;
		default:
			break;
		}
	}
}

static void sim_sched_n(sim_t *s, const char *sched, int n, const float *in, size_t *cyc)
{
	for (int i = 0; i < n; i++)
		sim_sched(s, sched, in, cyc);
}

static size_t count_c(const char *sched)
{
	size_t n = 0;

	for (const char *c = sched; *c; c++)
		n += *c == 'C';
	return n;
}

/* ---- references ---------------------------------------------------------- */

/* The engine's offline output for the whole input plus its flushed tail:
 * what a lossless hand-off must deliver (frames + L long). */
typedef struct {
	float *mono, *raw;
	size_t frames, total;
} ref_t;

static void ref_make(ref_t *r, const float *in, size_t cycles)
{
	g16mic_engine *e = make_engine();
	size_t L = g16mic_engine_latency(e), got, done = 0;

	r->frames = cycles * Q;
	r->total = r->frames + L;
	r->mono = g16s_xcalloc(r->total, sizeof(float));
	r->raw = g16s_xcalloc(r->total * CH, sizeof(float));
	g16mic_engine_process(e, in, r->frames, r->raw, r->mono);
	while ((got = g16mic_engine_flush(e, r->raw + (r->frames + done) * CH, r->mono + r->frames + done, 100)) > 0)
		done += got;
	CHECK_EQ_INT(done, L, "reference tail is the latency");
	g16mic_engine_destroy(e);
}

static void ref_free(ref_t *r)
{
	free(r->mono);
	free(r->raw);
}

/* got frames [at, at + n) == the reference's frames [from, from + n), bit for bit. */
static int matches(const stream_t *g, size_t at, const ref_t *r, int out, size_t from, size_t n)
{
	if (at + n > g->n || from + n > r->total)
		return 0;
	const float *src = out == OUT_P ? r->mono + from : r->raw + from * CH;
	return memcmp(g->buf + at * (size_t)g->ch, src, n * (size_t)g->ch * sizeof(float)) == 0;
}

/* Speech-like on channel 0, low noise on channel 1, interleaved. */
static float *make_input(size_t cycles, uint32_t seed)
{
	size_t n = cycles * Q;
	float *a = g16s_xcalloc(n, sizeof(float)), *b = g16s_xcalloc(n, sizeof(float));
	float *in = g16s_xcalloc(n * CH, sizeof(float));

	g16s_speech_like(a, n, RATE, seed, 100.0f, 220.0f);
	g16s_noise(b, n, seed + 1, 0.05f);
	for (size_t i = 0; i < n; i++) {
		in[i * CH] = a[i];
		in[i * CH + 1] = b[i];
	}
	free(a);
	free(b);
	return in;
}

/* Sample markers: input frame f carries (base + f + 1) x MK_SCALE on
 * channel 0 and its negative on channel 1 (exact in float), so the raw
 * output's frame j carries input frame j - L's marker. */
#define MK_SCALE (1.0f / 1048576.0f)

static float *make_markers(size_t cycles, uint32_t base)
{
	size_t n = cycles * Q;
	float *in = g16s_xcalloc(n * CH, sizeof(float));

	for (size_t f = 0; f < n; f++) {
		in[f * CH] = (float)(base + f + 1) * MK_SCALE;
		in[f * CH + 1] = -(float)(base + f + 1) * MK_SCALE;
	}
	return in;
}

/* The raw output's channel-0 marker at output frame j (zero during the
 * engine's first L frames). */
static float raw_marker(size_t j, size_t L, uint32_t base)
{
	return j < L ? 0.0f : (float)(base + (j - L) + 1) * MK_SCALE;
}

/* got frames [at, at + n) are all zeros. */
static int zeros_at(const stream_t *g, size_t at, size_t n)
{
	if (at + n > g->n)
		return 0;
	for (size_t i = at * (size_t)g->ch; i < (at + n) * (size_t)g->ch; i++)
		if (g->buf[i] != 0.0f)
			return 0;
	return 1;
}

/* A queue-only simulation (the new cases have no old-model counterpart). */
static void sim_init_q(sim_t *s)
{
	sim_init(s, G16MIC_HF_MAX_FRAMES);
	s->old_stopped = 1;
}

/* After sim_stop: one graph cycle at a time (the capture keeps being
 * called, both outputs run) until both outputs are drained. Returns the
 * cycles it took, -1 past limit. */
static int sim_drain(sim_t *s, int limit)
{
	size_t cyc = 0;

	for (int i = 1; i <= limit; i++) {
		sim_sched(s, "CPR", NULL, &cyc);
		if (g16mic_handoff_drained(s->hf, OUT_P) && g16mic_handoff_drained(s->hf, OUT_R))
			return i;
	}
	return -1;
}

static uint64_t new_lost(const sim_t *s, g16mic_hf_stats *st)
{
	g16mic_handoff_get_stats(s->hf, st);
	return g16mic_handoff_lost_samples(st);
}

/* Samples the old hand-off did not deliver, against `frames` expected per
 * output. */
static uint64_t old_missing(const sim_t *s, size_t frames)
{
	uint64_t n = 0;

	for (int o = 0; o < G16MIC_HF_NOUT; o++)
		if (s->ogot[o].n < frames)
			n += (uint64_t)(frames - s->ogot[o].n) * (uint64_t)och[o];
	return n;
}

static void report(uint64_t old_lost, uint64_t old_counted, uint64_t queue_lost)
{
	printf("  RED (old hand-off): lost %llu (counted %llu)\n", (unsigned long long)old_lost,
	       (unsigned long long)old_counted);
	printf("  GREEN (queue): lost %llu\n", (unsigned long long)queue_lost);
}

static void verdict(const char *name, int failures_before)
{
	printf("%s: %s\n", g16t_failures == failures_before ? "PASS" : "FAIL", name);
}

/* ---- (1) callback contention --------------------------------------------- */

/* glitch: the schedule between four normal cycles before and after. A
 * refused or late output run leaves its cycle queued: that output then
 * carries lag[o] cycles of added latency, with zero loss, one quantum per
 * buffer, until the stop drain delivers the rest. */
static void contention_case(const char *what, const char *glitch, size_t lag_p, size_t lag_r, uint64_t old_expect,
			    int refused)
{
	const size_t total = 8 + count_c(glitch);
	const size_t lag[G16MIC_HF_NOUT] = { lag_p, lag_r };
	float *in = make_input(total, 101u + (uint32_t)total);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("contention: %s\n", what);
	ref_make(&ref, in, total);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);
	sim_sched_n(&s, "CPR", 4, in, &cyc);
	sim_sched(&s, glitch, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].depth, lag[o], "%s: output %d keeps its missed cycles queued", what, o);
		CHECK_EQ_INT(st.out[o].added_frames, lag[o] * Q, "%s: output %d added latency", what, o);
		CHECK_EQ_INT(s.got[o].n, (cyc - lag[o]) * Q, "%s: output %d one quantum per run", what, o);
	}
	sim_sched_n(&s, "CPR", 4, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].added_frames, lag[o] * Q, "%s: output %d latency stays, never grows", what, o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, s.got[o].n), "%s: output %d bit-exact and contiguous", what, o);
	}
	uint64_t om = old_missing(&s, total * Q), oo = s.old->overflow;

	/* the stop drain delivers the backlog and the tail */
	sim_stop(&s);
	int cycles = sim_drain(&s, G16MIC_HF_CAP_CYCLES + 4);
	CHECK(cycles > 0, "%s: drained", what);
	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(s.got[o].n, total * Q + Q, "%s: output %d every frame, the tail, the pad", what, o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, total * Q + L), "%s: output %d bit-exact", what, o);
		CHECK(zeros_at(&s.got[o], total * Q + L, Q - L), "%s: output %d final buffer padded", what, o);
		CHECK_EQ_INT(st.out[o].eos_pad, (Q - L) * c, "%s: output %d pad counted", what, o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "%s: output %d no zeros", what, o);
		CHECK_EQ_INT(st.out[o].max_added_frames, lag[o] * Q, "%s: output %d max added latency", what, o);
		CHECK(st.out[o].max_depth <= G16MIC_HF_CAP_CYCLES, "%s: depth bounded", what);
	}
	CHECK(st.out[OUT_P].late_runs + st.out[OUT_R].late_runs >= 1, "%s: the late run is counted", what);
	if (refused) {
		CHECK_EQ_INT(st.trigger_refused, 2, "%s: both refused triggers counted", what);
		CHECK_EQ_INT(st.trigger_errno, EBUSY, "%s: errno recorded", what);
	}
	CHECK_EQ_INT(lost, 0, "%s: the queue loses nothing", what);

	CHECK_EQ_INT(om, old_expect, "%s: the old hand-off loses the missed cycle(s)", what);
	CHECK_EQ_INT(oo, old_expect, "%s: the old hand-off counted it", what);
	report(om, oo, lost);
	verdict(what, f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

static void test_contention(void)
{
	/* both triggers refused once */
	contention_case("trigger refused once", "CTCPR", 1, 1, 3 * Q, 1);
	/* the processed output's run comes one cycle late */
	contention_case("processed output one cycle late", "CRCPR", 1, 0, 1 * Q, 0);
	/* both outputs run only after the next capture cycle, raw first */
	contention_case("outputs run after the next capture cycle", "CCRP", 1, 1, 3 * Q, 0);
	/* three cycles late */
	contention_case("outputs three cycles late", "CCCCPRCPRCPR", 3, 3, 3 * 3 * Q, 0);
}

/* ---- (2) / (c) quiet speech and markers right before a stop -------------- */

/* (c) RED on round 1's queue: the final output run returned the L-frame
 * tail alone (not a quantum), there was no eos_pad and no drained(). */
static void test_stop_quiet_tail(void)
{
	const size_t N = 12, frames = N * Q;
	float *in = g16s_xcalloc(frames * CH, sizeof(float));
	uint32_t rs = 2024u;
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	g16mic_stats es;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("stop drain: quiet speech bursts and markers in the last 100 ms\n");
	/* a -70 dBFS bed; in the last 100 ms (the final accepted cycle
	 * included), 10 ms tone bursts at -40 dBFS every 20 ms and single
	 * low-level impulses; a marker on the very last accepted frame */
	for (size_t i = 0; i < frames * CH; i++)
		in[i] = 3.1623e-4f * g16t_rand_uniform(&rs);
	size_t from = frames - (size_t)RATE / 10;
	for (size_t i = from; i < frames; i++) {
		if (((i - from) / 480) % 2 == 0) {
			float v = 0.01f * (float)sin(2.0 * M_PI * 1000.0 * (double)i / RATE);
			in[i * CH] += v;
			in[i * CH + 1] += 0.5f * v;
		}
	}
	for (size_t k = 1; k <= 6; k++)
		in[(frames - k * 700) * CH] += 0.003f;
	in[(frames - 1) * CH] = 0.25f;
	in[(frames - 1) * CH + 1] = -0.25f;
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", (int)N, in, &cyc);
	sim_sched(&s, "S", in, &cyc);
	CHECK_EQ_INT(g16mic_handoff_stopping(s.hf), G16MIC_HF_STOP_REQUESTED, "stop requested");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_P), L, "the tail is still due (processed)");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_R), L * CH, "the tail is still due (raw)");
	CHECK(!g16mic_handoff_drained(s.hf, OUT_P) && !g16mic_handoff_drained(s.hf, OUT_R), "not drained yet");
	/* the next cycle accepts nothing and pushes the tail; the outputs
	 * still run, one quantum each: the tail, zero-padded */
	sim_sched(&s, "C", in, &cyc);
	CHECK_EQ_INT(g16mic_handoff_stopping(s.hf), G16MIC_HF_STOPPED, "stopped after the tail");
	CHECK_EQ_INT(sim_run(&s, OUT_P), Q, "the final buffer is one whole quantum (processed)");
	CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "the final buffer is one whole quantum (raw)");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_P), 0, "nothing left (processed)");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_R), 0, "nothing left (raw)");
	CHECK(!g16mic_handoff_drained(s.hf, OUT_P), "not drained: the final buffer has not gone through its cycle");
	CHECK(!g16mic_handoff_drained(s.hf, OUT_R), "not drained (raw)");
	CHECK_EQ_INT(sim_run(&s, OUT_P), 0, "end of stream (processed)");
	CHECK(g16mic_handoff_drained(s.hf, OUT_P), "drained after one more run (processed)");
	CHECK(!g16mic_handoff_drained(s.hf, OUT_R), "raw still waits for its run");
	CHECK_EQ_INT(sim_run(&s, OUT_R), 0, "end of stream (raw)");
	CHECK(g16mic_handoff_drained(s.hf, OUT_R), "drained after one more run (raw)");

	uint64_t lost = new_lost(&s, &st);
	g16mic_engine_get_stats(s.e, &es);
	CHECK_EQ_INT(es.frames_in, frames, "no input accepted after the stop instant");
	CHECK_EQ_INT(st.tail_flushed_frames, L, "the whole tail flushed");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(s.got[o].n, frames + Q, "output %d: every accepted frame, the tail, the pad", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, frames + L), "output %d: bit-exact to the offline engine", o);
		CHECK(matches(&s.got[o], frames - Q, &ref, o, frames - Q, Q), "output %d: the final accepted cycle arrived", o);
		CHECK(zeros_at(&s.got[o], frames + L, Q - L), "output %d: zero-padded to the quantum", o);
		CHECK_EQ_INT(st.out[o].eos_pad, (Q - L) * c, "output %d: the pad is eos_pad", o);
		CHECK_EQ_INT(st.out[o].drain_lost, 0, "output %d: nothing lost to the drain", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: the pad is not underflow", o);
	}
	CHECK(g16t_rms(ref.raw + (frames - Q) * CH, Q * CH) > 1e-3, "the final accepted cycle carries the -40 dBFS bursts");
	CHECK(g16s_energy(ref.mono + frames, L) > 0.0, "the tail carries the last words");
	size_t mk = frames - 1 + L;
	CHECK(s.got[OUT_R].n > mk && s.got[OUT_R].buf[mk * CH] == 0.25f && s.got[OUT_R].buf[mk * CH + 1] == -0.25f,
	      "the last accepted frame's marker arrived on raw");
	CHECK_EQ_INT(lost, 0, "the queue loses nothing at a stop");

	uint64_t om = old_missing(&s, frames + L);
	CHECK_EQ_INT(om, L * (1 + CH), "the old hand-off drops the tail");
	CHECK(s.ogot[OUT_R].n <= mk, "the old hand-off never delivered the final marker");
	report(om, s.old->overflow, lost);
	verdict("stop drain: quiet speech bursts and markers", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (3) outputs behind at the stop -------------------------------------- */

static void test_stop_queued(void)
{
	const size_t N = 7;
	float *in = make_input(N, 303u);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("stop drain: outputs three cycles behind at the stop\n");
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", 4, in, &cyc);
	sim_sched(&s, "CCCSC", in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(st.out[OUT_P].depth, 4, "three cycles and the tail queued");
	/* one quantum a run: three cycles, then the tail zero-padded */
	for (int r = 0; r < 4; r++) {
		CHECK_EQ_INT(sim_run(&s, OUT_P), Q, "run %d: one quantum (processed)", r);
		CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "run %d: one quantum (raw)", r);
	}
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_P), 0, "drained within four runs (processed)");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_R), 0, "drained within four runs (raw)");
	CHECK_EQ_INT(sim_run(&s, OUT_P), 0, "then end of stream");
	CHECK_EQ_INT(sim_run(&s, OUT_R), 0, "then end of stream");
	CHECK(g16mic_handoff_drained(s.hf, OUT_P) && g16mic_handoff_drained(s.hf, OUT_R), "drained");

	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(s.got[o].n, N * Q + Q, "output %d: all of it, padded", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, N * Q + L), "output %d: bit-exact", o);
		CHECK_EQ_INT(st.out[o].eos_pad, (Q - L) * (uint64_t)och[o], "output %d: pad", o);
	}
	CHECK_EQ_INT(lost, 0, "the queue loses nothing");

	uint64_t om = old_missing(&s, N * Q + L);
	CHECK_EQ_INT(om, (3 * Q + L) * (1 + CH), "the old hand-off drops the queued cycles and the tail");
	CHECK(s.old->overflow < om, "and counted only part of it");
	report(om, s.old->overflow, lost);
	verdict("stop drain: outputs behind at the stop", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (4) drain timeout: a stalled consumer ------------------------------- */

static void test_drain_timeout(void)
{
	const size_t N = 6;
	float *in = make_input(N, 404u);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("stop drain: timeout with a stalled raw consumer\n");
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", 3, in, &cyc);
	sim_sched_n(&s, "CP", 3, in, &cyc);  /* the raw consumer stalls */
	sim_sched(&s, "SC", in, &cyc);
	/* the drain: one poll per graph cycle, bounded by G16MIC_HF_DRAIN_MS */
	const double cycle_ms = 1000.0 * Q / RATE;
	const int max_polls = (int)ceil(G16MIC_HF_DRAIN_MS / cycle_ms);
	int polls = 0;
	while ((!g16mic_handoff_drained(s.hf, OUT_P) || !g16mic_handoff_drained(s.hf, OUT_R)) && polls < max_polls) {
		sim_run(&s, OUT_P);
		polls++;
	}
	CHECK_EQ_INT(polls, max_polls, "the drain timed out, in bounded time");
	CHECK(g16mic_handoff_drained(s.hf, OUT_P), "processed drained");
	CHECK(!g16mic_handoff_drained(s.hf, OUT_R), "raw not drained");
	size_t expect = (3 * Q + L) * CH;
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_R), expect, "raw still queued");
	g16mic_handoff_abandon(s.hf, G16MIC_HF_LOST_DRAIN);

	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(st.out[OUT_R].drain_lost, expect, "exactly the queued raw samples are drain_lost");
	CHECK_EQ_INT(st.out[OUT_P].drain_lost, 0, "nothing of processed");
	CHECK_EQ_INT(lost, expect, "nothing else counted");
	CHECK_EQ_INT(g16mic_handoff_pending(s.hf, OUT_R), 0, "empty after abandon");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].overflow + st.out[o].stale_dropped + st.out[o].late_link_discarded +
				     st.out[o].source_lost_tail + st.out[o].underflow,
			     0, "output %d: no other counter moved", o);
	}
	CHECK(matches(&s.got[OUT_P], 0, &ref, OUT_P, 0, N * Q + L) && s.got[OUT_P].n == N * Q + Q,
	      "processed got everything, padded");
	CHECK(matches(&s.got[OUT_R], 0, &ref, OUT_R, 0, 3 * Q) && s.got[OUT_R].n == 3 * Q,
	      "raw got what it took before the stall");

	uint64_t om = old_missing(&s, N * Q + L);
	CHECK_EQ_INT(om, L + (3 * Q + L) * CH, "the old hand-off loses the stalled cycles and the tail");
	CHECK_EQ_INT(s.old->overflow, L * (1 + CH), "but counts only the tail");
	printf("  drain: %d polls of %.1f ms (bound %d ms)\n", polls, cycle_ms, G16MIC_HF_DRAIN_MS);
	report(om, s.old->overflow, lost);
	verdict("stop drain: timeout with a stalled consumer", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (5) late output listener -------------------------------------------- */

static void test_late_listener(void)
{
	const size_t N = 10;
	float *in = make_input(N, 505u);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("late output listener\n");
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);

	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched_n(&s, "CR", 3, in, &cyc);  /* backlog builds on processed */
	g16mic_handoff_set_consuming(s.hf, OUT_P, 0);
	s.old->out[OUT_P].active = 0;
	CHECK(g16mic_handoff_drained(s.hf, OUT_P), "an output that is not consuming is drained");
	sim_sched_n(&s, "CR", 2, in, &cyc);
	g16mic_handoff_set_consuming(s.hf, OUT_P, 1);  /* a listener links */
	s.old->out[OUT_P].active = 1;
	s.old->out[OUT_P].resync = 1;
	size_t at = s.got[OUT_P].n;
	sim_sched_n(&s, "CPR", 3, in, &cyc);

	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(st.out[OUT_P].late_link_discarded, 3 * Q, "the backlog is counted, not delivered");
	CHECK_EQ_INT(s.got[OUT_P].n, 5 * Q, "processed: two cycles, then the three after the link");
	CHECK(matches(&s.got[OUT_P], 0, &ref, OUT_P, 0, 2 * Q), "processed before");
	CHECK(matches(&s.got[OUT_P], at, &ref, OUT_P, 7 * Q, 3 * Q),
	      "the first frame after the link is the newest cycle's audio");
	CHECK(matches(&s.got[OUT_R], 0, &ref, OUT_R, 0, N * Q) && s.got[OUT_R].n == N * Q, "raw untouched");
	CHECK_EQ_INT(st.out[OUT_P].underflow + st.out[OUT_R].underflow, 0, "no zeros");
	CHECK_EQ_INT(st.out[OUT_P].added_frames, 0, "no added latency after the link");
	CHECK_EQ_INT(lost, 0, "a late link is not a loss");

	uint64_t om = old_missing(&s, 0);
	CHECK(s.ogot[OUT_P].n == 5 * Q && matches(&s.ogot[OUT_P], at, &ref, OUT_P, 7 * Q, 3 * Q),
	      "the old hand-off also started the listener at the newest cycle");
	report(om, s.old->overflow, lost);
	verdict("late output listener", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (5b) an output activated after the capture's first cycles ---------- */

/* The host activates its outputs only once the capture streams, and the
 * capture's first cycles can run before that (test_pw_live step 6 saw the
 * reconnected stream one cycle late, latency 1296 instead of 272, for good).
 * The capture relinks an output at its first active cycle: the cycles
 * queued while it could not run are dropped, counted, never added
 * latency. */
static void test_relink(void)
{
	const size_t N = 8;
	float *in = make_input(N, 515u);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(h) relink at the first active cycle\n");
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	sim_sched_n(&s, "C", 3, in, &cyc);  /* consuming, but not yet active: no runs */
	g16mic_handoff_relink(s.hf, OUT_P);
	g16mic_handoff_relink(s.hf, OUT_R);
	sim_sched_n(&s, "CPR", 5, in, &cyc);

	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].late_link_discarded, 3 * Q * c, "output %d: the three early cycles counted, not delivered", o);
		CHECK_EQ_INT(s.got[o].n, 5 * Q, "output %d: the five cycles after the relink", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 3 * Q, 5 * Q), "output %d: from the relink cycle on, in order", o);
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: no added latency", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: no zeros", o);
	}
	CHECK_EQ_INT(lost, 0, "a relink is not a loss");
	printf("  GREEN: late_link_discarded %llu (processed); added_frames %llu\n",
	       (unsigned long long)st.out[OUT_P].late_link_discarded, (unsigned long long)st.out[OUT_P].added_frames);
	sim_free(&s);

	/* A consumer links (start_output) and its first graph cycle comes three
	 * capture cycles later (test_pw_live steps 6 and 10 under load: a late
	 * reader one or two cycles behind for good). Its first run starts at
	 * the newest cycle. */
	cyc = 0;
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	g16mic_handoff_start_output(s.hf, OUT_P);
	g16mic_handoff_start_output(s.hf, OUT_R);
	sim_sched_n(&s, "C", 3, in, &cyc);
	sim_sched_n(&s, "CPR", 5, in, &cyc);
	lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].late_link_discarded, 3 * Q * c, "start_output %d: the backlog before the first run counted", o);
		CHECK(s.got[o].n == 5 * Q && matches(&s.got[o], 0, &ref, o, 3 * Q, 5 * Q),
		      "start_output %d: the first run delivers the newest cycle, then in order", o);
		CHECK_EQ_INT(st.out[o].added_frames, 0, "start_output %d: no added latency", o);
	}
	CHECK_EQ_INT(lost, 0, "a late first run is not a loss");
	verdict("(h) relink at the first active cycle", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (6) source loss and reconnect --------------------------------------- */

static void sim_reconnect(sim_t *s)
{
	g16mic_engine_destroy(s->e);
	g16mic_engine_destroy(s->eo);
	s->e = make_engine();
	s->eo = make_engine();
	g16mic_handoff_reset_stop(s->hf);
	g16mic_handoff_new_epoch(s->hf);
	s->old->out[OUT_P].resync = 1;
	s->old->out[OUT_R].resync = 1;
}

static void test_reconnect(void)
{
	float *inA = make_input(3, 601u), *inB = make_input(4, 602u), *inC = make_input(5, 603u), *inD = make_input(2, 604u);
	ref_t rA, rB, rC, rD;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc;
	int f0 = g16t_failures;

	printf("source loss and reconnect\n");
	ref_make(&rA, inA, 3);
	ref_make(&rB, inB, 4);
	ref_make(&rC, inC, 5);
	ref_make(&rD, inD, 2);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);

	/* A: lost while the outputs still run: the tail is delivered,
	 * zero-padded to the quantum */
	cyc = 0;
	sim_sched_n(&s, "CPR", 3, inA, &cyc);
	CHECK_EQ_INT(g16mic_handoff_flush_tail(s.hf, s.e), L, "A: the tail flushed");
	old_retire(s.old, s.eo);
	CHECK_EQ_INT(sim_run(&s, OUT_P), Q, "A: the tail as one quantum (processed)");
	CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "A: the tail as one quantum (raw)");
	CHECK_EQ_INT(sim_run(&s, OUT_P), 0, "A: then end of stream, not zeros");
	CHECK_EQ_INT(sim_run(&s, OUT_R), 0, "A: then end of stream, not zeros");
	CHECK(g16mic_handoff_drained(s.hf, OUT_P) && g16mic_handoff_drained(s.hf, OUT_R), "A: drained");
	g16mic_handoff_abandon(s.hf, G16MIC_HF_LOST_SOURCE);
	size_t old_after_a = s.ogot[OUT_P].n;

	/* B: two cycles behind when lost; nothing runs in the tail window and
	 * the source is back before the queues drained */
	sim_reconnect(&s);
	cyc = 0;
	sim_sched_n(&s, "CPR", 2, inB, &cyc);
	sim_sched(&s, "CC", inB, &cyc);
	CHECK_EQ_INT(g16mic_handoff_flush_tail(s.hf, s.e), L, "B: the tail flushed");
	old_retire(s.old, s.eo);

	/* C: the old stream's entries are still queued */
	sim_reconnect(&s);
	cyc = 0;
	sim_sched_n(&s, "CPR", 3, inC, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(st.out[OUT_P].stale_dropped, 2 * Q + L, "B's queued processed samples dropped, counted");
	CHECK_EQ_INT(st.out[OUT_R].stale_dropped, (2 * Q + L) * CH, "B's queued raw samples dropped, counted");
	/* lost again, two cycles behind, the tail window ends undelivered */
	sim_sched(&s, "CC", inC, &cyc);
	CHECK_EQ_INT(g16mic_handoff_flush_tail(s.hf, s.e), L, "C: the tail flushed");
	old_retire(s.old, s.eo);
	g16mic_handoff_abandon(s.hf, G16MIC_HF_LOST_SOURCE);

	/* D */
	sim_reconnect(&s);
	cyc = 0;
	sim_sched_n(&s, "CPR", 2, inD, &cyc);

	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		size_t at = 0;
		CHECK(matches(&s.got[o], at, &rA, o, 0, 3 * Q + L), "output %d: A whole, tail included", o);
		CHECK(zeros_at(&s.got[o], at + 3 * Q + L, Q - L), "output %d: A's final buffer padded", o);
		at += 4 * Q;
		CHECK(matches(&s.got[o], at, &rB, o, 0, 2 * Q), "output %d: B as delivered", o);
		at += 2 * Q;
		CHECK(matches(&s.got[o], at, &rC, o, 0, 3 * Q), "output %d: C with no B sample before or in it", o);
		at += 3 * Q;
		CHECK(matches(&s.got[o], at, &rD, o, 0, 2 * Q), "output %d: D with no C sample before or in it", o);
		at += 2 * Q;
		CHECK_EQ_INT(s.got[o].n, at, "output %d: nothing else delivered", o);
		CHECK_EQ_INT(st.out[o].source_lost_tail, (uint64_t)(2 * Q + L) * (uint64_t)och[o],
			     "output %d: C's undelivered samples are source_lost_tail", o);
		CHECK_EQ_INT(st.out[o].eos_pad, (uint64_t)(Q - L) * (uint64_t)och[o], "output %d: A's pad", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: no zeros", o);
	}
	CHECK_EQ_INT(st.tail_flushed_frames, 3 * L, "three tails flushed");
	CHECK_EQ_INT(lost, 2 * (2 * Q + L) * (1 + CH), "lost = B stale + C source loss, exactly");

	CHECK_EQ_INT(old_after_a, 3 * Q, "the old hand-off dropped A's tail although the outputs could run");
	uint64_t om = (uint64_t)(4 * Q + 3 * L) * (1 + CH);
	CHECK_EQ_INT(s.ogot[OUT_P].n, 10 * Q, "the old hand-off delivered no tail at all");
	CHECK_EQ_INT(s.old->overflow, 3 * L * (1 + CH), "the old hand-off counted only the tails");
	report(om, s.old->overflow, lost);
	verdict("source loss and reconnect", f0);
	sim_free(&s);
	ref_free(&rA);
	ref_free(&rB);
	ref_free(&rC);
	ref_free(&rD);
	free(inA);
	free(inB);
	free(inC);
	free(inD);
}

/* ---- (7) overload beyond the bound --------------------------------------- */

/* Round 1's queue dropped the NEWEST cycles here and caught up two cycles a
 * run; now the oldest go, the latency stays at its bounded level, and the
 * drain delivers the rest. */
static void test_overload(void)
{
	const size_t N = 30;
	const size_t K = G16MIC_HF_CAP_CYCLES;
	float *in = make_input(N, 707u);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("overload: outputs starved for 20 cycles\n");
	ref_make(&ref, in, N);
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched_n(&s, "C", 20, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].depth, K, "output %d: the queue stops at its bound", o);
		CHECK_EQ_INT(st.out[o].added_frames, K * Q, "output %d: added latency at the bound", o);
	}
	/* the late run, then one capture and one run per cycle: the latency
	 * stays where the stall left it, bounded */
	sim_sched(&s, "PR", in, &cyc);
	while (cyc < N) {
		sim_sched(&s, "CPR", in, &cyc);
		g16mic_handoff_get_stats(s.hf, &st);
		CHECK(st.out[OUT_P].added_frames == (K - 1) * Q && st.out[OUT_R].added_frames == (K - 1) * Q,
		      "cycle %zu: latency stays at %zu cycles", cyc, K - 1);
	}
	uint64_t om = old_missing(&s, N * Q);
	sim_stop(&s);
	CHECK(sim_drain(&s, (int)K + 4) > 0, "drained");

	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].overflow, (20 - K) * Q * c, "output %d: overflow exact", o);
		CHECK_EQ_INT(st.out[o].overflow_cycles, 20 - K, "output %d: overflow cycles", o);
		CHECK_EQ_INT(st.out[o].max_depth, K, "output %d: depth never above the bound", o);
		CHECK_EQ_INT(st.out[o].max_added_frames, (K - 1) * Q, "output %d: max added latency", o);
		CHECK(st.out[o].max_added_frames <= K * Q, "output %d: within the documented bound", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: no zeros", o);
		CHECK_EQ_INT(st.out[o].drain_lost, 0, "output %d: the drain delivered the backlog", o);
		/* kept: cycles 0..1, then the newest eight of the stall (14..21)
		 * and everything after; dropped: the oldest of the stall, 2..13 */
		CHECK(matches(&s.got[o], 0, &ref, o, 0, 2 * Q), "output %d: before the stall", o);
		CHECK(matches(&s.got[o], 2 * Q, &ref, o, (22 - K) * Q, (N - 22 + K) * Q + L),
		      "output %d: the newest cycles kept, contiguous to the tail", o);
		CHECK_EQ_INT(s.got[o].n, 2 * Q + (N - 22 + K) * Q + Q, "output %d: length", o);
	}
	CHECK_EQ_INT(lost, (20 - K) * Q * (1 + CH), "lost exactly the oldest cycles beyond the bound");

	CHECK_EQ_INT(om, 19 * Q * (1 + CH), "the old hand-off loses all but the newest starved cycle");
	printf("  bound: %zu cycles = %.1f ms added latency at most; observed %zu cycles\n", K,
	       1000.0 * (double)(K * Q) / RATE, K - 1);
	report(om, s.old->overflow, lost);
	verdict("overload beyond the bound", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (8) capture gap ------------------------------------------------------ */

static void test_capture_gap(void)
{
	const size_t N = 9;
	float *in = make_input(N, 808u);
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("capture gap\n");
	sim_init(&s, G16MIC_HF_MAX_FRAMES);
	sim_sched_n(&s, "CPR", 3, in, &cyc);
	s.ticks += 5 * Q;  /* the capture missed five graph cycles (SIGSTOP) */
	sim_sched_n(&s, "CPR", 3, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(st.capture_gap_frames, 5 * Q, "the gap counted exactly");
	/* a new epoch restarts the tracking: no gap across a reconnect */
	g16mic_handoff_new_epoch(s.hf);
	s.ticks += 7 * Q;
	sim_sched(&s, "CPR", in, &cyc);
	/* a cycle without a graph position breaks the chain too */
	sim_capture_t(&s, in + cyc * Q * CH, 0);
	cyc++;
	sim_run(&s, OUT_P);
	sim_run(&s, OUT_R);
	s.ticks += 3 * Q;
	sim_sched(&s, "CPR", in, &cyc);
	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(st.capture_gap_frames, 5 * Q, "nothing counted across an epoch or a missing position");
	CHECK_EQ_INT(lost, 0, "a capture gap is input never seen, not an output loss");
	printf("  RED (old hand-off): lost %llu; a capture gap was invisible to it (no counter)\n",
	       (unsigned long long)old_missing(&s, N * Q));
	printf("  GREEN (queue): lost %llu; capture_gap_frames %llu\n", (unsigned long long)lost,
	       (unsigned long long)st.capture_gap_frames);
	verdict("capture gap", f0);
	sim_free(&s);
	free(in);
}

/* ---- (a) exactly one quantum per buffer ----------------------------------- */

/* RED on round 1's queue: with three cycles queued it wrote two whole
 * cycles (2048 frames) into one buffer, and it ignored `requested` while a
 * cycle was queued (256 or 1536 got 1024). */
static void test_exact_quantum(void)
{
	const size_t N = 11;
	float *in = make_markers(N, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0, bad = 0;
	int f0 = g16t_failures;

	printf("(a) exactly one quantum per output buffer\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);
	size_t L = g16mic_engine_latency(s.e);

	/* three cycles queued: still one quantum a buffer */
	sim_sched(&s, "CCC", in, &cyc);
	for (int r = 0; r < 3; r++) {
		bad += sim_run(&s, OUT_P) != Q;
		bad += sim_run(&s, OUT_R) != Q;
		g16mic_handoff_get_stats(s.hf, &st);
		CHECK_EQ_INT(st.out[OUT_R].added_frames, (size_t)(2 - r) * Q, "run %d: the rest stays in our queue", r);
	}
	/* a 256-frame quantum against 1024-frame capture cycles */
	for (int c = 0; c < 4; c++) {
		sim_sched(&s, "C", in, &cyc);
		for (int r = 0; r < 4; r++) {
			bad += sim_run_req(&s, OUT_P, 256) != 256;
			bad += sim_run_req(&s, OUT_R, 256) != 256;
		}
	}
	/* a 1536-frame quantum: across entry boundaries */
	sim_sched(&s, "CCC", in, &cyc);
	for (int r = 0; r < 2; r++) {
		bad += sim_run_req(&s, OUT_P, 1536) != 1536;
		bad += sim_run_req(&s, OUT_R, 1536) != 1536;
	}
	/* one more cycle, a 1536 request: 1024 frames of audio, 512 of zeros */
	sim_sched(&s, "C", in, &cyc);
	bad += sim_run_req(&s, OUT_P, 1536) != 1536;
	bad += sim_run_req(&s, OUT_R, 1536) != 1536;
	CHECK_EQ_INT(bad, 0, "every buffer is exactly the requested quantum");

	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(s.got[o].n, N * Q + 512, "output %d: length", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, N * Q), "output %d: contiguous across entry boundaries", o);
		CHECK(zeros_at(&s.got[o], N * Q, 512), "output %d: the shortfall is zeros", o);
		CHECK_EQ_INT(st.out[o].underflow, 512 * c, "output %d: counted as underflow", o);
		CHECK_EQ_INT(st.out[o].delivered, N * Q * c, "output %d: delivered", o);
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: nothing left queued", o);
	}
	/* the raw markers themselves, across a 256 and a 1536 boundary */
	size_t at[] = { 3 * Q + 255, 3 * Q + 256, 7 * Q + 1535, 7 * Q + 1536 };
	for (size_t k = 0; k < sizeof at / sizeof at[0]; k++)
		CHECK(s.got[OUT_R].buf[at[k] * CH] == raw_marker(at[k], L, 0), "raw marker at frame %zu", at[k]);
	CHECK_EQ_INT(g16mic_handoff_lost_samples(&st), 0, "nothing lost");
	printf("  GREEN: every buffer one quantum (round 1's queue wrote up to two cycles in one)\n");
	verdict("(a) exactly one quantum per output buffer", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (b) overflow drops the oldest ---------------------------------------- */

/* RED on round 1's queue: it dropped the three newest cycles and delivered
 * cycle 0 first. */
static void test_overflow_oldest(void)
{
	const size_t K = G16MIC_HF_CAP_CYCLES, N = K + 3;
	float *in = make_markers(N, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(b) overflow drops the oldest cycles, counted exactly\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "C", (int)N, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].overflow, 3 * Q * c, "output %d: three cycles x frames x channels", o);
		CHECK_EQ_INT(st.out[o].overflow_cycles, 3, "output %d: three cycles", o);
		CHECK_EQ_INT(st.out[o].depth, K, "output %d: full", o);
	}
	for (size_t r = 0; r < K; r++) {
		sim_run(&s, OUT_P);
		sim_run(&s, OUT_R);
	}
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(s.got[o].n, K * Q, "output %d: the bound's worth", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 3 * Q, K * Q), "output %d: cycles 3.. in order", o);
		CHECK_EQ_INT(st.out[o].delivered + st.out[o].overflow, N * Q * c, "output %d: delivered + overflow = produced", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: no zeros", o);
	}
	CHECK(s.got[OUT_R].buf[0] == raw_marker(3 * Q, L, 0), "the first delivered raw sample is cycle 3's marker");
	printf("  GREEN: first raw marker %.0f (cycle 3), overflow %llu raw samples\n",
	       (double)s.got[OUT_R].buf[0] / MK_SCALE, (unsigned long long)st.out[OUT_R].overflow);
	verdict("(b) overflow drops the oldest", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (d) source loss with a half-taken entry ------------------------------- */

/* RED on round 1's queue: `requested` was ignored, the half run took two
 * whole cycles, so source_lost_tail was not the unconsumed rest. */
static void test_source_loss_partial(void)
{
	const size_t N = 5;
	float *in = make_markers(N, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(d) source loss with a half-taken oldest entry\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched(&s, "CCC", in, &cyc);
	CHECK_EQ_INT(sim_run_req(&s, OUT_P, Q / 2), Q / 2, "half a cycle (processed)");
	CHECK_EQ_INT(sim_run_req(&s, OUT_R, Q / 2), Q / 2, "half a cycle (raw)");
	CHECK_EQ_INT(g16mic_handoff_flush_tail(s.hf, s.e), L, "the tail flushed");
	g16mic_handoff_abandon(s.hf, G16MIC_HF_LOST_SOURCE);

	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].source_lost_tail, (2 * Q + Q / 2 + L) * c,
			     "output %d: the half entry's rest + two cycles + the tail", o);
		CHECK_EQ_INT(st.out[o].delivered, (2 * Q + Q / 2) * c, "output %d: delivered", o);
		CHECK_EQ_INT(st.out[o].delivered + st.out[o].source_lost_tail, (N * Q + L) * c,
			     "output %d: every sample accounted for", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, 2 * Q + Q / 2), "output %d: what was delivered", o);
		CHECK_EQ_INT(g16mic_handoff_pending(s.hf, o), 0, "output %d: empty", o);
	}
	CHECK_EQ_INT(lost, (2 * Q + Q / 2 + L) * (1 + CH), "lost = exactly the source-loss tail");
	verdict("(d) source loss with a half-taken entry", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (e) a new epoch after queued data ------------------------------------ */

struct epoch_hook {
	g16mic_handoff *hf;
	int fire, calls;
};

/* the control thread starts a new epoch while the output is copying */
static void hook_new_epoch(void *arg, int out)
{
	struct epoch_hook *h = arg;

	(void)out;
	h->calls++;
	if (h->fire > 0) {
		h->fire--;
		g16mic_handoff_new_epoch(h->hf);
	}
}

/* RED on round 1's queue: the half run took two whole cycles (stale count
 * off) and it had no recopy: an epoch changing during the copy let the old
 * stream's samples out. */
static void test_new_epoch_queued(void)
{
	const uint32_t BASE_B = 100000;
	float *inA = make_markers(5, 0), *inB = make_markers(3, BASE_B);
	ref_t rA, rB;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(e) a new epoch with the old stream still queued\n");
	ref_make(&rA, inA, 5);
	ref_make(&rB, inB, 3);
	sim_init_q(&s);

	sim_sched_n(&s, "CPR", 2, inA, &cyc);
	sim_sched(&s, "CCC", inA, &cyc);
	sim_run_req(&s, OUT_P, Q / 2);
	sim_run_req(&s, OUT_R, Q / 2);
	/* the reconnect: a new engine, a new epoch, 2.5 old cycles queued */
	g16mic_engine_destroy(s.e);
	s.e = make_engine();
	g16mic_handoff_new_epoch(s.hf);
	size_t at = s.got[OUT_R].n;
	cyc = 0;
	sim_sched(&s, "CPR", inB, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].stale_dropped, (2 * Q + Q / 2) * c, "output %d: the old rest, counted", o);
		CHECK(matches(&s.got[o], at, &rB, o, 0, Q), "output %d: the next buffer is the new stream's", o);
	}
	size_t old_in_new = 0;
	for (size_t j = at; j < s.got[OUT_R].n; j++) {
		float v = s.got[OUT_R].buf[j * CH];
		old_in_new += v != 0.0f && v < (float)BASE_B * MK_SCALE;
	}
	CHECK_EQ_INT(old_in_new, 0, "no old-stream marker in the new stream");

	/* an epoch that changes while the output is copying: the copy is
	 * thrown away, the old entry dropped, zeros instead */
	sim_sched(&s, "C", inB, &cyc);
	struct epoch_hook eh = { .hf = s.hf, .fire = 1 };
	g16mic_handoff_set_test_hook(s.hf, hook_new_epoch, &eh);
	size_t atp = s.got[OUT_P].n;
	CHECK_EQ_INT(sim_run(&s, OUT_P), Q, "a quantum");
	g16mic_handoff_set_test_hook(s.hf, NULL, NULL);
	CHECK(zeros_at(&s.got[OUT_P], atp, Q), "nothing of the earlier epoch in the buffer");
	CHECK_EQ_INT(eh.calls, 2, "copied, then recopied");
	CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "a quantum (raw)");
	CHECK(zeros_at(&s.got[OUT_R], s.got[OUT_R].n - Q, Q), "raw: the earlier epoch's entry is not delivered");
	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(st.out[OUT_P].retries, 1, "the recopy is counted");
	CHECK_EQ_INT(st.out[OUT_P].stale_dropped, 2 * Q + Q / 2 + Q, "and the entry as stale");
	CHECK_EQ_INT(st.out[OUT_R].stale_dropped, (2 * Q + Q / 2 + Q) * CH, "raw too");
	CHECK_EQ_INT(st.out[OUT_P].underflow, Q, "the buffer was zeros, counted");
	verdict("(e) a new epoch after queued data", f0);
	sim_free(&s);
	ref_free(&rA);
	ref_free(&rB);
	free(inA);
	free(inB);
}

/* ---- (f) late or refused runs: latency, not loss --------------------------- */

/* RED on round 1's queue: the run after the skip wrote two cycles into one
 * buffer, and there was no added_frames / max_added_frames. */
static void test_late_runs(void)
{
	int f0 = g16t_failures;

	printf("(f) skipped output runs (k < CAP): added latency, zero loss\n");
	for (size_t k = 1; k < G16MIC_HF_CAP_CYCLES; k++) {
		const size_t N = 2 + k + 6;
		float *in = make_markers(N, 0);
		ref_t ref;
		sim_t s;
		g16mic_hf_stats st;
		size_t cyc = 0, bad = 0;

		ref_make(&ref, in, N);
		sim_init_q(&s);
		size_t L = g16mic_engine_latency(s.e);
		sim_sched_n(&s, "CPR", 2, in, &cyc);
		sim_sched_n(&s, "CT", (int)k, in, &cyc);
		g16mic_handoff_get_stats(s.hf, &st);
		CHECK(st.out[OUT_P].added_frames == k * Q && st.out[OUT_R].added_frames == k * Q,
		      "k %zu: added_frames is k cycles", k);
		for (int r = 0; r < 6; r++) {
			sim_sched(&s, "C", in, &cyc);
			bad += sim_run(&s, OUT_P) != Q;
			bad += sim_run(&s, OUT_R) != Q;
			g16mic_handoff_get_stats(s.hf, &st);
			bad += st.out[OUT_P].added_frames != k * Q || st.out[OUT_R].added_frames != k * Q;
		}
		CHECK_EQ_INT(bad, 0, "k %zu: one quantum per run, latency steady at k cycles", k);
		for (int o = 0; o < G16MIC_HF_NOUT; o++)
			CHECK_EQ_INT(st.out[o].max_added_frames, k * Q, "k %zu: output %d max added", k, o);
		CHECK_EQ_INT(st.trigger_refused, 2 * k, "k %zu: refused triggers counted", k);
		sim_stop(&s);
		CHECK(sim_drain(&s, (int)k + 4) > 0, "k %zu: drained", k);
		uint64_t lost = new_lost(&s, &st);
		for (int o = 0; o < G16MIC_HF_NOUT; o++) {
			CHECK(matches(&s.got[o], 0, &ref, o, 0, N * Q + L), "k %zu: output %d all of it, in order", k, o);
			CHECK_EQ_INT(s.got[o].n, N * Q + Q, "k %zu: output %d length", k, o);
			CHECK_EQ_INT(st.out[o].underflow + st.out[o].overflow, 0, "k %zu: output %d no zeros, no drops", k, o);
			CHECK(st.out[o].late_runs >= 6, "k %zu: output %d late runs counted", k, o);
		}
		CHECK_EQ_INT(lost, 0, "k %zu: zero loss", k);
		sim_free(&s);
		ref_free(&ref);
		free(in);
	}
	verdict("(f) late or refused runs", f0);
}

/* ---- (g) the producer drops what the consumer copied ---------------------- */

struct cap_hook {
	sim_t *s;
	const float *in;
	size_t *cyc;
	int fire, calls;
};

/* the capture runs between the output's copy and its publish */
static void hook_capture(void *arg, int out)
{
	struct cap_hook *h = arg;

	(void)out;
	h->calls++;
	if (h->fire > 0) {
		h->fire--;
		sim_capture(h->s, h->in + *h->cyc * (size_t)Q * CH);
		(*h->cyc)++;
	}
}

struct thr {
	g16mic_handoff *hf;
	g16mic_engine *e;
	const float *in;
	size_t cycles, L;
	atomic_int done;
	uint64_t out_of_order, polls;
};

static void *thr_producer(void *arg)
{
	struct thr *t = arg;

	for (size_t c = 0; c < t->cycles; c++)
		g16mic_handoff_capture(t->hf, t->e, t->in + c * (size_t)Q * CH, Q, CH, (uint64_t)(c * Q), 1);
	atomic_store(&t->done, 1);
	return NULL;
}

static void *thr_consumer(void *arg)
{
	struct thr *t = arg;
	float *dst = g16s_xcalloc((size_t)Q * CH, sizeof(float));
	float last = 0.0f;

	for (uint64_t i = 0; i < 50000000u; i++) {
		int fin = atomic_load(&t->done);
		g16mic_handoff_output(t->hf, OUT_P, dst, Q, 1, Q);
		g16mic_handoff_output(t->hf, OUT_R, dst, Q, CH, Q);
		for (size_t j = 0; j < Q; j++) {
			float v = dst[j * CH];
			if (v != 0.0f) {
				t->out_of_order += !(v > last);
				last = v;
			}
		}
		t->polls++;
		if (fin && g16mic_handoff_pending(t->hf, OUT_P) == 0 && g16mic_handoff_pending(t->hf, OUT_R) == 0)
			break;
	}
	free(dst);
	return NULL;
}

/* RED on round 1's queue: a full queue dropped the new cycle, so the copy
 * was never invalidated and there was no recopy (nor a hook to show it). */
static void test_cas_retry(void)
{
	const size_t K = G16MIC_HF_CAP_CYCLES, N = K + 5;
	float *in = make_markers(N, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(g) the producer drops what an output just copied\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);

	struct cap_hook ch = { .s = &s, .in = in, .cyc = &cyc };
	sim_sched_n(&s, "C", (int)K, in, &cyc);  /* cycles 0..7: full */
	/* a whole entry: the capture of cycle 8 drops cycle 0 mid-copy */
	ch.fire = 1;
	g16mic_handoff_set_test_hook(s.hf, hook_capture, &ch);
	CHECK_EQ_INT(sim_run(&s, OUT_P), Q, "one quantum");
	g16mic_handoff_set_test_hook(s.hf, NULL, NULL);
	CHECK_EQ_INT(ch.calls, 2, "copied, dropped under it, recopied");
	CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "raw, no race");
	/* half an entry: cycle 10's capture drops cycle 2 mid-copy */
	sim_sched(&s, "C", in, &cyc);  /* cycle 9: full again */
	ch.fire = 1;
	ch.calls = 0;
	g16mic_handoff_set_test_hook(s.hf, hook_capture, &ch);
	CHECK_EQ_INT(sim_run_req(&s, OUT_P, Q / 2), Q / 2, "half a quantum");
	g16mic_handoff_set_test_hook(s.hf, NULL, NULL);
	CHECK_EQ_INT(ch.calls, 2, "recopied from the new oldest entry");
	CHECK_EQ_INT(sim_run_req(&s, OUT_P, Q / 2), Q / 2, "the rest of that entry");
	CHECK_EQ_INT(sim_run(&s, OUT_R), Q, "raw");
	/* a half-taken oldest entry dropped by the producer: only its rest */
	sim_sched(&s, "C", in, &cyc);  /* cycle 11: full */
	sim_run_req(&s, OUT_P, Q / 2);
	sim_run_req(&s, OUT_R, Q / 2);
	sim_sched(&s, "C", in, &cyc);  /* cycle 12: drops the rest of cycle 4 */
	sim_run(&s, OUT_P);
	sim_run(&s, OUT_R);

	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(cyc, N, "all cycles captured");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		const g16mic_hf_out_stats *so = &st.out[o];
		CHECK(matches(&s.got[o], 0, &ref, o, 1 * Q, Q), "output %d: cycle 1", o);
		CHECK(matches(&s.got[o], Q, &ref, o, 3 * Q, Q), "output %d: cycle 3, across a split", o);
		CHECK(matches(&s.got[o], 2 * Q, &ref, o, 4 * Q, Q / 2), "output %d: the first half of cycle 4", o);
		CHECK(matches(&s.got[o], 2 * Q + Q / 2, &ref, o, 5 * Q, Q), "output %d: cycle 5", o);
		CHECK_EQ_INT(s.got[o].n, 3 * Q + Q / 2, "output %d: length", o);
		CHECK_EQ_INT(so->overflow, (2 * Q + Q / 2) * c, "output %d: overflow: cycles 0 and 2, half of 4", o);
		CHECK_EQ_INT(so->overflow_cycles, 3, "output %d: three entries dropped", o);
		CHECK_EQ_INT(so->added_frames, 7 * Q, "output %d: cycles 6..12 queued", o);
		CHECK_EQ_INT(so->delivered + so->overflow + so->added_frames * c, N * Q * c,
			     "output %d: delivered + overflow + queued = produced", o);
		CHECK_EQ_INT(so->underflow, 0, "output %d: no zeros", o);
	}
	CHECK_EQ_INT(st.out[OUT_P].retries, 2, "processed recopied twice");
	CHECK_EQ_INT(st.out[OUT_R].retries, 0, "raw never");
	sim_free(&s);
	ref_free(&ref);
	free(in);

	/* two threads, a fixed amount of work, no pacing: whatever the
	 * interleaving, every sample is accounted for and order is kept */
	const size_t TN = 400;
	struct thr t;
	pthread_t pt, ct;
	memset(&t, 0, sizeof t);
	t.in = make_markers(TN, 0);
	t.cycles = TN;
	t.e = make_engine();
	t.L = g16mic_engine_latency(t.e);
	t.hf = g16mic_handoff_create(CH, G16MIC_HF_CAP_CYCLES, G16MIC_HF_MAX_FRAMES);
	atomic_init(&t.done, 0);
	g16mic_handoff_new_epoch(t.hf);
	g16mic_handoff_set_consuming(t.hf, OUT_P, 1);
	g16mic_handoff_set_consuming(t.hf, OUT_R, 1);
	CHECK_EQ_INT(pthread_create(&ct, NULL, thr_consumer, &t), 0, "consumer thread");
	CHECK_EQ_INT(pthread_create(&pt, NULL, thr_producer, &t), 0, "producer thread");
	pthread_join(pt, NULL);
	pthread_join(ct, NULL);
	g16mic_handoff_get_stats(t.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		const g16mic_hf_out_stats *so = &st.out[o];
		CHECK_EQ_INT(so->delivered + so->overflow + so->added_frames * c, TN * Q * c,
			     "threads: output %d delivered + overflow + queued = produced", o);
		CHECK_EQ_INT(so->stale_dropped + so->late_link_discarded + so->width_mismatch, 0,
			     "threads: output %d nothing else", o);
		CHECK(so->max_depth <= G16MIC_HF_CAP_CYCLES, "threads: output %d bounded", o);
		printf("  threads: output %d delivered %llu overflow %llu retries %llu\n", o,
		       (unsigned long long)so->delivered, (unsigned long long)so->overflow,
		       (unsigned long long)so->retries);
	}
	CHECK_EQ_INT(t.out_of_order, 0, "threads: raw markers strictly in order");
	g16mic_handoff_destroy(t.hf);
	g16mic_engine_destroy(t.e);
	free((void *)t.in);
	verdict("(g) recopy after a drop, exact accounting", f0);
}

/* ---- (j) a late listener PipeWire first runs before the capture ----------- */

/* RED on round 2 (test_pw_live step 6, a g16_mic_raw reader one cycle behind
 * for good: latency 1296 = 272 + 1024, queue_added_frames 1024): its start
 * logic looked only at the output's first 4 runs, and a run that found one
 * cycle queued took it. Right after the link PipeWire runs the raw output
 * BEFORE the capture for six cycles (schedule "RCP": the run takes the
 * previous cycle, the capture's trigger is refused), then in the normal
 * order ("CPR"). By then the 4 runs were used up and the output took, every
 * cycle, the cycle before the capture's. Now the producer checks, for
 * G16MIC_HF_START_CYCLES cycles after the link, right after its push of the
 * graph cycle, whether the output holds more than that cycle. */
static void test_late_listener_order(void)
{
	const size_t N = 14;
	float *in = make_markers(N, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(j) late listener, first run before the capture for six cycles\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);
	size_t L = g16mic_engine_latency(s.e);

	sim_sched_n(&s, "CPR", 2, in, &cyc);
	g16mic_handoff_set_consuming(s.hf, OUT_R, 0);  /* the raw reader goes */
	sim_sched_n(&s, "CP", 2, in, &cyc);
	g16mic_handoff_set_consuming(s.hf, OUT_R, 1);  /* a raw reader links */
	g16mic_handoff_start_output(s.hf, OUT_R);
	sim_sched_n(&s, "RCP", 6, in, &cyc);  /* output before capture */
	CHECK_EQ_INT(G16MIC_HF_START_CYCLES > 6, 1, "the start window outlasts the output-first spell");
	size_t at = s.got[OUT_R].n;
	sim_sched(&s, "CPR", in, &cyc);  /* the normal order */
	size_t now = cyc - 1;
	CHECK(s.got[OUT_R].n == at + Q && s.got[OUT_R].buf[at * CH] == raw_marker(now * Q, L, 0),
	      "the first buffer in the normal order starts with the current cycle's first sample");
	sim_sched_n(&s, "CPR", 3, in, &cyc);
	CHECK_EQ_INT(cyc, N, "all cycles captured");

	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(st.out[OUT_R].added_frames, 0, "raw: no added latency, at exactly the engine latency");
	CHECK_EQ_INT(st.out[OUT_R].late_link_discarded, (uint64_t)Q * CH, "raw: the one cycle behind dropped, counted");
	CHECK_EQ_INT(st.out[OUT_R].underflow, (uint64_t)Q * CH, "raw: its first run (nothing pushed yet) was zeros");
	CHECK(matches(&s.got[OUT_R], 0, &ref, OUT_R, 0, 2 * Q), "raw: before it left");
	CHECK(zeros_at(&s.got[OUT_R], 2 * Q, Q), "raw: the first run's zeros");
	CHECK(matches(&s.got[OUT_R], 3 * Q, &ref, OUT_R, 4 * Q, 5 * Q), "raw: the output-first runs, a cycle behind");
	CHECK(matches(&s.got[OUT_R], 8 * Q, &ref, OUT_R, 10 * Q, 4 * Q), "raw: then current audio, in order");
	CHECK_EQ_INT(s.got[OUT_R].n, 12 * Q, "raw: length");
	/* the processed output was on time all along: untouched */
	CHECK(matches(&s.got[OUT_P], 0, &ref, OUT_P, 0, N * Q) && s.got[OUT_P].n == N * Q, "processed: every cycle, in order");
	CHECK_EQ_INT(st.out[OUT_P].added_frames + st.out[OUT_P].late_link_discarded + st.out[OUT_P].underflow, 0,
		     "processed: nothing added, dropped or zero");
	CHECK_EQ_INT(lost, 0, "a late link is not a loss");
	printf("  RED (round 2): raw one cycle behind for good, added_frames %d\n", Q);
	printf("  GREEN: raw added_frames %llu, late_link_discarded %llu\n", (unsigned long long)st.out[OUT_R].added_frames,
	       (unsigned long long)st.out[OUT_R].late_link_discarded);
	sim_free(&s);

	/* a listener that is on time from its first run loses nothing */
	cyc = 0;
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	g16mic_handoff_set_consuming(s.hf, OUT_R, 0);
	sim_sched_n(&s, "CP", 2, in, &cyc);
	g16mic_handoff_set_consuming(s.hf, OUT_R, 1);
	g16mic_handoff_start_output(s.hf, OUT_R);
	sim_sched_n(&s, "CPR", (int)(N - 4), in, &cyc);
	lost = new_lost(&s, &st);
	CHECK(matches(&s.got[OUT_R], 2 * Q, &ref, OUT_R, 4 * Q, (N - 4) * Q) && s.got[OUT_R].n == (N - 2) * Q,
	      "on time: every cycle from the link on");
	CHECK_EQ_INT(st.out[OUT_R].late_link_discarded + st.out[OUT_R].underflow + st.out[OUT_R].added_frames, 0,
		     "on time: nothing dropped, no zeros, no added latency");
	CHECK_EQ_INT(lost, 0, "on time: no loss");

	/* the engine tail never restarts an output in its window: the last
	 * accepted cycle, still queued at the stop, arrives */
	cyc = 0;
	sim_free(&s);
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	g16mic_handoff_start_output(s.hf, OUT_P);
	g16mic_handoff_start_output(s.hf, OUT_R);
	sim_sched(&s, "CPR", in, &cyc);
	sim_sched(&s, "C", in, &cyc);  /* the outputs miss this cycle's run */
	sim_stop(&s);
	CHECK(sim_drain(&s, 8) > 0, "window + stop: drained");
	lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK(matches(&s.got[o], 0, &ref, o, 0, 4 * Q + L), "window + stop: output %d the last cycle and the tail", o);
		CHECK_EQ_INT(st.out[o].late_link_discarded, 0, "window + stop: output %d nothing discarded", o);
	}
	CHECK_EQ_INT(lost, 0, "window + stop: no loss");
	verdict("(j) late listener, output before capture", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (k) the latency trim: quiet cycles only, both outputs ---------------- */

/* Capture cycles of held excess before the first trim, and the trim rate. */
#define TRIM_HOLD_CYCLES ((size_t)(((uint64_t)G16MIC_HF_TRIM_HOLDOFF_MS * RATE / 1000u + Q - 1) / Q))
#define TRIM_EVERY ((size_t)G16MIC_HF_TRIM_EVERY_CYCLES)

/* -80 dBFS noise on both channels; with burst, 10 ms 1 kHz tone bursts at
 * -40 dBFS every 20 ms on top (every 1024-frame cycle carries one). */
static float *make_quiet(size_t cycles, uint32_t seed, int burst)
{
	size_t n = cycles * Q;
	float *in = g16s_xcalloc(n * CH, sizeof(float));

	g16s_noise(in, n * CH, seed, 1e-4f);
	if (burst) {
		for (size_t i = 0; i < n; i++) {
			if ((i / 480) % 2 == 0) {
				float v = 0.01f * (float)sin(2.0 * M_PI * 1000.0 * (double)i / RATE);
				in[i * CH] += v;
				in[i * CH + 1] += 0.5f * v;
			}
		}
	}
	return in;
}

static float peak_abs(const float *x, size_t n)
{
	float p = 0.0f;

	for (size_t i = 0; i < n; i++)
		if (fabsf(x[i]) > p)
			p = fabsf(x[i]);
	return p;
}

/* Cycles [from, to) of the reference: quiet (1) when every raw and mono
 * sample is below the trim threshold; else 0. */
static int ref_quiet(const ref_t *r, size_t from, size_t to)
{
	return peak_abs(r->raw + from * Q * CH, (to - from) * Q * CH) < G16MIC_HF_TRIM_QUIET_PEAK &&
	       peak_abs(r->mono + from * Q, (to - from) * Q) < G16MIC_HF_TRIM_QUIET_PEAK;
}

/* got == the reference with capture cycle `gap` (the trimmed one) left out:
 * bit-exact on both sides of it. */
static int matches_without(const stream_t *g, const ref_t *r, int out, size_t gap)
{
	size_t a = gap * Q;

	if (g->n < a)
		return 0;
	return matches(g, 0, r, out, 0, a) && matches(g, a, r, out, a + Q, g->n - a);
}

/* (2) RED on round 2 (no recovery: a missed output run left a cycle of
 * latency for good). One missed run on quiet input: after the hold-off the
 * next quiet cycle is withheld from both outputs and the latency is back at
 * the target. */
static void test_trim_quiet(void)
{
	const size_t H = TRIM_HOLD_CYCLES, N = 3 + H + 8;
	float *in = make_quiet(N, 1101u, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(k) latency trim: a one-cycle excess on quiet input (hold-off %zu cycles)\n", H);
	ref_make(&ref, in, N);
	CHECK(ref_quiet(&ref, 0, N), "the input is quiet on every channel, raw and processed");
	sim_init_q(&s);

	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched(&s, "C", in, &cyc);  /* both runs missed: a cycle behind */
	sim_sched_n(&s, "CPR", (int)H - 1, in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].added_frames, Q, "output %d: within the hold-off the excess stays", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed, 0, "output %d: nothing trimmed within the hold-off", o);
	}
	sim_sched(&s, "CPR", in, &cyc);  /* the hold-off is over */
	size_t gap = cyc - 1;
	g16mic_handoff_get_stats(s.hf, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: back at the target", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed, Q * c, "output %d: exactly one cycle x channels trimmed", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed_cycles, 1, "output %d: one cycle", o);
	}
	CHECK_EQ_INT(st.latency_trims, 1, "one trim decision");
	sim_sched_n(&s, "CPR", 8, in, &cyc);
	CHECK_EQ_INT(cyc, N, "all cycles captured");
	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: stays at the target", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed, Q * c, "output %d: no further trim on time", o);
		CHECK_EQ_INT(st.out[o].underflow + st.out[o].overflow, 0, "output %d: no zeros, no overflow", o);
		CHECK(matches_without(&s.got[o], &ref, o, gap), "output %d: bit-exact, only the trimmed cycle missing", o);
		CHECK_EQ_INT(s.got[o].n, (N - 1) * Q, "output %d: length", o);
		CHECK_EQ_INT(st.out[o].delivered + st.out[o].latency_trimmed, N * Q * c,
			     "output %d: delivered + trimmed = produced", o);
	}
	CHECK_EQ_INT(lost, 0, "a trim is not a loss: ring_overflow unchanged");
	printf("  RED (round 2): added latency stayed %d frames for good\n", Q);
	printf("  GREEN: cycle %zu trimmed after %zu cycles behind; added_frames 0\n", gap, H);
	verdict("(k) latency trim on quiet input", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* (3) Continuous -40 dBFS tone bursts (quiet speech): no cycle is quiet, so
 * the excess stays and nothing is trimmed, however long it holds. */
static void test_trim_never_in_speech(void)
{
	const size_t H = TRIM_HOLD_CYCLES, N = 3 + H + 20;
	float *in = make_quiet(N, 1201u, 1);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0, loud = 0;
	int f0 = g16t_failures;

	printf("(l) latency trim: never inside -40 dBFS bursts or markers\n");
	ref_make(&ref, in, N);
	for (size_t k = 0; k < N; k++)
		loud += !ref_quiet(&ref, k, k + 1);
	CHECK_EQ_INT(loud, N, "every cycle carries a -40 dBFS burst");
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched(&s, "C", in, &cyc);
	sim_sched_n(&s, "CPR", (int)(N - 3), in, &cyc);
	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].latency_trimmed, 0, "output %d: nothing trimmed", o);
		CHECK_EQ_INT(st.out[o].added_frames, Q, "output %d: the excess stays", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, s.got[o].n) && s.got[o].n == (N - 1) * Q,
		      "output %d: every cycle, bit-exact", o);
	}
	CHECK_EQ_INT(st.latency_trims, 0, "no trim decision");
	CHECK_EQ_INT(lost, 0, "no loss");
	sim_free(&s);
	free(in);
	ref_free(&ref);

	/* sample markers (loud from cycle 1 on): the same */
	in = make_markers(N, 0);
	ref_make(&ref, in, N);
	cyc = 0;
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched(&s, "C", in, &cyc);
	sim_sched_n(&s, "CPR", (int)(N - 3), in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	CHECK_EQ_INT(st.latency_trims, 0, "markers: no trim");
	CHECK(matches(&s.got[OUT_R], 0, &ref, OUT_R, 0, s.got[OUT_R].n), "markers: every marker delivered in order");
	verdict("(l) latency trim never inside speech or markers", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* (4) The outputs carry different excess (processed one cycle, raw two):
 * the trim withholds the SAME capture cycle from both, so both delivered
 * streams are the reference with that one cycle out, and it stops once
 * processed is at the target (raw keeps its other cycle). */
static void test_trim_aligned(void)
{
	const size_t H = TRIM_HOLD_CYCLES, N = 4 + H + 8;
	float *in = make_quiet(N, 1301u, 0);
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(m) latency trim: both outputs lose the same cycle\n");
	ref_make(&ref, in, N);
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched(&s, "CP", in, &cyc);  /* raw one behind */
	sim_sched(&s, "C", in, &cyc);   /* processed one, raw two */
	sim_sched_n(&s, "CPR", (int)H, in, &cyc);
	size_t gap = cyc - 1;
	sim_sched_n(&s, "CPR", 8, in, &cyc);
	CHECK_EQ_INT(cyc, N, "all cycles captured");
	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(st.latency_trims, 1, "one trim: then processed is at the target");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].latency_trimmed_cycles, 1, "output %d: one cycle trimmed", o);
		CHECK(matches_without(&s.got[o], &ref, o, gap), "output %d: the same cycle %zu missing", o, gap);
	}
	CHECK_EQ_INT(st.out[OUT_P].added_frames, 0, "processed at the target");
	CHECK_EQ_INT(st.out[OUT_R].added_frames, Q, "raw keeps the cycle the processed side never had");
	CHECK_EQ_INT(s.got[OUT_P].n, (N - 1) * Q, "processed length");
	CHECK_EQ_INT(s.got[OUT_R].n, (N - 2) * Q, "raw length");
	CHECK_EQ_INT(lost, 0, "no loss");
	verdict("(m) latency trim keeps the outputs aligned", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* (5) Three cycles of excess on quiet input: three trims, exactly
 * G16MIC_HF_TRIM_EVERY_CYCLES cycles apart, never two closer. */
static void test_trim_rate(void)
{
	const size_t H = TRIM_HOLD_CYCLES, N = 5 + H + 3 * TRIM_EVERY + 4;
	float *in = make_quiet(N, 1401u, 0);
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0, at[8], n_at = 0;
	uint64_t prev = 0;
	int f0 = g16t_failures;

	printf("(n) latency trim: at most one cycle per %zu cycles\n", TRIM_EVERY);
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched_n(&s, "C", 3, in, &cyc);  /* three cycles behind */
	while (cyc < N) {
		sim_sched(&s, "CPR", in, &cyc);
		g16mic_handoff_get_stats(s.hf, &st);
		if (st.latency_trims != prev && n_at < 8)
			at[n_at++] = cyc - 1;
		prev = st.latency_trims;
	}
	CHECK_EQ_INT(n_at, 3, "three trims for three cycles of excess");
	CHECK(n_at >= 1 && at[0] == 2 + H, "the first after the hold-off (cycle %zu)", n_at ? at[0] : 0);
	for (size_t k = 1; k < n_at; k++)
		CHECK_EQ_INT(at[k] - at[k - 1], TRIM_EVERY, "trim %zu: %zu cycles after the last", k, TRIM_EVERY);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: back at the target", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed, 3 * Q * (uint64_t)och[o], "output %d: three cycles counted", o);
	}
	printf("  GREEN: trims at cycles %zu, %zu, %zu\n", n_at > 0 ? at[0] : 0, n_at > 1 ? at[1] : 0,
	       n_at > 2 ? at[2] : 0);
	verdict("(n) latency trim rate limit", f0);
	sim_free(&s);
	free(in);
}

/* (6) Overload past the bound on quiet input: the oldest cycles overflow,
 * counted exactly as before; afterwards the trim brings the latency from
 * K - 1 cycles back to the target, one cycle per G16MIC_HF_TRIM_EVERY_CYCLES,
 * and the overflow count does not move. */
static void test_trim_after_overflow(void)
{
	const size_t K = G16MIC_HF_CAP_CYCLES, H = TRIM_HOLD_CYCLES;
	const size_t N = 2 + 20 + H + (K - 1) * TRIM_EVERY + 8;
	float *in = make_quiet(N, 1501u, 0);
	sim_t s;
	g16mic_hf_stats st;
	size_t cyc = 0;
	int f0 = g16t_failures;

	printf("(o) overflow past the bound, then the trim recovers on quiet input\n");
	sim_init_q(&s);
	sim_sched_n(&s, "CPR", 2, in, &cyc);
	sim_sched_n(&s, "C", 20, in, &cyc);
	sim_sched(&s, "PR", in, &cyc);
	g16mic_handoff_get_stats(s.hf, &st);
	uint64_t ov[G16MIC_HF_NOUT];
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		ov[o] = st.out[o].overflow;
		CHECK_EQ_INT(st.out[o].overflow, (20 - K) * Q * (uint64_t)och[o], "output %d: the oldest dropped, exactly", o);
		CHECK_EQ_INT(st.out[o].overflow_cycles, 20 - K, "output %d: overflow cycles", o);
		CHECK_EQ_INT(st.out[o].added_frames, (K - 1) * Q, "output %d: K - 1 cycles behind", o);
	}
	while (cyc < N)
		sim_sched(&s, "CPR", in, &cyc);
	uint64_t lost = new_lost(&s, &st);
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].added_frames, 0, "output %d: back at the target", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed_cycles, K - 1, "output %d: K - 1 cycles trimmed", o);
		CHECK_EQ_INT(st.out[o].overflow, ov[o], "output %d: overflow unchanged by the trim", o);
		CHECK_EQ_INT(st.out[o].underflow, 0, "output %d: no zeros", o);
		CHECK_EQ_INT(st.out[o].max_depth, K, "output %d: depth never above the bound", o);
		CHECK_EQ_INT(st.out[o].delivered + st.out[o].overflow + st.out[o].latency_trimmed, N * Q * c,
			     "output %d: delivered + overflow + trimmed = produced", o);
		CHECK_EQ_INT(s.got[o].n * c, st.out[o].delivered, "output %d: one quantum per run", o);
	}
	CHECK_EQ_INT(lost, (20 - K) * Q * (1 + CH), "lost is the overflow alone");
	printf("  GREEN: overflow %llu raw samples, then %llu cycles trimmed back to the target\n",
	       (unsigned long long)st.out[OUT_R].overflow, (unsigned long long)st.out[OUT_R].latency_trimmed_cycles);
	verdict("(o) overflow, then trim back to the target", f0);
	sim_free(&s);
	free(in);
}

/* (7) The trim threshold against the live test's quiet speech. Step 10 of
 * test_pw_live.sh streams test_pw_helper --quiet: uniform noise of peak
 * STEP10_QUIET_PEAK, which it requires delivered intact. Round-4 finding: a
 * quiet-speech burst at the live step-10 level must never be trimmed; with a
 * threshold raised to that level (comparing against 0.004, say) phase A and
 * the single-sample edge fail. */
#define STEP10_QUIET_PEAK (0.1f / 32.0f)  /* test_pw_helper.c: 0.1 * SIG_QUIET_GAIN (2^-5), about -50 dBFS */
#define BELOW_QUIET_PEAK 0.0005f          /* about -66 dBFS: below the 0.001 (-60 dBFS) threshold */
_Static_assert(STEP10_QUIET_PEAK >= 2.0f * G16MIC_HF_TRIM_QUIET_PEAK, "the step-10 level must stay above the threshold");
_Static_assert(BELOW_QUIET_PEAK < G16MIC_HF_TRIM_QUIET_PEAK, "the below level must stay below the threshold");

/* Uniform noise in [-peak, peak) on both channels, deterministic. */
static float *make_level(size_t cycles, uint32_t seed, float peak)
{
	size_t n = cycles * Q;
	float *in = g16s_xcalloc(n * CH, sizeof(float));

	g16s_noise(in, n * CH, seed, peak);
	return in;
}

/* The one-cycle excess of test_trim_quiet on `in` (N cycles), then CPR to
 * the end; at[] gets the capture cycle of each trim (at most 4). Returns
 * the number of trims seen. */
static size_t run_excess(sim_t *s, const float *in, size_t N, size_t *at)
{
	size_t cyc = 0, n_at = 0;
	uint64_t prev = 0;
	g16mic_hf_stats st;

	sim_sched_n(s, "CPR", 2, in, &cyc);
	sim_sched(s, "C", in, &cyc);  /* both runs missed: a cycle behind */
	while (cyc < N) {
		sim_sched(s, "CPR", in, &cyc);
		g16mic_handoff_get_stats(s->hf, &st);
		if (st.latency_trims != prev && n_at < 4)
			at[n_at++] = cyc - 1;
		prev = st.latency_trims;
	}
	return n_at;
}

static void test_trim_threshold_boundary(void)
{
	const size_t H = TRIM_HOLD_CYCLES, N = 3 + H + 20, K = 2 + H;  /* K: the first cycle a trim may take */
	ref_t ref;
	sim_t s;
	g16mic_hf_stats st;
	size_t at[4] = { 0 }, n_at, loud = 0;
	int f0 = g16t_failures;

	printf("(p) latency trim: the step-10 quiet level is never trimmed, below the threshold may be\n");

	/* A: the step-10 level, every cycle, both channels: never trimmed */
	float *in = make_level(N, 1601u, STEP10_QUIET_PEAK);
	CHECK(peak_abs(in, N * Q * CH) <= STEP10_QUIET_PEAK, "A: the input peaks at the step-10 level");
	ref_make(&ref, in, N);
	for (size_t k = 0; k < N; k++)
		loud += !ref_quiet(&ref, k, k + 1);
	CHECK_EQ_INT(loud, N, "A: no cycle at the step-10 level is quiet");
	sim_init_q(&s);
	n_at = run_excess(&s, in, N, at);
	uint64_t lost = new_lost(&s, &st);
	CHECK_EQ_INT(n_at, 0, "A: no trim at any cycle");
	CHECK_EQ_INT(st.latency_trims, 0, "A: no trim decision");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		CHECK_EQ_INT(st.out[o].latency_trimmed, 0, "A: output %d nothing trimmed", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed_cycles, 0, "A: output %d no trimmed cycle", o);
		CHECK_EQ_INT(st.out[o].added_frames, Q, "A: output %d the one-cycle excess stays", o);
		CHECK(matches(&s.got[o], 0, &ref, o, 0, s.got[o].n) && s.got[o].n == (N - 1) * Q,
		      "A: output %d every cycle, bit-exact", o);
	}
	CHECK_EQ_INT(lost, 0, "A: ring_overflow unchanged");
	sim_free(&s);
	ref_free(&ref);
	free(in);

	/* B: -66 dBFS, below the threshold: exactly one cycle trimmed after the
	 * hold-off, the same one on both outputs */
	in = make_level(N, 1602u, BELOW_QUIET_PEAK);
	ref_make(&ref, in, N);
	CHECK(ref_quiet(&ref, 0, N), "B: the input is quiet on every channel, raw and processed");
	sim_init_q(&s);
	n_at = run_excess(&s, in, N, at);
	lost = new_lost(&s, &st);
	CHECK_EQ_INT(n_at, 1, "B: one trim");
	CHECK(n_at == 1 && at[0] == K, "B: right after the hold-off (cycle %zu)", K);
	CHECK_EQ_INT(st.latency_trims, 1, "B: one trim decision");
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		uint64_t c = (uint64_t)och[o];
		CHECK_EQ_INT(st.out[o].latency_trimmed, Q * c, "B: output %d one cycle x channels trimmed", o);
		CHECK_EQ_INT(st.out[o].latency_trimmed_cycles, 1, "B: output %d one cycle", o);
		CHECK_EQ_INT(st.out[o].added_frames, 0, "B: output %d back at the target", o);
		CHECK(n_at == 1 && matches_without(&s.got[o], &ref, o, at[0]),
		      "B: output %d bit-exact, only the trimmed cycle missing", o);
		CHECK_EQ_INT(st.out[o].delivered + st.out[o].latency_trimmed, N * Q * c,
			     "B: output %d delivered + trimmed = produced", o);
	}
	CHECK_EQ_INT(lost, 0, "B: a trim is not a loss");
	sim_free(&s);
	ref_free(&ref);
	free(in);

	/* edge: cycle K (the first a trim may take) is -80 dBFS except ONE
	 * sample at the step-10 level, placed so the raw output carries it in
	 * cycle K: K is kept whole and the trim takes the next quiet cycle */
	in = make_quiet(N, 1603u, 0);
	{
		g16mic_engine *e = make_engine();
		size_t L = g16mic_engine_latency(e);
		g16mic_engine_destroy(e);
		in[(K * Q + Q / 2 - L) * CH] = STEP10_QUIET_PEAK;  /* output frame K * Q + Q / 2 */
	}
	ref_make(&ref, in, N);
	CHECK(!ref_quiet(&ref, K, K + 1), "edge: cycle %zu carries the sample", K);
	CHECK(ref_quiet(&ref, 0, K) && ref_quiet(&ref, K + 1, N), "edge: every other cycle is quiet");
	sim_init_q(&s);
	n_at = run_excess(&s, in, N, at);
	lost = new_lost(&s, &st);
	CHECK_EQ_INT(n_at, 1, "edge: one trim");
	CHECK(n_at == 1 && at[0] != K, "edge: cycle %zu with one step-10 sample not trimmed", K);
	CHECK(n_at == 1 && at[0] == K + 1, "edge: the next quiet cycle (%zu) trimmed instead", K + 1);
	for (int o = 0; o < G16MIC_HF_NOUT; o++)
		CHECK(n_at == 1 && matches_without(&s.got[o], &ref, o, at[0]),
		      "edge: output %d bit-exact, cycle %zu delivered whole", o, K);
	CHECK_EQ_INT(lost, 0, "edge: no loss");
	printf("  RED (threshold at the step-10 level): phase A and the edge cycle would be trimmed\n");
	printf("  GREEN: step-10 level kept whole; -66 dBFS trimmed at cycle %zu\n", K);
	verdict("(p) latency trim threshold vs the step-10 quiet level", f0);
	sim_free(&s);
	ref_free(&ref);
	free(in);
}

/* ---- (9) API edges --------------------------------------------------------- */

static void test_api_edges(void)
{
	int f0 = g16t_failures;
	float *in = make_input(2, 909u);
	ref_t ref;
	g16mic_hf_stats st;
	float *dst = g16s_xcalloc((size_t)DST_MAX * CH, sizeof(float));

	printf("API edges\n");
	CHECK(g16mic_handoff_create(0, 8, 1024) == NULL, "0 channels refused");
	CHECK(g16mic_handoff_create(G16MIC_MAX_CH + 1, 8, 1024) == NULL, "too many channels refused");
	CHECK(g16mic_handoff_create(CH, 6, 1024) == NULL, "capacity not a power of two refused");
	CHECK(g16mic_handoff_create(CH, 8, 0) == NULL, "0 frames refused");
	CHECK(g16mic_handoff_create(CH, 8, 65536) == NULL, "an entry offset must fit the cursor's 16 bits");
	ref_make(&ref, in, 2);

	/* a cycle above max_frames: the engine sees all of it, an entry
	 * carries max_frames, the rest is oversize; the next cycle continues
	 * the engine's stream */
	g16mic_handoff *hf = g16mic_handoff_create(CH, 8, 512);
	g16mic_engine *e = make_engine();
	g16mic_handoff_new_epoch(hf);
	CHECK_EQ_INT(g16mic_handoff_pending(hf, OUT_P), 0, "not consuming: nothing pending");
	CHECK(g16mic_handoff_drained(hf, OUT_P), "not consuming: drained");
	g16mic_handoff_note_trigger(hf, OUT_P, -EBUSY);
	g16mic_handoff_get_stats(hf, &st);
	CHECK_EQ_INT(st.trigger_refused, 0, "a refused trigger without a consumer is nothing");
	g16mic_handoff_set_consuming(hf, OUT_P, 1);
	g16mic_handoff_set_consuming(hf, OUT_R, 1);
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_P, dst, 512, 1, 0), 0, "no cycle yet and no request: nothing");
	g16mic_handoff_capture(hf, e, in, Q, CH, 0, 1);
	g16mic_handoff_capture(hf, e, in + Q * CH, Q, CH, Q, 1);
	/* requested 0: the last cycle's size (what an entry carried) */
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_P, dst, 512, 1, 0), 512, "an entry carries max_frames");
	CHECK(memcmp(dst, ref.mono, 512 * sizeof(float)) == 0, "the first part of the cycle");
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_P, dst, 512, 1, 0), 512, "the next cycle's entry");
	CHECK(memcmp(dst, ref.mono + Q, 512 * sizeof(float)) == 0, "engine state stayed continuous");
	/* raw: an output of the wrong width gets zeros, counted; the request
	 * beyond the buffer is cut, counted */
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_R, dst, 512, 1, Q), 512, "width mismatch still runs");
	CHECK(g16s_energy(dst, 512) == 0.0, "as zeros");
	/* raw: a buffer smaller than the entry: the rest stays queued */
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_R, dst, 100, CH, Q), 100, "a small buffer takes what fits");
	CHECK(memcmp(dst, ref.raw + Q * CH, 100 * CH * sizeof(float)) == 0, "the start of the entry");
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_R, dst, DST_MAX, CH, 300), 300, "the next buffer continues inside it");
	CHECK(memcmp(dst, ref.raw + (Q + 100) * CH, 300 * CH * sizeof(float)) == 0, "from the read position");
	/* 112 frames left, 300 asked for, running: zeros for the rest, counted */
	CHECK_EQ_INT(g16mic_handoff_output(hf, OUT_R, dst, DST_MAX, CH, 300), 300, "underflow fills the request");
	CHECK(memcmp(dst, ref.raw + (Q + 400) * CH, 112 * CH * sizeof(float)) == 0, "the entry's last frames first");
	CHECK(g16s_energy(dst + 112 * CH, 188 * CH) == 0.0, "then zeros");
	g16mic_handoff_get_stats(hf, &st);
	CHECK_EQ_INT(st.out[OUT_P].oversize, 2 * (Q - 512), "processed oversize");
	CHECK_EQ_INT(st.out[OUT_R].oversize, 2 * (Q - 512) * CH + (Q - 512) * 1 + (Q - 100) * CH, "raw oversize");
	CHECK_EQ_INT(st.out[OUT_R].width_mismatch, 512 * CH, "raw width mismatch");
	CHECK_EQ_INT(st.out[OUT_R].underflow, 188 * CH, "raw underflow");
	CHECK_EQ_INT(st.out[OUT_R].delivered, 512 * CH, "raw delivered");
	CHECK_EQ_INT(st.last_cycle_frames, 512, "last cycle size");
	CHECK_EQ_INT(g16mic_handoff_lost_samples(&st),
		     2 * (Q - 512) * (1 + CH) + (Q - 512) + (Q - 100) * CH + 512 * CH, "lost = oversize + width mismatch");
	g16mic_handoff_note_trigger(hf, OUT_R, -EPIPE);
	g16mic_handoff_get_stats(hf, &st);
	CHECK_EQ_INT(st.trigger_refused, 1, "a refused trigger while consuming counts");
	CHECK_EQ_INT(st.trigger_errno, EPIPE, "with its errno");
	g16mic_engine_destroy(e);
	g16mic_handoff_destroy(hf);

	g16mic_hf_stats z;
	memset(&z, 0, sizeof z);
	z.out[0].overflow = 1;
	z.out[0].oversize = 2;
	z.out[0].width_mismatch = 4;
	z.out[1].stale_dropped = 8;
	z.out[1].drain_lost = 16;
	z.out[1].source_lost_tail = 32;
	z.out[0].underflow = 64;
	z.out[1].late_link_discarded = 128;
	z.out[0].eos_pad = 256;
	z.capture_gap_frames = 512;
	z.out[1].latency_trimmed = 1024;
	z.latency_trims = 1;
	CHECK_EQ_INT(g16mic_handoff_lost_samples(&z), 63, "lost sums the six loss counters only (not the trim)");
	g16mic_handoff_destroy(NULL);
	g16mic_handoff_set_test_hook(NULL, NULL, NULL);
	CHECK(g16mic_handoff_drained(NULL, OUT_P), "NULL: nothing to wait for");
	verdict("API edges", f0);
	ref_free(&ref);
	free(dst);
	free(in);
}

int main(void)
{
	g16mic_engine *e = make_engine();
	printf("quantum %d frames, engine latency %zu frames, queue bound %d cycles\n", Q, g16mic_engine_latency(e),
	       G16MIC_HF_CAP_CYCLES);
	g16mic_engine_destroy(e);
	test_contention();
	test_stop_quiet_tail();
	test_stop_queued();
	test_drain_timeout();
	test_late_listener();
	test_relink();
	test_reconnect();
	test_overload();
	test_capture_gap();
	test_exact_quantum();
	test_overflow_oldest();
	test_source_loss_partial();
	test_new_epoch_queued();
	test_late_runs();
	test_cas_retry();
	test_late_listener_order();
	test_trim_quiet();
	test_trim_never_in_speech();
	test_trim_aligned();
	test_trim_rate();
	test_trim_after_overflow();
	test_trim_threshold_boundary();
	test_api_edges();
	G16T_RETURN();
}
