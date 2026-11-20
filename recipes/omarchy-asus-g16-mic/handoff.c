/* SPDX-License-Identifier: MIT */
/* handoff.c: the capture -> outputs hand-off of the g16-mic host
 * (g16mic_handoff.h has the design: one quantum per buffer, bound, epochs,
 * stop).
 *
 * Each output has its own single-producer single-consumer queue of capture
 * cycles (entries), written and read in place: an entry carries up to
 * max_frames x channels samples, too much to copy through a record. The
 * queue holds at most cap entries (the logical capacity) in a physical ring
 * of cap + 1 slots, indexed by monotonic entry numbers modulo cap + 1.
 *
 *   head    producer-owned: the number of the next entry to write; published
 *           with release after the entry is complete.
 *   cursor  the read position, one 64-bit atomic packing (entry number << 16
 *           | frame offset inside that entry). Both sides move it, only by
 *           compare-and-swap, and only forward: the consumer past what it
 *           took, the producer past the oldest entry when the queue is full.
 *
 * Producer (capture, flush_tail; one thread at a time): before writing
 * entry h it makes room: while h - cursor.entry >= cap it advances the
 * cursor by CAS past the oldest entry and counts that entry's rest (frames
 * from the offset on) as overflow. Then it writes slot h % (cap + 1), which
 * is outside [cursor.entry, h) and so not one a consumer that still holds
 * the current cursor reads, and publishes head = h + 1.
 *
 * Consumer (output, abandon of one output; one thread at a time): loads the
 * cursor and head, copies from the slots between them into dst, then
 * publishes the advanced cursor by CAS. Cursor values only grow, so the CAS
 * fails exactly when the producer dropped (and may have overwritten) part of
 * what the consumer copied since it loaded the cursor; that is already
 * counted as overflow, so the consumer throws its copy away and copies again
 * from the new cursor (at most HF_MAX_RETRY times, then zeros). A
 * successful CAS synchronizes with the producer's next drop, so the copy
 * never saw a later write. Entry metadata are relaxed atomics, so a copy
 * racing an overwrite reads only values the producer wrote; inconsistent
 * metadata are checked before use and only lead to a retry.
 *
 * Accounting: pushed_f/pushed_s grow by every entry before head moves;
 * taken_f/taken_s grow by everything the cursor moves past (taken, dropped
 * or discarded), after the CAS that moved it. Queued = pushed - taken,
 * loading taken first (so never below zero). A cycle the latency trim
 * withholds (trim_cycle) is never pushed: it is counted as latency_trimmed
 * by the producer and touches neither pushed_* nor the cursor, so the trim
 * never races a consumer. The few atomics drained()
 * relies on (run_begin, run_end, last_real, taken_s) are sequentially
 * consistent; the rest are relaxed. Counters are fetch-adds (some have two
 * writers); the max values have one writer each.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic_handoff.h"

#define RLX memory_order_relaxed
#define ACQ memory_order_acquire
#define REL memory_order_release
#define HF_OFF_BITS 16
#define HF_OFF_MASK ((uint64_t)0xffff)
#define HF_MAX_RETRY 8
/* the trim hold-off in frames at G16MIC_RATE (no division per cycle) */
#define HF_TRIM_HOLDOFF_FRAMES ((uint64_t)G16MIC_HF_TRIM_HOLDOFF_MS * (uint64_t)G16MIC_RATE / 1000u)

struct hf_entry {
	_Atomic uint64_t epoch;
	_Atomic uint64_t push_seq;
	_Atomic uint32_t frames;
	atomic_int channels;
	float *samples;  /* preallocated: max_frames x (1 or max_channels) */
};

struct hf_queue {
	struct hf_entry *ent;  /* cap + 1 slots */
	float *store;
	size_t stride;  /* samples per entry's storage */
	int max_ch;     /* 1 (processed) or max_channels (raw) */
	_Atomic uint64_t head;    /* next entry number (producer) */
	_Atomic uint64_t cursor;  /* entry number << 16 | frame offset */
	atomic_int consuming;
	_Atomic uint64_t link_seq;
	/* capture cycles left in the start window (start_output, relink): set
	 * by the control thread or the producer, counted down by the producer
	 * (by compare-and-swap, so a restart is never lost) */
	atomic_int start_left;
	_Atomic uint64_t pushed_f, pushed_s, taken_f, taken_s;
	_Atomic uint64_t delivered, underflow, eos_pad, overflow, overflow_cycles, oversize, width, stale, late_link,
		drain_lost, source_lost, late_runs, retries, trimmed, trimmed_cycles;
	_Atomic uint64_t max_depth;  /* producer */
	_Atomic uint64_t max_added;  /* consumer */
	/* consumer runs, for drained(): run_begin is stored at the start of a
	 * run, run_end at its end; last_real is the number of the last run
	 * that handed out audio (or a zero-padded final buffer), 0 = none */
	_Atomic uint64_t run_begin, run_end, last_real;
};

struct g16mic_handoff {
	int max_ch;
	size_t cap, nslot, max_frames;
	struct hf_queue q[G16MIC_HF_NOUT];

	_Atomic uint64_t epoch;
	_Atomic uint64_t push_seq;   /* the next capture cycle's sequence number */
	atomic_int stop;             /* G16MIC_HF_RUNNING / STOP_REQUESTED / STOPPED */

	/* producer-only state */
	uint64_t prod_epoch;
	int prod_ch;                 /* channels of the epoch's accepted input; 0 = none yet */
	int have_prev;
	uint64_t prev_ticks, prev_frames;
	float *scratch_raw, *scratch_mono;
	/* latency trim (trim_cycle): frames of consecutive cycles at whose push
	 * every consuming output held a whole extra cycle (saturates at the
	 * hold-off), and capture cycles since the last trim (saturates at
	 * G16MIC_HF_TRIM_EVERY_CYCLES) */
	uint64_t trim_held, trim_since;
	int in_tail;                 /* push_tail is pushing: no start-window restart on the tail */

	/* producer-written, read by pending() and get_stats() */
	_Atomic uint64_t tail_due;   /* engine latency of the current epoch's engine, frames */
	_Atomic int tail_ch;
	_Atomic uint64_t capture_gap, tail_flushed, last_cycle, trims;
	/* capture callback */
	_Atomic uint64_t trigger_refused;
	atomic_int trigger_errno;

	/* tests only (g16mic_handoff_set_test_hook) */
	g16mic_hf_test_hook hook;
	void *hook_arg;
};

static int is_pow2(size_t v)
{
	return v >= 2 && (v & (v - 1)) == 0;
}

static int valid_out(int out)
{
	return out >= 0 && out < G16MIC_HF_NOUT;
}

static void bump_max(_Atomic uint64_t *m, uint64_t v)
{
	/* single writer: a load and a store are enough */
	if (v > atomic_load_explicit(m, RLX))
		atomic_store_explicit(m, v, RLX);
}

static uint64_t cur_pack(uint64_t entry, uint64_t off)
{
	return entry << HF_OFF_BITS | off;
}

static struct hf_entry *slot(const g16mic_handoff *hf, struct hf_queue *q, uint64_t entry)
{
	return &q->ent[entry % hf->nslot];
}

/* Frames queued now (pushed - taken; taken first, so never negative). */
static uint64_t queued_frames(struct hf_queue *q)
{
	uint64_t t = atomic_load_explicit(&q->taken_f, ACQ);
	return atomic_load_explicit(&q->pushed_f, ACQ) - t;
}

static uint64_t queued_samples(struct hf_queue *q)
{
	uint64_t t = atomic_load(&q->taken_s);
	return atomic_load(&q->pushed_s) - t;
}

static void count_taken(struct hf_queue *q, uint64_t frames, uint64_t samples)
{
	if (!frames && !samples)
		return;
	atomic_fetch_add_explicit(&q->taken_f, frames, REL);
	atomic_fetch_add(&q->taken_s, samples);
}

g16mic_handoff *g16mic_handoff_create(int max_channels, size_t cap_cycles_pow2, size_t max_frames)
{
	if (max_channels < 1 || max_channels > G16MIC_MAX_CH || !is_pow2(cap_cycles_pow2) || max_frames == 0 ||
	    max_frames > HF_OFF_MASK || cap_cycles_pow2 > SIZE_MAX / 2 ||
	    max_frames > SIZE_MAX / sizeof(float) / (size_t)max_channels / (cap_cycles_pow2 + 1))
		return NULL;
	g16mic_handoff *hf = calloc(1, sizeof *hf);
	if (!hf)
		return NULL;
	hf->max_ch = max_channels;
	hf->cap = cap_cycles_pow2;
	hf->nslot = cap_cycles_pow2 + 1;
	hf->max_frames = max_frames;
	atomic_init(&hf->epoch, 0);
	atomic_init(&hf->push_seq, 0);
	atomic_init(&hf->stop, G16MIC_HF_RUNNING);
	atomic_init(&hf->tail_due, 0);
	atomic_init(&hf->tail_ch, 0);
	atomic_init(&hf->capture_gap, 0);
	atomic_init(&hf->tail_flushed, 0);
	atomic_init(&hf->last_cycle, 0);
	atomic_init(&hf->trims, 0);
	hf->trim_held = 0;
	hf->trim_since = G16MIC_HF_TRIM_EVERY_CYCLES;
	atomic_init(&hf->trigger_refused, 0);
	atomic_init(&hf->trigger_errno, 0);
	hf->scratch_raw = calloc(max_frames * (size_t)max_channels, sizeof(float));
	hf->scratch_mono = calloc(max_frames, sizeof(float));
	if (!hf->scratch_raw || !hf->scratch_mono)
		goto fail;
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &hf->q[o];
		q->max_ch = o == G16MIC_HF_RAW ? max_channels : 1;
		q->stride = max_frames * (size_t)q->max_ch;
		q->ent = calloc(hf->nslot, sizeof *q->ent);
		q->store = calloc(hf->nslot * q->stride, sizeof(float));
		if (!q->ent || !q->store)
			goto fail;
		for (size_t i = 0; i < hf->nslot; i++) {
			struct hf_entry *en = &q->ent[i];
			en->samples = q->store + i * q->stride;
			atomic_init(&en->epoch, 0);
			atomic_init(&en->push_seq, 0);
			atomic_init(&en->frames, 0);
			atomic_init(&en->channels, 0);
		}
		atomic_init(&q->head, 0);
		atomic_init(&q->cursor, 0);
		atomic_init(&q->consuming, 0);
		atomic_init(&q->link_seq, 0);
		atomic_init(&q->start_left, 0);
		atomic_init(&q->pushed_f, 0);
		atomic_init(&q->pushed_s, 0);
		atomic_init(&q->taken_f, 0);
		atomic_init(&q->taken_s, 0);
		atomic_init(&q->delivered, 0);
		atomic_init(&q->underflow, 0);
		atomic_init(&q->eos_pad, 0);
		atomic_init(&q->overflow, 0);
		atomic_init(&q->overflow_cycles, 0);
		atomic_init(&q->oversize, 0);
		atomic_init(&q->width, 0);
		atomic_init(&q->stale, 0);
		atomic_init(&q->late_link, 0);
		atomic_init(&q->drain_lost, 0);
		atomic_init(&q->source_lost, 0);
		atomic_init(&q->late_runs, 0);
		atomic_init(&q->retries, 0);
		atomic_init(&q->trimmed, 0);
		atomic_init(&q->trimmed_cycles, 0);
		atomic_init(&q->max_depth, 0);
		atomic_init(&q->max_added, 0);
		atomic_init(&q->run_begin, 0);
		atomic_init(&q->run_end, 0);
		atomic_init(&q->last_real, 0);
	}
	return hf;
fail:
	g16mic_handoff_destroy(hf);
	return NULL;
}

void g16mic_handoff_destroy(g16mic_handoff *hf)
{
	if (!hf)
		return;
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		free(hf->q[o].ent);
		free(hf->q[o].store);
	}
	free(hf->scratch_raw);
	free(hf->scratch_mono);
	free(hf);
}

uint64_t g16mic_handoff_new_epoch(g16mic_handoff *hf)
{
	if (!hf)
		return 0;
	return atomic_fetch_add_explicit(&hf->epoch, 1, memory_order_acq_rel) + 1;
}

void g16mic_handoff_set_consuming(g16mic_handoff *hf, int out, int on)
{
	if (!hf || !valid_out(out))
		return;
	struct hf_queue *q = &hf->q[out];
	if (on) {
		/* the next cycle the producer pushes is the first this
		 * consumer takes; everything before it is backlog */
		atomic_store_explicit(&q->link_seq, atomic_load_explicit(&hf->push_seq, ACQ), REL);
		atomic_store_explicit(&q->consuming, 1, REL);
	} else {
		atomic_store_explicit(&q->consuming, 0, REL);
	}
}

void g16mic_handoff_start_output(g16mic_handoff *hf, int out)
{
	if (!hf || !valid_out(out))
		return;
	atomic_store_explicit(&hf->q[out].start_left, G16MIC_HF_START_CYCLES, REL);
}

void g16mic_handoff_relink(g16mic_handoff *hf, int out)
{
	if (!hf || !valid_out(out))
		return;
	/* the producer is push_seq's only writer: this is the next cycle's */
	atomic_store_explicit(&hf->q[out].link_seq, atomic_load_explicit(&hf->push_seq, RLX), REL);
	atomic_store_explicit(&hf->q[out].start_left, G16MIC_HF_START_CYCLES, REL);
}

void g16mic_handoff_set_test_hook(g16mic_handoff *hf, g16mic_hf_test_hook fn, void *arg)
{
	if (!hf)
		return;
	hf->hook = fn;
	hf->hook_arg = arg;
}

/* What the cursor moved past, by kind; added to the counters only once the
 * move is published. */
struct hf_tally {
	uint64_t frames, samples;  /* everything moved past (taken_f, taken_s) */
	uint64_t delivered, width, stale, late, kept;
};

/* Which counter an entry the cursor moves past without delivering belongs
 * to: stale (another epoch), late (queued before the link) or kept (the
 * current stream's: the caller's cause). */
static void tally_skip(struct hf_tally *t, uint64_t eep, uint64_t seq, uint64_t ep, uint64_t link, uint64_t n)
{
	if (eep != ep)
		t->stale += n;
	else if (seq < link)
		t->late += n;
	else
		t->kept += n;
}

static void tally_apply(struct hf_queue *q, const struct hf_tally *t, _Atomic uint64_t *kept_to)
{
	if (t->delivered)
		atomic_fetch_add_explicit(&q->delivered, t->delivered, RLX);
	if (t->width)
		atomic_fetch_add_explicit(&q->width, t->width, RLX);
	if (t->stale)
		atomic_fetch_add_explicit(&q->stale, t->stale, RLX);
	if (t->late)
		atomic_fetch_add_explicit(&q->late_link, t->late, RLX);
	if (t->kept && kept_to)
		atomic_fetch_add_explicit(kept_to, t->kept, RLX);
	count_taken(q, t->frames, t->samples);
}

/* ---- producer side ------------------------------------------------------ */

/* Producer: picks up a new epoch (the capture-gap tracking and the tail's
 * channel count restart with it). Returns the current epoch. */
static uint64_t prod_sync(g16mic_handoff *hf)
{
	uint64_t ep = atomic_load_explicit(&hf->epoch, ACQ);

	if (ep != hf->prod_epoch) {
		hf->prod_epoch = ep;
		hf->prod_ch = 0;
		hf->have_prev = 0;
		hf->trim_held = 0;
		hf->trim_since = G16MIC_HF_TRIM_EVERY_CYCLES;
		atomic_store_explicit(&hf->tail_due, 0, RLX);
		atomic_store_explicit(&hf->tail_ch, 0, RLX);
	}
	return ep;
}

/* Producer, RT-safe: until entry h fits (fewer than cap entries from the
 * cursor to h), drops the oldest entry's rest by moving the cursor past it,
 * counted. Each failed CAS means the consumer moved the cursor forward, and
 * it cannot pass h, so the loop ends. */
static void make_room(g16mic_handoff *hf, struct hf_queue *q, uint64_t h, uint64_t ep)
{
	uint64_t c = atomic_load_explicit(&q->cursor, ACQ);

	for (;;) {
		uint64_t idx = c >> HF_OFF_BITS, off = c & HF_OFF_MASK;
		if (h - idx < hf->cap)
			return;
		/* the producer wrote this entry: its fields are consistent */
		struct hf_entry *en = slot(hf, q, idx);
		uint64_t fr = atomic_load_explicit(&en->frames, RLX);
		uint64_t ech = (uint64_t)atomic_load_explicit(&en->channels, RLX);
		uint64_t rest = fr > off ? fr - off : 0;
		uint64_t nc = cur_pack(idx + 1, 0);
		if (atomic_compare_exchange_strong_explicit(&q->cursor, &c, nc, memory_order_acq_rel, ACQ)) {
			struct hf_tally t = { .frames = rest, .samples = rest * ech };
			tally_skip(&t, atomic_load_explicit(&en->epoch, RLX), atomic_load_explicit(&en->push_seq, RLX), ep,
				   atomic_load_explicit(&q->link_seq, ACQ), rest * ech);
			if (t.kept)
				atomic_fetch_add_explicit(&q->overflow_cycles, 1, RLX);
			tally_apply(q, &t, &q->overflow);
			c = nc;
		}
	}
}

/* Producer, RT-safe: what this output will still deliver of the current
 * stream, from its read position: the frames (*frames) and entries (return)
 * of the current epoch pushed at or after its link. Entries of an earlier
 * epoch or queued before the link are dropped at its next run, so they are
 * no latency. At most cap entries are walked; the producer wrote them all,
 * so their fields are consistent. */
static uint64_t live_queued(g16mic_handoff *hf, struct hf_queue *q, uint64_t ep, uint64_t *frames)
{
	uint64_t c = atomic_load_explicit(&q->cursor, ACQ);
	uint64_t h = atomic_load_explicit(&q->head, RLX);
	uint64_t link = atomic_load_explicit(&q->link_seq, ACQ);
	uint64_t off = c & HF_OFF_MASK, n = 0, f = 0;

	for (uint64_t i = c >> HF_OFF_BITS; i < h; i++, off = 0) {
		struct hf_entry *en = slot(hf, q, i);
		uint64_t fr = atomic_load_explicit(&en->frames, RLX);
		if (atomic_load_explicit(&en->epoch, RLX) != ep || atomic_load_explicit(&en->push_seq, RLX) < link)
			continue;
		n++;
		f += fr > off ? fr - off : 0;
	}
	if (frames)
		*frames = f;
	return n;
}

/* Producer, RT-safe: the start window of a (re)linked output, after it
 * pushed cycle seq. Right after the push of a graph cycle an output that is
 * on time holds that cycle alone: in the normal order the capture runs
 * first and the output takes it in the same cycle; when PipeWire runs the
 * output before the capture (as it can for the first cycles after a link:
 * the output is then scheduled by the link as well as by the trigger, and
 * its trigger is refused) it has already taken the previous cycle and
 * holds the new one alone too. Holding MORE than that cycle means it is
 * behind: it ran before the capture for a while, took the previous cycle
 * each time, and now runs in the normal order a cycle late, which without
 * this would last for good (test_pw_live step 6: latency 1296 = 272 + 1024,
 * queue_added_frames 1024). Within the window the output then restarts at
 * this cycle: link_seq moves up to seq and its next run drops what came
 * before (late_link_discarded, not a loss). An output that is on time is
 * never touched; after the window a late run is added latency (and the
 * trim's business). */
static void start_window(g16mic_handoff *hf, struct hf_queue *q, uint64_t ep, uint64_t seq)
{
	int left = atomic_load_explicit(&q->start_left, ACQ);

	/* the engine tail is the end of the stream, never a backlog: the last
	 * accepted cycle still queued before it must arrive */
	if (left <= 0 || hf->in_tail)
		return;
	if (live_queued(hf, q, ep, NULL) > 1)
		atomic_store_explicit(&q->link_seq, seq, REL);
	/* a restart (start_output) meanwhile wins */
	atomic_compare_exchange_strong_explicit(&q->start_left, &left, left - 1, memory_order_acq_rel, RLX);
}

/* Producer, RT-safe: one cycle into one output's queue, if it is consuming. */
static void push_one(g16mic_handoff *hf, int out, uint64_t ep, uint64_t seq, const float *src, size_t frames, int ch)
{
	struct hf_queue *q = &hf->q[out];

	if (!atomic_load_explicit(&q->consuming, ACQ))
		return;
	uint64_t n = (uint64_t)frames * (uint64_t)ch;
	uint64_t h = atomic_load_explicit(&q->head, RLX);

	make_room(hf, q, h, ep);
	struct hf_entry *en = slot(hf, q, h);
	atomic_store_explicit(&en->epoch, ep, RLX);
	atomic_store_explicit(&en->push_seq, seq, RLX);
	atomic_store_explicit(&en->frames, (uint32_t)frames, RLX);
	atomic_store_explicit(&en->channels, ch, RLX);
	memcpy(en->samples, src, (size_t)n * sizeof(float));
	atomic_fetch_add_explicit(&q->pushed_f, (uint64_t)frames, RLX);
	atomic_fetch_add(&q->pushed_s, n);
	atomic_store_explicit(&q->head, h + 1, REL);

	uint64_t idx = atomic_load_explicit(&q->cursor, ACQ) >> HF_OFF_BITS;
	uint64_t depth = h + 1 - idx;
	bump_max(&q->max_depth, depth < hf->cap ? depth : hf->cap);
	start_window(hf, q, ep, seq);
}

/* Producer: the cycle in the scratch buffers to both outputs, under one
 * sequence number. */
static void push_cycle(g16mic_handoff *hf, uint64_t ep, size_t frames, int ch)
{
	uint64_t seq = atomic_load_explicit(&hf->push_seq, RLX);

	push_one(hf, G16MIC_HF_PROCESSED, ep, seq, hf->scratch_mono, frames, 1);
	push_one(hf, G16MIC_HF_RAW, ep, seq, hf->scratch_raw, frames, ch);
	atomic_store_explicit(&hf->push_seq, seq + 1, REL);
}

/* Producer: flushes the engine's tail into the queues (nothing if this epoch
 * accepted no input) and marks the hand-off stopped, after the tail is
 * published (an output that sees STOPPED sees the tail queued). */
static size_t push_tail(g16mic_handoff *hf, g16mic_engine *e, uint64_t ep)
{
	size_t total = 0, n;
	int ch = hf->prod_ch;

	if (e && ch > 0) {
		hf->in_tail = 1;
		while ((n = g16mic_engine_flush(e, hf->scratch_raw, hf->scratch_mono, hf->max_frames)) > 0) {
			push_cycle(hf, ep, n, ch);
			total += n;
		}
		hf->in_tail = 0;
	}
	atomic_fetch_add_explicit(&hf->tail_flushed, (uint64_t)total, RLX);
	atomic_store_explicit(&hf->tail_due, 0, RLX);
	atomic_store_explicit(&hf->stop, G16MIC_HF_STOPPED, REL);
	return total;
}

/* Producer, RT-safe: 1 if every sample of the cycle in the scratch buffers
 * (the raw channels and the processed mono) is below the quiet threshold;
 * a non-finite sample is not quiet. */
static int cycle_quiet(const g16mic_handoff *hf, size_t frames, int ch)
{
	const float thr = G16MIC_HF_TRIM_QUIET_PEAK;

	for (size_t i = 0; i < frames; i++)
		if (!(fabsf(hf->scratch_mono[i]) < thr))
			return 0;
	for (size_t i = 0; i < frames * (size_t)ch; i++)
		if (!(fabsf(hf->scratch_raw[i]) < thr))
			return 0;
	return 1;
}

/* Producer, RT-safe: the latency trim (g16mic_handoff.h). Decided once per
 * capture cycle, before the push, for both outputs at once. Returns 1 when
 * this cycle is withheld from every consuming output (counted as
 * latency_trimmed), 0 when it is pushed as usual. Trims only when:
 *   - at least one output is consuming, none is in its start window, and
 *     every consuming output holds at least a whole cycle (this cycle's
 *     frames) of the current stream before the push: an output on time
 *     holds nothing then (target G16MIC_HF_TARGET_CYCLES = 0), so only
 *     added latency is trimmed, and only when BOTH outputs carry it, which
 *     keeps processed and raw sample aligned (each loses the same cycle);
 *   - that has held for every cycle of at least G16MIC_HF_TRIM_HOLDOFF_MS
 *     (counted in pushed frames, no clock read);
 *   - G16MIC_HF_TRIM_EVERY_CYCLES cycles have passed since the last trim;
 *   - the cycle is quiet on every raw channel and on the processed mono
 *     (cycle_quiet): never inside speech or a marker.
 * The cycle withheld is the newest; the outputs go on from their oldest
 * queued audio, so each delivers one cycle less ahead of the next. Nothing
 * already queued is touched, so no consumer can be racing it. */
static int trim_cycle(g16mic_handoff *hf, uint64_t ep, size_t frames, int ch)
{
	int any = 0, excess = 1;

	if (hf->trim_since < G16MIC_HF_TRIM_EVERY_CYCLES)
		hf->trim_since++;
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &hf->q[o];
		uint64_t f = 0;
		if (!atomic_load_explicit(&q->consuming, ACQ))
			continue;
		any = 1;
		if (atomic_load_explicit(&q->start_left, ACQ) > 0) {
			excess = 0;
			continue;
		}
		live_queued(hf, q, ep, &f);
		if (f < (uint64_t)frames)
			excess = 0;
	}
	if (!any || !excess) {
		hf->trim_held = 0;
		return 0;
	}
	if (hf->trim_held < HF_TRIM_HOLDOFF_FRAMES)
		hf->trim_held += (uint64_t)frames;
	if (hf->trim_held < HF_TRIM_HOLDOFF_FRAMES || hf->trim_since < G16MIC_HF_TRIM_EVERY_CYCLES)
		return 0;
	if (!cycle_quiet(hf, frames, ch))
		return 0;
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &hf->q[o];
		if (!atomic_load_explicit(&q->consuming, ACQ))
			continue;
		uint64_t n = (uint64_t)frames * (uint64_t)(o == G16MIC_HF_RAW ? ch : 1);
		atomic_fetch_add_explicit(&q->trimmed, n, RLX);
		atomic_fetch_add_explicit(&q->trimmed_cycles, 1, RLX);
	}
	atomic_fetch_add_explicit(&hf->trims, 1, RLX);
	hf->trim_since = 0;
	return 1;
}

/* Producer: counts `frames` frames per consuming output into a producer-side
 * counter (oversize or width mismatch). */
static void count_unpushed(g16mic_handoff *hf, size_t frames, int ch, int width)
{
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &hf->q[o];
		if (!atomic_load_explicit(&q->consuming, ACQ))
			continue;
		uint64_t n = (uint64_t)frames * (uint64_t)(o == G16MIC_HF_RAW ? ch : 1);
		atomic_fetch_add_explicit(width ? &q->width : &q->oversize, n, RLX);
	}
}

void g16mic_handoff_capture(g16mic_handoff *hf, g16mic_engine *e, const float *in, size_t frames, int ch, uint64_t ticks, int have_ticks)
{
	if (!hf)
		return;
	uint64_t ep = prod_sync(hf);
	int st = atomic_load_explicit(&hf->stop, ACQ);

	if (st == G16MIC_HF_STOP_REQUESTED) {
		/* the stop instant: this cycle's input is not accepted; the
		 * engine's tail is the last thing the outputs get */
		push_tail(hf, e, ep);
		return;
	}
	if (st != G16MIC_HF_RUNNING)
		return;  /* stopped: harmless, the host keeps calling during the drain */

	/* frames the graph moved on that this capture never saw */
	if (have_ticks) {
		if (hf->have_prev && ticks > hf->prev_ticks + hf->prev_frames)
			atomic_fetch_add_explicit(&hf->capture_gap, ticks - (hf->prev_ticks + hf->prev_frames), RLX);
		hf->prev_ticks = ticks;
		hf->prev_frames = (uint64_t)frames;
		hf->have_prev = 1;
	} else {
		hf->have_prev = 0;
	}

	if (!e || !in || frames == 0)
		return;
	if (ch < 1 || ch > hf->max_ch) {
		/* wider than the queues were built for: nothing of it can be
		 * carried; counted, not processed */
		count_unpushed(hf, frames, ch, 1);
		return;
	}
	size_t first = frames < hf->max_frames ? frames : hf->max_frames;

	g16mic_engine_process(e, in, first, hf->scratch_raw, hf->scratch_mono);
	if (!trim_cycle(hf, ep, first, ch))
		push_cycle(hf, ep, first, ch);
	hf->prod_ch = ch;
	atomic_store_explicit(&hf->tail_ch, ch, RLX);
	atomic_store_explicit(&hf->tail_due, (uint64_t)g16mic_engine_latency(e), RLX);
	atomic_store_explicit(&hf->last_cycle, (uint64_t)first, RLX);

	/* the rest of an oversized cycle still goes through the engine so its
	 * state stays continuous; what an entry cannot carry is counted */
	for (size_t done = first; done < frames;) {
		size_t n = frames - done < hf->max_frames ? frames - done : hf->max_frames;
		g16mic_engine_process(e, in + done * (size_t)ch, n, hf->scratch_raw, hf->scratch_mono);
		done += n;
	}
	if (frames > first)
		count_unpushed(hf, frames - first, ch, 0);
}

size_t g16mic_handoff_flush_tail(g16mic_handoff *hf, g16mic_engine *e)
{
	if (!hf)
		return 0;
	uint64_t ep = prod_sync(hf);

	return push_tail(hf, e, ep);
}

void g16mic_handoff_begin_stop(g16mic_handoff *hf)
{
	if (!hf)
		return;
	int expect = G16MIC_HF_RUNNING;
	atomic_compare_exchange_strong_explicit(&hf->stop, &expect, G16MIC_HF_STOP_REQUESTED, memory_order_acq_rel, ACQ);
}

int g16mic_handoff_stopping(const g16mic_handoff *hf)
{
	if (!hf)
		return G16MIC_HF_STOPPED;
	g16mic_handoff *m = (g16mic_handoff *)hf;  /* the casts drop const for C11's generic loads */
	return atomic_load_explicit(&m->stop, ACQ);
}

void g16mic_handoff_reset_stop(g16mic_handoff *hf)
{
	if (hf)
		atomic_store_explicit(&hf->stop, G16MIC_HF_RUNNING, REL);
}

size_t g16mic_handoff_pending(const g16mic_handoff *hf, int out)
{
	if (!hf || !valid_out(out))
		return 0;
	g16mic_handoff *m = (g16mic_handoff *)hf;
	struct hf_queue *q = &m->q[out];

	if (!atomic_load_explicit(&q->consuming, ACQ))
		return 0;
	uint64_t n = queued_samples(q);
	if (atomic_load_explicit(&m->stop, ACQ) == G16MIC_HF_STOP_REQUESTED) {
		uint64_t ch = out == G16MIC_HF_RAW ? (uint64_t)atomic_load_explicit(&m->tail_ch, RLX) : 1;
		n += atomic_load_explicit(&m->tail_due, RLX) * ch;
	}
	return (size_t)n;
}

int g16mic_handoff_drained(const g16mic_handoff *hf, int out)
{
	if (!hf || !valid_out(out))
		return 1;
	g16mic_handoff *m = (g16mic_handoff *)hf;
	struct hf_queue *q = &m->q[out];

	if (!atomic_load_explicit(&q->consuming, ACQ))
		return 1;
	/* run_end first, run_begin last (all sequentially consistent): a run
	 * that has already taken from the queue has stored its run_begin, so
	 * an emptied queue seen here with run_begin != run_end is a run still
	 * handing out its buffer */
	uint64_t end = atomic_load(&q->run_end);
	uint64_t real = atomic_load(&q->last_real);
	if (atomic_load_explicit(&m->stop, ACQ) != G16MIC_HF_STOPPED)
		return 0;
	if (queued_samples(q) != 0)
		return 0;
	if (atomic_load(&q->run_begin) != end)
		return 0;
	return real == 0 || end > real;
}

void g16mic_handoff_note_trigger(g16mic_handoff *hf, int out, int res)
{
	if (!hf || !valid_out(out) || res >= 0)
		return;
	if (!atomic_load_explicit(&hf->q[out].consuming, ACQ))
		return;
	atomic_fetch_add_explicit(&hf->trigger_refused, 1, RLX);
	atomic_store_explicit(&hf->trigger_errno, -res, RLX);
}

/* ---- consumer side ------------------------------------------------------ */

/* Consumer, RT-safe: one attempt to copy up to want frames from the cursor
 * into dst and publish the advanced cursor. Returns 1 with *written and *t
 * filled when the move is published (or there was nothing to move), 0 when
 * the copy must be thrown away (the producer moved the cursor, a new epoch
 * began during the copy, or a slot was being rewritten). */
static int take_once(g16mic_handoff *hf, int out, float *dst, size_t want, int ch, size_t *written, struct hf_tally *t)
{
	struct hf_queue *q = &hf->q[out];
	uint64_t ep = atomic_load_explicit(&hf->epoch, ACQ);
	uint64_t link = atomic_load_explicit(&q->link_seq, ACQ);
	uint64_t c = atomic_load_explicit(&q->cursor, ACQ);
	uint64_t h = atomic_load_explicit(&q->head, ACQ);
	uint64_t i = c >> HF_OFF_BITS, o = c & HF_OFF_MASK;
	size_t w = 0;

	memset(t, 0, sizeof *t);
	while (i < h) {
		struct hf_entry *en = slot(hf, q, i);
		uint64_t fr = atomic_load_explicit(&en->frames, RLX);
		int ech = atomic_load_explicit(&en->channels, RLX);
		uint64_t eep = atomic_load_explicit(&en->epoch, RLX);
		uint64_t seq = atomic_load_explicit(&en->push_seq, RLX);
		if (fr == 0 || fr > hf->max_frames || ech < 1 || ech > q->max_ch || o >= fr)
			return 0;  /* being rewritten after a drop: the cursor moved */
		uint64_t rest = fr - o;
		if (eep != ep || seq < link) {
			/* never written to dst: dropped, counted */
			tally_skip(t, eep, seq, ep, link, rest * (uint64_t)ech);
			t->frames += rest;
			t->samples += rest * (uint64_t)ech;
			i++;
			o = 0;
			continue;
		}
		if (w == want)
			break;
		size_t n = rest < want - w ? (size_t)rest : want - w;
		float *d = dst + w * (size_t)ch;
		if (ech == ch) {
			memcpy(d, en->samples + o * (uint64_t)ech, n * (size_t)ch * sizeof(float));
			t->delivered += (uint64_t)n * (uint64_t)ch;
		} else {
			/* the output is being rebuilt for another width:
			 * nothing of this cycle can be carried */
			memset(d, 0, n * (size_t)ch * sizeof(float));
			t->width += (uint64_t)n * (uint64_t)ech;
		}
		t->frames += n;
		t->samples += (uint64_t)n * (uint64_t)ech;
		w += n;
		o += n;
		if (o == fr) {
			i++;
			o = 0;
		}
	}
	*written = w;
	if (hf->hook)
		hf->hook(hf->hook_arg, out);
	/* a new epoch during the copy: what was copied may be the old
	 * stream's (or a new entry was taken for stale) */
	if (atomic_load_explicit(&hf->epoch, ACQ) != ep)
		return 0;
	uint64_t nc = cur_pack(i, o);
	if (nc == c)
		return 1;
	return atomic_compare_exchange_strong_explicit(&q->cursor, &c, nc, memory_order_acq_rel, ACQ);
}

size_t g16mic_handoff_output(g16mic_handoff *hf, int out, float *dst, size_t max_frames, int ch, size_t requested)
{
	if (!hf || !valid_out(out) || !dst || ch < 1 || max_frames == 0)
		return 0;
	struct hf_queue *q = &hf->q[out];
	uint64_t run = atomic_load_explicit(&q->run_end, RLX) + 1;  /* this consumer is its only writer */

	/* where a (re)linked output starts is the producer's decision
	 * (start_window): it moves link_seq, and take_once below drops what
	 * came before it as late_link_discarded */
	size_t lc = (size_t)atomic_load_explicit(&hf->last_cycle, RLX);
	size_t want = requested ? requested : lc;

	atomic_store(&q->run_begin, run);
	if (want > max_frames) {
		/* never silently cut: the graph asked for more than the buffer
		 * holds (what is queued stays queued) */
		atomic_fetch_add_explicit(&q->oversize, (uint64_t)(want - max_frames) * (uint64_t)ch, RLX);
		want = max_frames;
	}
	/* the stop state before the take: STOPPED here means the tail is
	 * already queued, so an empty queue below is the end of the stream */
	int st = atomic_load_explicit(&hf->stop, ACQ);
	size_t w = 0;
	struct hf_tally t;
	int ok = 0;

	for (int r = 0; r < HF_MAX_RETRY && !ok; r++) {
		if (r)
			atomic_fetch_add_explicit(&q->retries, 1, RLX);
		ok = take_once(hf, out, dst, want, ch, &w, &t);
	}
	if (ok) {
		tally_apply(q, &t, NULL);
	} else {
		/* the producer kept dropping under us (an overflow every
		 * attempt, all counted): nothing taken this run */
		w = 0;
	}

	uint64_t left = queued_frames(q);
	if (left > 0 && left >= (uint64_t)lc)
		atomic_fetch_add_explicit(&q->late_runs, 1, RLX);
	bump_max(&q->max_added, left);

	int real = w > 0;
	size_t ret = want;
	if (w < want) {
		if (st == G16MIC_HF_STOPPED && w == 0) {
			ret = 0;  /* end of stream, not a shortfall */
		} else {
			memset(dst + w * (size_t)ch, 0, (want - w) * (size_t)ch * sizeof(float));
			atomic_fetch_add_explicit(st == G16MIC_HF_STOPPED ? &q->eos_pad : &q->underflow,
						  (uint64_t)(want - w) * (uint64_t)ch, RLX);
		}
	}
	if (real)
		atomic_store(&q->last_real, run);
	atomic_store(&q->run_end, run);
	return ret;
}

void g16mic_handoff_abandon(g16mic_handoff *hf, int cause)
{
	if (!hf)
		return;
	uint64_t ep = atomic_load_explicit(&hf->epoch, ACQ);

	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &hf->q[o];
		uint64_t link = atomic_load_explicit(&q->link_seq, ACQ);
		struct hf_tally t;

		/* not RT: retried until the move is published (a producer, if
		 * one still runs, only moves the cursor forward) */
		for (;;) {
			uint64_t c = atomic_load_explicit(&q->cursor, ACQ);
			uint64_t h = atomic_load_explicit(&q->head, ACQ);
			uint64_t off = c & HF_OFF_MASK;
			memset(&t, 0, sizeof t);
			for (uint64_t i = c >> HF_OFF_BITS; i < h; i++, off = 0) {
				struct hf_entry *en = slot(hf, q, i);
				uint64_t fr = atomic_load_explicit(&en->frames, RLX);
				uint64_t ech = (uint64_t)atomic_load_explicit(&en->channels, RLX);
				uint64_t rest = fr > off ? fr - off : 0;
				tally_skip(&t, atomic_load_explicit(&en->epoch, RLX), atomic_load_explicit(&en->push_seq, RLX),
					   ep, link, rest * ech);
				t.frames += rest;
				t.samples += rest * ech;
			}
			uint64_t nc = cur_pack(h, 0);
			if (nc == c || atomic_compare_exchange_strong_explicit(&q->cursor, &c, nc, memory_order_acq_rel, ACQ))
				break;
		}
		tally_apply(q, &t, cause == G16MIC_HF_LOST_SOURCE ? &q->source_lost : &q->drain_lost);
	}
}

/* ---- telemetry ---------------------------------------------------------- */

void g16mic_handoff_get_stats(const g16mic_handoff *hf, g16mic_hf_stats *st)
{
	if (!st)
		return;
	memset(st, 0, sizeof *st);
	if (!hf)
		return;
	g16mic_handoff *m = (g16mic_handoff *)hf;  /* the casts drop const for C11's generic loads */

	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		struct hf_queue *q = &m->q[o];
		g16mic_hf_out_stats *s = &st->out[o];
		/* cursor first: head only grows, so head - entry never underflows */
		uint64_t idx = atomic_load_explicit(&q->cursor, ACQ) >> HF_OFF_BITS;
		uint64_t h = atomic_load_explicit(&q->head, ACQ);

		s->delivered = atomic_load_explicit(&q->delivered, RLX);
		s->underflow = atomic_load_explicit(&q->underflow, RLX);
		s->eos_pad = atomic_load_explicit(&q->eos_pad, RLX);
		s->overflow = atomic_load_explicit(&q->overflow, RLX);
		s->overflow_cycles = atomic_load_explicit(&q->overflow_cycles, RLX);
		s->oversize = atomic_load_explicit(&q->oversize, RLX);
		s->width_mismatch = atomic_load_explicit(&q->width, RLX);
		s->stale_dropped = atomic_load_explicit(&q->stale, RLX);
		s->late_link_discarded = atomic_load_explicit(&q->late_link, RLX);
		s->drain_lost = atomic_load_explicit(&q->drain_lost, RLX);
		s->source_lost_tail = atomic_load_explicit(&q->source_lost, RLX);
		s->late_runs = atomic_load_explicit(&q->late_runs, RLX);
		s->retries = atomic_load_explicit(&q->retries, RLX);
		s->latency_trimmed = atomic_load_explicit(&q->trimmed, RLX);
		s->latency_trimmed_cycles = atomic_load_explicit(&q->trimmed_cycles, RLX);
		s->max_depth = atomic_load_explicit(&q->max_depth, RLX);
		s->depth = h - idx > m->cap ? m->cap : h - idx;
		s->added_frames = queued_frames(q);
		s->max_added_frames = atomic_load_explicit(&q->max_added, RLX);
	}
	st->capture_gap_frames = atomic_load_explicit(&m->capture_gap, RLX);
	st->tail_flushed_frames = atomic_load_explicit(&m->tail_flushed, RLX);
	st->trigger_refused = atomic_load_explicit(&m->trigger_refused, RLX);
	st->trigger_errno = atomic_load_explicit(&m->trigger_errno, RLX);
	st->last_cycle_frames = atomic_load_explicit(&m->last_cycle, RLX);
	st->latency_trims = atomic_load_explicit(&m->trims, RLX);
}

uint64_t g16mic_handoff_lost_samples(const g16mic_hf_stats *st)
{
	uint64_t n = 0;

	if (!st)
		return 0;
	for (int o = 0; o < G16MIC_HF_NOUT; o++) {
		const g16mic_hf_out_stats *s = &st->out[o];
		n += s->overflow + s->oversize + s->width_mismatch + s->stale_dropped + s->drain_lost + s->source_lost_tail;
	}
	return n;
}
