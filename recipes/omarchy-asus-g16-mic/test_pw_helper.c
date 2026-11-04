/* SPDX-License-Identifier: MIT */
/* test_pw_helper.c: the PipeWire client side of test_pw_live.sh. A test-only
 * program, never installed. It talks to whatever daemon PIPEWIRE_REMOTE and
 * PIPEWIRE_RUNTIME_DIR name; test_pw_live.sh points them at its private one.
 *
 *   source --name N --channels C [--class Audio/Source] [--props k=v,...]
 *          [--start K] [--driver [--ppm P]] [--quiet] --log FILE
 *       An output stream that looks like a microphone: media.class
 *       Audio/Source (or --class), node.name N, F32 48 kHz, C channels (1:
 *       MONO, 2: FL FR, more: AUX0..), no autoconnect. Frame k carries
 *       sig(k, c) on channel c, a deterministic 24-bit value scaled to
 *       [-0.1, 0.1) (peak -20 dBFS, far below the engine's limiter ceiling,
 *       so omni stays linear). k starts at --start (default 0). Every buffer
 *       adds a line "<graph position> <first k> <frames>" to FILE. Runs until
 *       SIGTERM or SIGINT; exits 0.
 *       --quiet scales the signal by 2^-5 (30 dB down: about -50 dBFS peak),
 *       the level of quiet speech trailing off, and above g16-mic's
 *       quiet-only latency trim threshold (G16MIC_HF_TRIM_QUIET_DBFS, -60
 *       dBFS), so a cycle of it is never trimmed; a power of two keeps every
 *       value exact and unique, so compare --quiet still matches bit for bit.
 *       FILE's first line then ends in " quiet=1".
 *       --driver makes it a source on its own clock, like a sound card: the
 *       stream is a driver (PW_STREAM_FLAG_DRIVER, priority.driver 30000,
 *       above the test daemon's dummy driver, and a node.group of its own),
 *       so whatever links to it runs on its cycles. A timer on absolute
 *       CLOCK_MONOTONIC deadlines starts a cycle every 1024 frames at 48 kHz
 *       scaled by (1 + P * 1e-6) (--ppm, -2000..2000, default 0: P > 0 runs
 *       slower than nominal), but only while the stream is driving; when
 *       another driver won, the stream follows it as without --driver. FILE
 *       gets "# source: driving" once it has driven a cycle, or
 *       "# source: not driving" after about 1 s of streaming without ever
 *       driving one, and a "# source: ..." tick count at exit.
 *   tap --target NODE_NAME --out FILE --channels C [--positions P,...]
 *       --seconds S
 *       An input stream with target.object NODE_NAME and node.dont-fallback,
 *       linked by the session manager. Writes S seconds of interleaved F32
 *       to FILE and "<graph position> <frames>" per buffer to FILE.ticks.
 *       Exits 0 with S seconds of data, 1 with less (or none), 2 if the
 *       stream negotiated another format.
 *   graph --dump
 *       One line per core, node, port, link, device and metadata object (see
 *       cmd_graph for the format), for the script to assert on without jq.
 *   compare --input-log SRC.log --raw RAW [--processed PROC] --channels C
 *       --latency L [--strict] [--quiet] [--last-pos P --last-frames F]
 *       [--report-gaps] [--expect-gap N [--expect-zero-fill Z]]
 *       [--old-log OLD.log] [--allow-delays]
 *       Checks tap files against the source's log: RAW must be the input bit
 *       for bit (gaps reported), its end-to-end latency must be exactly L
 *       (host.c processes and delivers each capture cycle in the same graph
 *       cycle), and PROC, at the same graph positions, must equal an offline
 *       omni engine fed the same frames. --strict also requires RAW to be
 *       one contiguous run of input frames: no zero-filled frame after the
 *       first input frame, no forward gap, no repeat, nothing that is not
 *       input, and at least 90% of its frames matched. With --strict,
 *       --latency is optional; without it the latency and PROC checks are
 *       skipped (and say so). PASS/FAIL lines; exit 0 if all pass, 1
 *       otherwise.
 *       --quiet: the source ran with --quiet (the input is sig(k, c) * 2^-5).
 *       --allow-delays: a graph xrun (a node of the chain ran late, without
 *       RT under load) may delay the stream, never cut it: PipeWire gives
 *       the tap a quantum of silence for a cycle g16-mic's output missed, or
 *       the tap's own node misses a cycle (its graph position jumps), and
 *       the audio waits in g16-mic's queue. Zero frames between input
 *       frames and the tap's position jumps are then delays: --strict
 *       allows those zero frames (and no others), --report-gaps expects
 *       them unless --expect-zero-fill says otherwise, and a rise of the
 *       latency above L is accepted only as far as those delays before
 *       the frame cover it, so every frame must still be the next input
 *       frame at exactly L plus at most the delays the tap shows. A forward gap where the tap's own position
 *       jumped by at least as much (and by at most 4096 frames) is the
 *       tap's own loss, not g16-mic's: its node missed those cycles and
 *       PipeWire moved on; it is reported apart and not in the gap counts.
 *       Prints "delay_zero_frames=<n>", "delay_skip_frames=<n>" and
 *       "consumer_lost_frames=<n>". Without it, all of them count against
 *       the checks. "latency_first=<n>" and "latency_last=<n>" (measured, at
 *       the first and the last timed frame) are printed either way, with
 *       or without --latency.
 *       --last-pos P --last-frames F (needs --latency): every input frame at
 *       graph positions P..P+F-1 (g16-mic's last accepted cycle, from its
 *       stop log) must be in RAW at graph position + L, bit for bit, and (with
 *       --processed) PROC there must equal an offline omni engine fed the
 *       same input and then flushed with g16mic_engine_flush(), the tail a
 *       graceful stop delivers (with --allow-delays at graph position + L
 *       plus the delay accepted by then: it came before the window). Prints
 *       "last_missing=<n>", the positions
 *       whose raw or processed frame is missing or wrong; passes only if 0.
 *       --report-gaps (--latency optional): prints, for RAW,
 *       "gap_frames_total=<n>" (input frames skipped by forward jumps),
 *       "repeat_frames=<n>" (raw frames at or behind the furthest input
 *       frame already seen), "zero_fill_frames=<n>" (zero frames between the
 *       first and the last input frame), "not_input_frames=<n>" and
 *       "last_frame=<k>" (the furthest input frame, -1 if none).
 *       With --report-gaps it also prints "gap_count=<n>" (forward jumps),
 *       "trailing_zero_frames=<n>" (zero frames after the last input frame),
 *       "eos_zero_frames=<n>" (the zeros completing the tap buffer that
 *       holds the last input frame: a zero-padded last quantum) and
 *       "after_eos_frames=<n>" (frames in later tap buffers; not judged) and
 *       "src_clock_skip_frames=<n>" (graph frames the source's clock moved on
 *       without the source producing, between the tap's first and furthest
 *       input frame: a driver that skipped a cycle).
 *       --expect-gap N (implies --report-gaps) passes only when
 *       gap_frames_total == N exactly and there is no repeat, zero fill or
 *       non-input frame: the loss is exactly the counted amount.
 *       --expect-zero-fill Z (with --expect-gap) expects exactly Z zero
 *       frames between input frames instead of none (counted underflow).
 *       --old-log OLD.log: the previous stream's source log (an earlier
 *       source of the same name). A raw frame of that stream is stale:
 *       prints "stale_frames=<n>" and "stale_lead_frames=<n>" (before the
 *       first new input frame) and passes only if there are none. Stale
 *       frames also count as not input.
 *
 * "Graph position" is the driver's clock position for the cycle (its
 * spa_io_position, in 48 kHz samples), the same for every node of one
 * driver, so the raw and processed taps can be lined up frame by frame.
 *
 * The real-time callbacks (source and tap process) run on PipeWire's data
 * thread: they only fill and copy into memory allocated before the stream
 * connects, and publish counts with atomics. The main thread writes files.
 */
#include <errno.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/defs.h>
#include <spa/utils/result.h>

#include "g16mic.h"

#define EXIT_USAGE 64
#define SIG_SEED 0x6731366d69630001ull
#define SIG_SCALE (0.1f / 8388608.0f)
#define SIG_QUIET_GAIN (1.0f / 32.0f)  /* --quiet: 2^-5, exact; above the -60 dBFS trim threshold */
#define POS_UNKNOWN UINT64_MAX
#define CONSUMER_XRUN_MAX 4096u      /* --allow-delays: the longest own miss of a tap's node taken as its xrun */
#define SRC_RECS (1u << 18)          /* source buffers logged: over an hour at 1024 frames */
#define TAP_RECS (1u << 16)
#define TICK_MS 100
#define TAP_GRACE_S 15               /* a tap gives up this long after its S seconds */
#define FEED_CHUNK 1024
#define SRC_DRIVER_FRAMES 1024       /* source --driver: frames per cycle it drives */
#define SRC_RESYNC_CYCLES 8          /* ... restarts its schedule after a stall this long */
#define SRC_NOT_DRIVING_CYCLES 47    /* ... says "not driving" after about 1 s of cycles it did not drive */
#define SRC_DRIVER_PRIORITY "30000"  /* above the test daemon's Dummy-Driver (20000) */

/* compare: the processed output is checked against an offline engine that
 * starts from silence at the first frame of each contiguous raw segment,
 * while the live engine had been running before it. The engine's DC blocker
 * (5 Hz, time constant about 1528 samples) carries that difference longest;
 * after SETTLE_FRAMES (0.5 s, 15.7 time constants) it has decayed by
 * e^-15.7 (about 1.5e-7) of a signal at most 0.1, so what is left is float
 * rounding in the filter states, far below TOL. */
#define SETTLE_FRAMES 24000
#define MIN_SEGMENT (SETTLE_FRAMES + 4800)
#define TOL 1e-5
#define LAG_SEARCH 16384
#define LAG_WINDOW 4096

/* ---- the test signal ------------------------------------------------------ */

static uint64_t splitmix64(uint64_t x)
{
	x += 0x9e3779b97f4a7c15ull;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
	return x ^ (x >> 31);
}

/* 1, or SIG_QUIET_GAIN with --quiet (source and compare); set once in main
 * before any stream or check runs. */
static float sig_gain = 1.0f;

/* Integer hashing and one exact int-to-float conversion and multiply, so the
 * source and compare produce the same bits. The gain is a power of two, so
 * the second multiply is exact (1: the same bits as without it). */
static float sig(int64_t k, int c)
{
	uint64_t h = splitmix64(SIG_SEED ^ ((uint64_t)k * 8u + (uint64_t)c));
	int32_t v = (int32_t)(h >> 40) - 8388608;  /* 24 bits -> [-2^23, 2^23) */

	return (float)v * SIG_SCALE * sig_gain;
}

static uint32_t fbits(float x)
{
	uint32_t u;

	memcpy(&u, &x, sizeof u);
	return u;
}

/* ---- small helpers -------------------------------------------------------- */

struct opts {
	const char *name, *cls, *props, *log, *target, *out, *positions;
	const char *input_log, *raw, *processed, *old_log;
	long channels, start, latency, ppm;
	long last_pos, last_frames, expect_gap, expect_zero_fill;  /* -1, 0, -1, -1: not given */
	int allow_delays;                                          /* --allow-delays */
	double seconds;
	int driver, strict, quiet, report_gaps;  /* flags: --driver, --strict, --quiet, --report-gaps (no value) */
};

static int parse_long(const char *s, long lo, long hi, long *out)
{
	char *end;

	errno = 0;
	long v = strtol(s, &end, 10);
	if (errno || end == s || *end != 0 || v < lo || v > hi)
		return -1;
	*out = v;
	return 0;
}

static int parse_double(const char *s, double lo, double hi, double *out)
{
	char *end;

	errno = 0;
	double v = strtod(s, &end);
	if (errno || end == s || *end != 0 || !isfinite(v) || v < lo || v > hi)
		return -1;
	*out = v;
	return 0;
}

static int bad_opt(const char *k, const char *v)
{
	fprintf(stderr, "test_pw_helper: bad value '%s' for %s\n", v, k);
	return -1;
}

static int parse_opts(int argc, char **argv, struct opts *o)
{
	memset(o, 0, sizeof *o);
	o->latency = -1;
	o->last_pos = -1;
	o->expect_gap = -1;
	o->expect_zero_fill = -1;
	for (int i = 0; i < argc; i++) {
		const char *k = argv[i], *v;

		if (strcmp(k, "--driver") == 0) {
			o->driver = 1;
			continue;
		}
		if (strcmp(k, "--strict") == 0) {
			o->strict = 1;
			continue;
		}
		if (strcmp(k, "--allow-delays") == 0) {
			o->allow_delays = 1;
			continue;
		}
		if (strcmp(k, "--quiet") == 0) {
			o->quiet = 1;
			continue;
		}
		if (strcmp(k, "--report-gaps") == 0) {
			o->report_gaps = 1;
			continue;
		}
		v = i + 1 < argc ? argv[i + 1] : NULL;
		i++;
		if (!v) {
			fprintf(stderr, "test_pw_helper: %s needs a value\n", k);
			return -1;
		}
		if (strcmp(k, "--name") == 0)
			o->name = v;
		else if (strcmp(k, "--class") == 0)
			o->cls = v;
		else if (strcmp(k, "--props") == 0)
			o->props = v;
		else if (strcmp(k, "--log") == 0)
			o->log = v;
		else if (strcmp(k, "--target") == 0)
			o->target = v;
		else if (strcmp(k, "--out") == 0)
			o->out = v;
		else if (strcmp(k, "--positions") == 0)
			o->positions = v;
		else if (strcmp(k, "--input-log") == 0)
			o->input_log = v;
		else if (strcmp(k, "--raw") == 0)
			o->raw = v;
		else if (strcmp(k, "--processed") == 0)
			o->processed = v;
		else if (strcmp(k, "--old-log") == 0)
			o->old_log = v;
		else if (strcmp(k, "--channels") == 0) {
			if (parse_long(v, 1, G16MIC_MAX_CH, &o->channels) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--start") == 0) {
			if (parse_long(v, 0, (long)1 << 40, &o->start) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--ppm") == 0) {
			if (parse_long(v, -2000, 2000, &o->ppm) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--latency") == 0) {
			if (parse_long(v, 0, 1 << 20, &o->latency) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--seconds") == 0) {
			if (parse_double(v, 0.01, 600.0, &o->seconds) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--last-pos") == 0) {
			if (parse_long(v, 0, (long)1 << 62, &o->last_pos) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--last-frames") == 0) {
			if (parse_long(v, 1, 1 << 16, &o->last_frames) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--expect-gap") == 0) {
			if (parse_long(v, 0, (long)1 << 30, &o->expect_gap) != 0)
				return bad_opt(k, v);
			o->report_gaps = 1;
		} else if (strcmp(k, "--expect-zero-fill") == 0) {
			if (parse_long(v, 0, (long)1 << 30, &o->expect_zero_fill) != 0)
				return bad_opt(k, v);
			o->report_gaps = 1;
		} else {
			fprintf(stderr, "test_pw_helper: unknown option '%s'\n", k);
			return -1;
		}
	}
	return 0;
}

static const struct { const char *name; uint32_t id; } chan_names[] = {
	{ "MONO", SPA_AUDIO_CHANNEL_MONO }, { "FL", SPA_AUDIO_CHANNEL_FL }, { "FR", SPA_AUDIO_CHANNEL_FR },
	{ "FC", SPA_AUDIO_CHANNEL_FC }, { "LFE", SPA_AUDIO_CHANNEL_LFE }, { "SL", SPA_AUDIO_CHANNEL_SL },
	{ "SR", SPA_AUDIO_CHANNEL_SR }, { "RL", SPA_AUDIO_CHANNEL_RL }, { "RR", SPA_AUDIO_CHANNEL_RR },
};

static void default_positions(int ch, uint32_t *pos)
{
	for (int i = 0; i < ch; i++)
		pos[i] = ch == 1 ? SPA_AUDIO_CHANNEL_MONO :
			 ch == 2 ? (i == 0 ? SPA_AUDIO_CHANNEL_FL : SPA_AUDIO_CHANNEL_FR) :
			 SPA_AUDIO_CHANNEL_AUX0 + (uint32_t)i;
}

/* "FL,FR" / "MONO" / "AUX0,AUX1"; exactly ch names. */
static int parse_positions(const char *s, int ch, uint32_t *pos)
{
	char buf[256];
	char *save = NULL;
	int n = 0;

	if (snprintf(buf, sizeof buf, "%s", s) >= (int)sizeof buf)
		return -1;
	for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
		uint32_t id = SPA_AUDIO_CHANNEL_UNKNOWN;
		long aux;

		if (n >= ch)
			return -1;
		for (size_t i = 0; i < SPA_N_ELEMENTS(chan_names); i++)
			if (strcmp(tok, chan_names[i].name) == 0)
				id = chan_names[i].id;
		if (id == SPA_AUDIO_CHANNEL_UNKNOWN && strncmp(tok, "AUX", 3) == 0 &&
		    parse_long(tok + 3, 0, 63, &aux) == 0)
			id = SPA_AUDIO_CHANNEL_AUX0 + (uint32_t)aux;
		if (id == SPA_AUDIO_CHANNEL_UNKNOWN)
			return -1;
		pos[n++] = id;
	}
	return n == ch ? 0 : -1;
}

/* "k=v,k2=v2" onto props. */
static int apply_props(struct pw_properties *props, const char *list)
{
	char buf[1024];
	char *save = NULL;

	if (!list)
		return 0;
	if (snprintf(buf, sizeof buf, "%s", list) >= (int)sizeof buf)
		return -1;
	for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
		char *eq = strchr(tok, '=');
		if (!eq || eq == tok)
			return -1;
		*eq = 0;
		pw_properties_set(props, tok, eq + 1);
	}
	return 0;
}

static const struct spa_pod *audio_format(struct spa_pod_builder *b, int ch, const uint32_t *pos)
{
	struct spa_audio_info_raw info;

	memset(&info, 0, sizeof info);
	info.format = SPA_AUDIO_FORMAT_F32;
	info.rate = G16MIC_RATE;
	info.channels = (uint32_t)ch;
	for (int i = 0; i < ch; i++)
		info.position[i] = pos[i];
	return spa_format_audio_raw_build(b, SPA_PARAM_EnumFormat, &info);
}

/* RT-safe: the cycle's clock position in 48 kHz samples, read from the
 * driver's spa_io_position that the stream was handed (io_changed). Every
 * node a driver runs shares that one position, so it lines up frames across
 * streams. pw_stream_get_time_n()'s ticks cannot: each stream counts them
 * from its own base, so two streams of one driver report different values
 * for the same cycle. */
static uint64_t graph_pos(struct spa_io_position *p)
{
	if (!p || p->clock.rate.num == 0 || p->clock.rate.denom == 0)
		return POS_UNKNOWN;
	return (uint64_t)((double)p->clock.position * (double)G16MIC_RATE * (double)p->clock.rate.num /
			  (double)p->clock.rate.denom + 0.5);
}

/* io_changed: keeps the position area the stream's node was given. */
static void keep_position(_Atomic(struct spa_io_position *) *slot, uint32_t id, void *area, uint32_t size)
{
	if (id != SPA_IO_Position)
		return;
	atomic_store(slot, area && size >= sizeof(struct spa_io_position) ? (struct spa_io_position *)area : NULL);
}

static void block_signals(sigset_t *s)
{
	sigemptyset(s);
	sigaddset(s, SIGINT);
	sigaddset(s, SIGTERM);
	pthread_sigmask(SIG_BLOCK, s, NULL);
}

static int wait_tick(const sigset_t *s)
{
	struct timespec ts = { .tv_sec = 0, .tv_nsec = TICK_MS * 1000000L };
	int sig_no = sigtimedwait(s, NULL, &ts);

	return sig_no > 0 ? sig_no : 0;
}

/* ---- a PipeWire connection on a thread loop -------------------------------- */

struct pwc {
	struct pw_thread_loop *tl;
	struct pw_context *ctx;
	struct pw_core *core;
	struct spa_hook core_listener;
	atomic_int core_failed;
};

static void pwc_core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
	struct pwc *p = data;

	(void)seq;
	fprintf(stderr, "test_pw_helper: PipeWire error on %u: %s (%s)\n", id, message ? message : "", spa_strerror(res));
	if (id == PW_ID_CORE && res == -EPIPE)
		atomic_store(&p->core_failed, 1);
}

static const struct pw_core_events pwc_core_events = {
	PW_VERSION_CORE_EVENTS,
	.error = pwc_core_error,
};

static int pwc_open(struct pwc *p, const char *app)
{
	p->tl = pw_thread_loop_new("test_pw_helper", NULL);
	if (!p->tl)
		return -1;
	p->ctx = pw_context_new(pw_thread_loop_get_loop(p->tl), NULL, 0);
	if (!p->ctx || pw_thread_loop_start(p->tl) < 0)
		return -1;
	pw_thread_loop_lock(p->tl);
	p->core = pw_context_connect(p->ctx, pw_properties_new(PW_KEY_APP_NAME, app, NULL), 0);
	if (!p->core) {
		pw_thread_loop_unlock(p->tl);
		fprintf(stderr, "test_pw_helper: cannot connect to PipeWire: %s\n", strerror(errno));
		return -1;
	}
	pw_core_add_listener(p->core, &p->core_listener, &pwc_core_events, p);
	pw_thread_loop_unlock(p->tl);
	return 0;
}

/* Stops the loop, destroys the stream (if any), then the connection. */
static void pwc_close(struct pwc *p, struct pw_stream **stream, struct spa_hook *stream_listener)
{
	if (p->tl)
		pw_thread_loop_stop(p->tl);
	if (stream && *stream) {
		spa_hook_remove(stream_listener);
		pw_stream_destroy(*stream);
		*stream = NULL;
	}
	if (p->core) {
		spa_hook_remove(&p->core_listener);
		pw_core_disconnect(p->core);
		p->core = NULL;
	}
	if (p->ctx)
		pw_context_destroy(p->ctx);
	if (p->tl)
		pw_thread_loop_destroy(p->tl);
	p->ctx = NULL;
	p->tl = NULL;
}

/* Disconnects with the loop locked; afterwards no process callback runs. */
static void stream_disconnect(struct pwc *p, struct pw_stream *s)
{
	if (!s)
		return;
	pw_thread_loop_lock(p->tl);
	pw_stream_disconnect(s);
	pw_thread_loop_unlock(p->tl);
}

/* ---- source ----------------------------------------------------------------- */

struct src_rec { uint64_t pos; int64_t k; uint32_t frames; };

struct src {
	struct pwc pw;
	struct pw_stream *stream;
	struct spa_hook listener;
	int ch;
	int64_t next_k;              /* data thread only */
	struct src_rec *recs;        /* SRC_RECS, allocated before connecting */
	atomic_size_t n_recs;
	_Atomic uint64_t lost;
	_Atomic(struct spa_io_position *) position;
	/* --driver: the cycle timer. Its fields are only touched on the thread
	 * loop (state_changed and the timer callback); the main thread reads
	 * the atomic counters. */
	int driver;
	struct spa_source *timer;
	double period_ns;            /* one cycle: SRC_DRIVER_FRAMES at 48 kHz, scaled by (1 + ppm * 1e-6) */
	uint64_t t0_ns, n_ticks;     /* deadline n is t0_ns + n * period_ns, on CLOCK_MONOTONIC */
	int armed;
	atomic_int driving_seen;
	_Atomic uint64_t drive_ticks, follow_ticks, resyncs;
	_Atomic uint64_t cycle_ns, next_ns;   /* the driven cycle's deadline and the next, for the clock */
};

static uint64_t mono_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* Thread loop: arms the timer at an absolute CLOCK_MONOTONIC time (the
 * clock PipeWire's loop timers run on), or disarms it (at == 0). */
static void src_timer_at(struct src *s, uint64_t at)
{
	struct timespec v = { .tv_sec = (time_t)(at / 1000000000ull), .tv_nsec = (long)(at % 1000000000ull) };
	struct pw_loop *loop = pw_thread_loop_get_loop(s->pw.tl);

	if (at == 0)
		pw_loop_update_timer(loop, s->timer, NULL, NULL, false);
	else
		pw_loop_update_timer(loop, s->timer, &v, NULL, true);
}

static uint64_t src_deadline(const struct src *s)
{
	return s->t0_ns + (uint64_t)llround((double)s->n_ticks * s->period_ns);
}

/* Thread loop, at each deadline: one cycle if this stream is the driver.
 * The next deadline is computed from t0, not from now, so wakeup latency
 * never accumulates into the source's rate. After a stall of more than
 * SRC_RESYNC_CYCLES the schedule restarts from now instead of bursting. */
static void src_on_timer(void *data, uint64_t expirations)
{
	struct src *s = data;

	(void)expirations;
	if (!s->armed)
		return;
	uint64_t this_ns = src_deadline(s);
	s->n_ticks++;
	uint64_t now = mono_ns();
	if (src_deadline(s) + (uint64_t)(SRC_RESYNC_CYCLES * s->period_ns) < now) {
		atomic_fetch_add(&s->resyncs, 1);
		s->t0_ns = now;
		s->n_ticks = 1;
	}
	uint64_t next_ns = src_deadline(s);
	src_timer_at(s, next_ns);
	if (pw_stream_is_driving(s->stream)) {
		atomic_store(&s->driving_seen, 1);
		atomic_fetch_add(&s->drive_ticks, 1);
		atomic_store(&s->cycle_ns, this_ns);
		atomic_store(&s->next_ns, next_ns);
		pw_stream_trigger_process(s->stream);
	} else {
		atomic_fetch_add(&s->follow_ticks, 1);
	}
}

/* Data thread, at the start of a cycle this stream drives: advances the
 * graph clock the way a driver must (nothing else does it for a stream),
 * as module-pipe-tunnel's timer does: one quantum of SRC_DRIVER_FRAMES at
 * 48 kHz per cycle, stamped with the timer's deadline. The followers run
 * after this callback returns, so they see the new position. */
static void src_advance_clock(struct src *s, struct spa_io_position *p)
{
	if (!p)
		return;
	p->clock.nsec = atomic_load_explicit(&s->cycle_ns, memory_order_relaxed);
	p->clock.rate = SPA_FRACTION(1, G16MIC_RATE);
	p->clock.position += p->clock.duration;
	p->clock.duration = SRC_DRIVER_FRAMES;
	p->clock.delay = 0;
	p->clock.rate_diff = 1.0;
	p->clock.next_nsec = atomic_load_explicit(&s->next_ns, memory_order_relaxed);
}

static void src_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct src *s = data;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR)
		fprintf(stderr, "test_pw_helper: source stream error: %s\n", error ? error : "unknown");
	if (!s->driver || !s->timer)
		return;
	if (state == PW_STREAM_STATE_STREAMING && !s->armed) {
		s->t0_ns = mono_ns();
		s->n_ticks = 1;
		s->armed = 1;
		src_timer_at(s, src_deadline(s));
	} else if (state != PW_STREAM_STATE_STREAMING && s->armed) {
		s->armed = 0;
		src_timer_at(s, 0);
	}
}

static void src_process(void *data)
{
	struct src *s = data;

	if (s->driver && pw_stream_is_driving(s->stream))
		src_advance_clock(s, atomic_load_explicit(&s->position, memory_order_relaxed));
	struct pw_buffer *b = pw_stream_dequeue_buffer(s->stream);
	if (!b)
		return;
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;
	if (!d || !d->data || !d->chunk) {
		pw_stream_queue_buffer(s->stream, b);
		return;
	}
	uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)s->ch;
	uint64_t frames = d->maxsize / stride;
	if (b->requested && b->requested < frames)
		frames = b->requested;
	float *out = d->data;
	for (uint64_t i = 0; i < frames; i++)
		for (int c = 0; c < s->ch; c++)
			out[i * (uint64_t)s->ch + (uint64_t)c] = sig(s->next_k + (int64_t)i, c);
	d->chunk->offset = 0;
	d->chunk->stride = (int32_t)stride;
	d->chunk->size = (uint32_t)(frames * stride);

	size_t n = atomic_load_explicit(&s->n_recs, memory_order_relaxed);
	if (n < SRC_RECS) {
		s->recs[n].pos = graph_pos(atomic_load_explicit(&s->position, memory_order_relaxed));
		s->recs[n].k = s->next_k;
		s->recs[n].frames = (uint32_t)frames;
		atomic_store_explicit(&s->n_recs, n + 1, memory_order_release);
	} else {
		atomic_fetch_add_explicit(&s->lost, 1, memory_order_relaxed);
	}
	s->next_k += (int64_t)frames;
	pw_stream_queue_buffer(s->stream, b);
}

static void src_io_changed(void *data, uint32_t id, void *area, uint32_t size)
{
	keep_position(&((struct src *)data)->position, id, area, size);
}

static const struct pw_stream_events src_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = src_state_changed,
	.io_changed = src_io_changed,
	.process = src_process,
};

/* Main thread: the --driver state lines, each written once. */
static void src_note_driving(struct src *s, FILE *log, int *noted)
{
	if (!s->driver || *noted == 2)
		return;
	if (atomic_load(&s->driving_seen)) {
		fputs("# source: driving\n", log);
		fflush(log);
		*noted = 2;
	} else if (*noted == 0 && atomic_load(&s->follow_ticks) >= SRC_NOT_DRIVING_CYCLES) {
		fputs("# source: not driving\n", log);
		fflush(log);
		*noted = 1;
	}
}

static size_t src_flush(struct src *s, FILE *log, size_t from)
{
	size_t n = atomic_load_explicit(&s->n_recs, memory_order_acquire);

	for (size_t i = from; i < n; i++)
		fprintf(log, "%" PRIu64 " %" PRId64 " %" PRIu32 "\n", s->recs[i].pos, s->recs[i].k, s->recs[i].frames);
	fflush(log);
	return n;
}

static int cmd_source(const struct opts *o)
{
	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
	const struct spa_pod *params[1];
	uint32_t pos[G16MIC_MAX_CH];
	sigset_t sigs;
	int rc = 0;

	if (!o->name || !o->log || o->channels < 1) {
		fputs("usage: test_pw_helper source --name N --channels C --log FILE [--start K] [--class C] [--props k=v,...]"
		      " [--driver [--ppm P]] [--quiet]\n", stderr);
		return EXIT_USAGE;
	}
	if (o->ppm != 0 && !o->driver) {
		fputs("test_pw_helper: --ppm needs --driver\n", stderr);
		return EXIT_USAGE;
	}
	int ch = (int)o->channels;
	default_positions(ch, pos);
	FILE *log = fopen(o->log, "we");
	if (!log) {
		fprintf(stderr, "test_pw_helper: %s: %s\n", o->log, strerror(errno));
		return 1;
	}
	fprintf(log, "# test_pw_helper source name=%s channels=%d start=%ld driver=%d ppm=%ld%s\n", o->name, ch, o->start,
		o->driver, o->ppm, o->quiet ? " quiet=1" : "");
	fflush(log);

	struct src *s = calloc(1, sizeof *s);
	if (!s || !(s->recs = calloc(SRC_RECS, sizeof *s->recs))) {
		fputs("test_pw_helper: out of memory\n", stderr);
		fclose(log);
		free(s);
		return 1;
	}
	s->ch = ch;
	s->next_k = (int64_t)o->start;
	s->driver = o->driver;
	s->period_ns = (double)SRC_DRIVER_FRAMES * 1e9 / (double)G16MIC_RATE * (1.0 + (double)o->ppm * 1e-6);

	block_signals(&sigs);
	pw_init(NULL, NULL);
	if (pwc_open(&s->pw, "g16-mic-test-source") != 0) {
		rc = 1;
		goto out;
	}
	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CLASS, o->cls ? o->cls : "Audio/Source",
		PW_KEY_NODE_NAME, o->name,
		PW_KEY_NODE_DESCRIPTION, "g16-mic live test source",
		PW_KEY_NODE_LATENCY, "1024/48000",
		"node.autoconnect", "false",
		NULL);
	if (props && o->driver) {
		/* its own group, never g16-mic's, so linking to it brings its clock */
		pw_properties_set(props, "priority.driver", SRC_DRIVER_PRIORITY);
		pw_properties_setf(props, PW_KEY_NODE_GROUP, "test.src-driver.%ld", (long)getpid());
	}
	if (!props || apply_props(props, o->props) != 0) {
		fputs("test_pw_helper: bad --props\n", stderr);
		pw_properties_free(props);
		rc = EXIT_USAGE;
		goto out;
	}
	pw_thread_loop_lock(s->pw.tl);
	int res = -ENOMEM;
	uint32_t flags = PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS;
	if (o->driver) {
		s->timer = pw_loop_add_timer(pw_thread_loop_get_loop(s->pw.tl), src_on_timer, s);
		flags |= PW_STREAM_FLAG_DRIVER;
	}
	s->stream = (!o->driver || s->timer) ? pw_stream_new(s->pw.core, o->name, props) : NULL;
	if (!s->stream && o->driver && !s->timer)
		pw_properties_free(props);
	if (s->stream) {
		pw_stream_add_listener(s->stream, &s->listener, &src_events, s);
		params[0] = audio_format(&bld, ch, pos);
		res = pw_stream_connect(s->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, (enum pw_stream_flags)flags, params, 1);
	}
	pw_thread_loop_unlock(s->pw.tl);
	if (res < 0) {
		fprintf(stderr, "test_pw_helper: cannot offer source %s: %s\n", o->name, spa_strerror(res));
		rc = 1;
		goto out;
	}

	size_t flushed = 0;
	int noted = 0;
	for (;;) {
		int sig_no = wait_tick(&sigs);
		flushed = src_flush(s, log, flushed);
		src_note_driving(s, log, &noted);
		if (sig_no == SIGINT || sig_no == SIGTERM)
			break;
		if (atomic_load(&s->pw.core_failed)) {
			fputs("test_pw_helper: lost the PipeWire connection\n", stderr);
			rc = 1;
			break;
		}
	}
	stream_disconnect(&s->pw, s->stream);
	src_flush(s, log, flushed);
	src_note_driving(s, log, &noted);
	if (s->driver) {
		fprintf(log, "# source: %" PRIu64 " cycles driven, %" PRIu64 " timer ticks while another driver ran,"
			" %" PRIu64 " schedule restarts after a stall\n",
			(uint64_t)atomic_load(&s->drive_ticks), (uint64_t)atomic_load(&s->follow_ticks),
			(uint64_t)atomic_load(&s->resyncs));
		fflush(log);
	}
	if (atomic_load(&s->lost))
		fprintf(stderr, "test_pw_helper: source %s: %" PRIu64 " buffers not logged (log full)\n",
			o->name, (uint64_t)atomic_load(&s->lost));

out:
	if (s->timer) {
		pw_thread_loop_lock(s->pw.tl);
		s->armed = 0;
		pw_loop_destroy_source(pw_thread_loop_get_loop(s->pw.tl), s->timer);
		s->timer = NULL;
		pw_thread_loop_unlock(s->pw.tl);
	}
	pwc_close(&s->pw, &s->stream, &s->listener);
	pw_deinit();
	fclose(log);
	free(s->recs);
	free(s);
	return rc;
}

/* ---- tap -------------------------------------------------------------------- */

struct tap_rec { uint64_t pos; uint32_t frames; };

struct tap {
	struct pwc pw;
	struct pw_stream *stream;
	struct spa_hook listener;
	int ch;
	size_t want;                 /* frames */
	float *buf;                  /* want * ch floats */
	struct tap_rec *recs;        /* TAP_RECS */
	size_t got, n_recs;          /* data thread only */
	atomic_size_t got_pub, n_pub;
	atomic_int done, fmt_error, stream_error;
	_Atomic(struct spa_io_position *) position;
};

static void tap_process(void *data)
{
	struct tap *t = data;
	struct pw_buffer *b = pw_stream_dequeue_buffer(t->stream);

	if (!b)
		return;
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;
	if (!atomic_load_explicit(&t->done, memory_order_relaxed) && d && d->data && d->chunk) {
		uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)t->ch;
		uint32_t off = SPA_MIN(d->chunk->offset, d->maxsize);
		uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - off);
		size_t n = SPA_MIN((size_t)(size / stride), t->want - t->got);
		if (n > 0 && t->n_recs < TAP_RECS) {
			memcpy(t->buf + t->got * (size_t)t->ch, SPA_PTROFF(d->data, off, const void), n * stride);
			t->recs[t->n_recs].pos = graph_pos(atomic_load_explicit(&t->position, memory_order_relaxed));
			t->recs[t->n_recs].frames = (uint32_t)n;
			t->n_recs++;
			t->got += n;
			atomic_store_explicit(&t->n_pub, t->n_recs, memory_order_release);
			atomic_store_explicit(&t->got_pub, t->got, memory_order_release);
			if (t->got >= t->want)
				atomic_store(&t->done, 1);
		}
	}
	pw_stream_queue_buffer(t->stream, b);
}

static void tap_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
	struct tap *t = data;
	uint32_t media_type, media_subtype;
	struct spa_audio_info_raw info;

	if (!param || id != SPA_PARAM_Format)
		return;
	if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
	    media_type != SPA_MEDIA_TYPE_audio || media_subtype != SPA_MEDIA_SUBTYPE_raw)
		return;
	memset(&info, 0, sizeof info);
	if (spa_format_audio_raw_parse(param, &info) < 0)
		return;
	if (info.format != SPA_AUDIO_FORMAT_F32 || info.rate != G16MIC_RATE || info.channels != (uint32_t)t->ch) {
		fprintf(stderr, "test_pw_helper: tap negotiated format %u, %u Hz, %u channels (want F32, %d Hz, %d)\n",
			(unsigned)info.format, (unsigned)info.rate, (unsigned)info.channels, G16MIC_RATE, t->ch);
		atomic_store(&t->fmt_error, 1);
	}
}

static void tap_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct tap *t = data;

	(void)old;
	if (state == PW_STREAM_STATE_ERROR) {
		fprintf(stderr, "test_pw_helper: tap stream error: %s\n", error ? error : "unknown");
		atomic_store(&t->stream_error, 1);
	}
}

static void tap_io_changed(void *data, uint32_t id, void *area, uint32_t size)
{
	keep_position(&((struct tap *)data)->position, id, area, size);
}

static const struct pw_stream_events tap_events = {
	PW_VERSION_STREAM_EVENTS,
	.io_changed = tap_io_changed,
	.state_changed = tap_state_changed,
	.param_changed = tap_param_changed,
	.process = tap_process,
};

static int write_tap(const struct tap *t, const char *path, size_t got, size_t n_recs)
{
	char tpath[4096];
	int rc = 0;

	if (snprintf(tpath, sizeof tpath, "%s.ticks", path) >= (int)sizeof tpath)
		return -1;
	FILE *f = fopen(path, "we");
	FILE *g = fopen(tpath, "we");
	if (!f || !g) {
		fprintf(stderr, "test_pw_helper: cannot write %s: %s\n", f ? tpath : path, strerror(errno));
		rc = -1;
	} else {
		if (fwrite(t->buf, sizeof(float) * (size_t)t->ch, got, f) != got)
			rc = -1;
		for (size_t i = 0; i < n_recs; i++)
			fprintf(g, "%" PRIu64 " %" PRIu32 "\n", t->recs[i].pos, t->recs[i].frames);
	}
	if (f && fclose(f) != 0)
		rc = -1;
	if (g && fclose(g) != 0)
		rc = -1;
	return rc;
}

static int cmd_tap(const struct opts *o)
{
	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
	const struct spa_pod *params[1];
	uint32_t pos[G16MIC_MAX_CH];
	char node_name[192];
	sigset_t sigs;
	int rc = 0;

	if (!o->target || !o->out || o->channels < 1 || o->seconds <= 0.0) {
		fputs("usage: test_pw_helper tap --target NODE --out FILE --channels C --seconds S [--positions P,...]\n", stderr);
		return EXIT_USAGE;
	}
	int ch = (int)o->channels;
	if (o->positions) {
		if (parse_positions(o->positions, ch, pos) != 0) {
			fprintf(stderr, "test_pw_helper: --positions '%s' does not name %d channels\n", o->positions, ch);
			return EXIT_USAGE;
		}
	} else {
		default_positions(ch, pos);
	}

	struct tap *t = calloc(1, sizeof *t);
	if (!t)
		return 1;
	t->ch = ch;
	t->want = (size_t)(o->seconds * G16MIC_RATE + 0.5);
	t->buf = calloc(t->want * (size_t)ch, sizeof(float));
	t->recs = calloc(TAP_RECS, sizeof *t->recs);
	if (!t->buf || !t->recs) {
		fputs("test_pw_helper: out of memory\n", stderr);
		free(t->buf);
		free(t->recs);
		free(t);
		return 1;
	}

	block_signals(&sigs);
	pw_init(NULL, NULL);
	if (pwc_open(&t->pw, "g16-mic-test-tap") != 0) {
		rc = 1;
		goto out;
	}
	snprintf(node_name, sizeof node_name, "g16-mic-test-tap.%s", o->target);
	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_ROLE, "Production",
		PW_KEY_NODE_NAME, node_name,
		PW_KEY_NODE_LATENCY, "1024/48000",
		PW_KEY_TARGET_OBJECT, o->target,
		"node.dont-fallback", "true",
		"node.dont-reconnect", "true",
		"stream.capture.sink", "false",
		NULL);
	if (!props) {
		rc = 1;
		goto out;
	}
	pw_thread_loop_lock(t->pw.tl);
	t->stream = pw_stream_new(t->pw.core, node_name, props);
	int res = -ENOMEM;
	if (t->stream) {
		pw_stream_add_listener(t->stream, &t->listener, &tap_events, t);
		params[0] = audio_format(&bld, ch, pos);
		res = pw_stream_connect(t->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
					PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
					params, 1);
	}
	pw_thread_loop_unlock(t->pw.tl);
	if (res < 0) {
		fprintf(stderr, "test_pw_helper: cannot connect a tap to %s: %s\n", o->target, spa_strerror(res));
		rc = 1;
		goto out;
	}

	long ticks_left = (long)((o->seconds + TAP_GRACE_S) * 1000.0 / TICK_MS);
	int interrupted = 0;
	while (!atomic_load(&t->done) && ticks_left-- > 0) {
		int sig_no = wait_tick(&sigs);
		if (sig_no == SIGINT || sig_no == SIGTERM) {
			interrupted = 1;
			break;
		}
		if (atomic_load(&t->pw.core_failed) || atomic_load(&t->stream_error) || atomic_load(&t->fmt_error))
			break;
	}
	atomic_store(&t->done, 1);
	stream_disconnect(&t->pw, t->stream);

	size_t got = atomic_load_explicit(&t->got_pub, memory_order_acquire);
	size_t n_recs = atomic_load_explicit(&t->n_pub, memory_order_acquire);
	if (write_tap(t, o->out, got, n_recs) != 0)
		rc = 1;
	if (atomic_load(&t->fmt_error))
		rc = 2;
	else if (got == 0) {
		fprintf(stderr, "test_pw_helper: tap %s: no data arrived\n", o->target);
		rc = 1;
	} else if (got < t->want) {
		fprintf(stderr, "test_pw_helper: tap %s: %zu of %zu frames%s\n", o->target, got, t->want,
			interrupted ? " (interrupted)" : "");
		rc = 1;
	}

out:
	pwc_close(&t->pw, &t->stream, &t->listener);
	pw_deinit();
	free(t->buf);
	free(t->recs);
	free(t);
	return rc;
}

/* ---- graph ------------------------------------------------------------------ */

#define G_NODES 512
#define G_PORTS 2048
#define G_LINKS 2048
#define G_SMALL 128

struct gnode { uint32_t id; char name[160], cls[64]; int alsa, bluez; };
struct gport { uint32_t id, node; char dir[8], chan[24], fmt[64]; int monitor; };
struct glink { uint32_t id, out_node, in_node; };
struct gdev { uint32_t id; char api[32]; };
struct gmeta { uint32_t id; char name[64]; };

struct graph {
	struct pw_main_loop *loop;
	struct pw_context *ctx;
	struct pw_core *core;
	struct pw_registry *reg;
	struct spa_hook core_l, reg_l;
	int sync_seq, failed;
	char core_name[160];
	struct gnode nodes[G_NODES];
	struct gport ports[G_PORTS];
	struct glink links[G_LINKS];
	struct gdev devs[G_SMALL];
	struct gmeta metas[G_SMALL];
	size_t n_nodes, n_ports, n_links, n_devs, n_metas;
};

static void copy_prop(char *dst, size_t len, const struct spa_dict *props, const char *key)
{
	const char *v = props ? spa_dict_lookup(props, key) : NULL;

	snprintf(dst, len, "%s", v ? v : "");
}

static uint32_t prop_u32(const struct spa_dict *props, const char *key)
{
	const char *v = props ? spa_dict_lookup(props, key) : NULL;
	long n;

	if (!v || parse_long(v, 0, (long)UINT32_MAX - 1, &n) != 0)
		return SPA_ID_INVALID;
	return (uint32_t)n;
}

static void g_global(void *data, uint32_t id, uint32_t permissions, const char *type, uint32_t version,
		     const struct spa_dict *props)
{
	struct graph *g = data;

	(void)permissions;
	(void)version;
	if (!type)
		return;
	if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0 && g->n_nodes < G_NODES) {
		struct gnode *n = &g->nodes[g->n_nodes++];
		const struct spa_dict_item *it;
		n->id = id;
		copy_prop(n->name, sizeof n->name, props, PW_KEY_NODE_NAME);
		copy_prop(n->cls, sizeof n->cls, props, PW_KEY_MEDIA_CLASS);
		if (props) {
			spa_dict_for_each(it, props) {
				if (strncmp(it->key, "api.alsa", 8) == 0)
					n->alsa = 1;
				if (strncmp(it->key, "api.bluez5", 10) == 0)
					n->bluez = 1;
				if (strcmp(it->key, "device.api") == 0 && it->value) {
					if (strcmp(it->value, "alsa") == 0)
						n->alsa = 1;
					if (strcmp(it->value, "bluez5") == 0)
						n->bluez = 1;
				}
			}
		}
	} else if (strcmp(type, PW_TYPE_INTERFACE_Port) == 0 && g->n_ports < G_PORTS) {
		struct gport *p = &g->ports[g->n_ports++];
		const char *mon = props ? spa_dict_lookup(props, "port.monitor") : NULL;
		p->id = id;
		p->node = prop_u32(props, PW_KEY_NODE_ID);
		copy_prop(p->dir, sizeof p->dir, props, PW_KEY_PORT_DIRECTION);
		copy_prop(p->chan, sizeof p->chan, props, PW_KEY_AUDIO_CHANNEL);
		copy_prop(p->fmt, sizeof p->fmt, props, PW_KEY_FORMAT_DSP);
		p->monitor = mon && strcmp(mon, "true") == 0;
	} else if (strcmp(type, PW_TYPE_INTERFACE_Link) == 0 && g->n_links < G_LINKS) {
		struct glink *l = &g->links[g->n_links++];
		l->id = id;
		l->out_node = prop_u32(props, PW_KEY_LINK_OUTPUT_NODE);
		l->in_node = prop_u32(props, PW_KEY_LINK_INPUT_NODE);
	} else if (strcmp(type, PW_TYPE_INTERFACE_Device) == 0 && g->n_devs < G_SMALL) {
		struct gdev *d = &g->devs[g->n_devs++];
		d->id = id;
		copy_prop(d->api, sizeof d->api, props, "device.api");
	} else if (strcmp(type, "PipeWire:Interface:Metadata") == 0 && g->n_metas < G_SMALL) {
		struct gmeta *m = &g->metas[g->n_metas++];
		m->id = id;
		copy_prop(m->name, sizeof m->name, props, "metadata.name");
	}
}

static const struct pw_registry_events g_registry_events = {
	PW_VERSION_REGISTRY_EVENTS,
	.global = g_global,
};

static void g_core_info(void *data, const struct pw_core_info *info)
{
	struct graph *g = data;

	if (info && info->name)
		snprintf(g->core_name, sizeof g->core_name, "%s", info->name);
}

static void g_core_done(void *data, uint32_t id, int seq)
{
	struct graph *g = data;

	if (id == PW_ID_CORE && seq == g->sync_seq)
		pw_main_loop_quit(g->loop);
}

static void g_core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
	struct graph *g = data;

	(void)seq;
	fprintf(stderr, "test_pw_helper: PipeWire error on %u: %s (%s)\n", id, message ? message : "", spa_strerror(res));
	if (id == PW_ID_CORE) {
		g->failed = 1;
		pw_main_loop_quit(g->loop);
	}
}

static const struct pw_core_events g_core_events = {
	PW_VERSION_CORE_EVENTS,
	.info = g_core_info,
	.done = g_core_done,
	.error = g_core_error,
};

/* Prints s with whitespace as '_' and "" as "-", so every field is one word. */
static void put_word(const char *s)
{
	if (!s || !*s) {
		fputc('-', stdout);
		return;
	}
	for (; *s; s++)
		fputc((*s == ' ' || *s == '\t' || *s == '\n') ? '_' : *s, stdout);
}

static const char *g_node_name(const struct graph *g, uint32_t id)
{
	for (size_t i = 0; i < g->n_nodes; i++)
		if (g->nodes[i].id == id)
			return g->nodes[i].name;
	return "";
}

/* Output, one object a line, every value one word:
 *   core name=N
 *   node id=I name=N class=C alsa=0|1 bluez=0|1
 *   port id=I node=I node_name=N dir=in|out channel=CH monitor=0|1 format=F
 *   link id=I out=N in=N out_id=I in_id=I
 *   device id=I api=A
 *   metadata id=I name=N
 */
static int cmd_graph(void)
{
	struct graph *g = calloc(1, sizeof *g);
	int rc = 0;

	if (!g)
		return 1;
	alarm(10);  /* an unresponsive daemon must not hang the test */
	pw_init(NULL, NULL);
	g->loop = pw_main_loop_new(NULL);
	if (g->loop)
		g->ctx = pw_context_new(pw_main_loop_get_loop(g->loop), NULL, 0);
	if (g->ctx)
		g->core = pw_context_connect(g->ctx, pw_properties_new(PW_KEY_APP_NAME, "g16-mic-test-graph", NULL), 0);
	if (!g->core) {
		fprintf(stderr, "test_pw_helper: cannot connect to PipeWire: %s\n", strerror(errno));
		rc = 1;
		goto out;
	}
	pw_core_add_listener(g->core, &g->core_l, &g_core_events, g);
	g->reg = pw_core_get_registry(g->core, PW_VERSION_REGISTRY, 0);
	pw_registry_add_listener(g->reg, &g->reg_l, &g_registry_events, g);
	g->sync_seq = pw_core_sync(g->core, PW_ID_CORE, 0);
	pw_main_loop_run(g->loop);
	if (g->failed) {
		rc = 1;
		goto out;
	}

	fputs("core name=", stdout);
	put_word(g->core_name);
	fputc('\n', stdout);
	for (size_t i = 0; i < g->n_nodes; i++) {
		const struct gnode *n = &g->nodes[i];
		printf("node id=%u name=", n->id);
		put_word(n->name);
		fputs(" class=", stdout);
		put_word(n->cls);
		printf(" alsa=%d bluez=%d\n", n->alsa, n->bluez);
	}
	for (size_t i = 0; i < g->n_ports; i++) {
		const struct gport *p = &g->ports[i];
		printf("port id=%u node=%u node_name=", p->id, p->node);
		put_word(g_node_name(g, p->node));
		fputs(" dir=", stdout);
		put_word(p->dir);
		fputs(" channel=", stdout);
		put_word(p->chan);
		printf(" monitor=%d format=", p->monitor);
		put_word(p->fmt);
		fputc('\n', stdout);
	}
	for (size_t i = 0; i < g->n_links; i++) {
		const struct glink *l = &g->links[i];
		printf("link id=%u out=", l->id);
		put_word(g_node_name(g, l->out_node));
		fputs(" in=", stdout);
		put_word(g_node_name(g, l->in_node));
		printf(" out_id=%u in_id=%u\n", l->out_node, l->in_node);
	}
	for (size_t i = 0; i < g->n_devs; i++) {
		printf("device id=%u api=", g->devs[i].id);
		put_word(g->devs[i].api);
		fputc('\n', stdout);
	}
	for (size_t i = 0; i < g->n_metas; i++) {
		printf("metadata id=%u name=", g->metas[i].id);
		put_word(g->metas[i].name);
		fputc('\n', stdout);
	}
	if (fflush(stdout) != 0)
		rc = 1;

out:
	if (g->reg) {
		spa_hook_remove(&g->reg_l);
		pw_proxy_destroy((struct pw_proxy *)g->reg);
	}
	if (g->core) {
		spa_hook_remove(&g->core_l);
		pw_core_disconnect(g->core);
	}
	if (g->ctx)
		pw_context_destroy(g->ctx);
	if (g->loop)
		pw_main_loop_destroy(g->loop);
	pw_deinit();
	free(g);
	return rc;
}

/* ---- compare ---------------------------------------------------------------- */

static int n_fail;

__attribute__((format(printf, 2, 3)))
static void verdict(int ok, const char *fmt, ...)
{
	va_list ap;

	fputs(ok ? "PASS: " : "FAIL: ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
	if (!ok)
		n_fail++;
}

struct srclog { uint64_t *pos; int64_t *k; uint32_t *n; size_t len, cap; };

static int srclog_push(struct srclog *s, uint64_t pos, int64_t k, uint32_t n)
{
	if (s->len == s->cap) {
		size_t cap = s->cap ? 2 * s->cap : 1024;
		uint64_t *p = realloc(s->pos, cap * sizeof *p);
		if (!p)
			return -1;
		s->pos = p;
		int64_t *kk = realloc(s->k, cap * sizeof *kk);
		if (!kk)
			return -1;
		s->k = kk;
		uint32_t *nn = realloc(s->n, cap * sizeof *nn);
		if (!nn)
			return -1;
		s->n = nn;
		s->cap = cap;
	}
	s->pos[s->len] = pos;
	s->k[s->len] = k;
	s->n[s->len] = n;
	s->len++;
	return 0;
}

/* The source may still be appending: a last line without its newline is
 * left out. */
static int read_srclog(const char *path, struct srclog *s)
{
	char line[256];
	FILE *f = fopen(path, "re");

	if (!f) {
		fprintf(stderr, "test_pw_helper: %s: %s\n", path, strerror(errno));
		return -1;
	}
	while (fgets(line, sizeof line, f)) {
		unsigned long long pos;
		long long k;
		unsigned long n;

		if (line[0] == '#')
			continue;
		if (!strchr(line, '\n'))
			break;
		if (sscanf(line, "%llu %lld %lu", &pos, &k, &n) != 3 || n == 0 || k < 0)
			continue;
		if (s->len > 0 && (int64_t)k != s->k[s->len - 1] + (int64_t)s->n[s->len - 1]) {
			fprintf(stderr, "test_pw_helper: %s: frame index jumps from %" PRId64 " to %lld\n", path,
				s->k[s->len - 1] + (int64_t)s->n[s->len - 1], k);
			fclose(f);
			return -1;
		}
		if (srclog_push(s, (uint64_t)pos, (int64_t)k, (uint32_t)n) != 0) {
			fclose(f);
			return -1;
		}
	}
	fclose(f);
	return s->len > 0 ? 0 : -1;
}

/* Index of the log record holding frame k, or -1. */
static long srclog_find(const struct srclog *s, int64_t k)
{
	size_t lo = 0, hi = s->len;

	while (hi - lo > 1) {
		size_t mid = lo + (hi - lo) / 2;
		if (s->k[mid] <= k)
			lo = mid;
		else
			hi = mid;
	}
	if (s->len == 0 || k < s->k[lo] || k >= s->k[lo] + (int64_t)s->n[lo])
		return -1;
	return (long)lo;
}

/* One tap file: x interleaved, gp the graph position of every frame, bstart
 * 1 on the first frame of every tap buffer (one output buffer each). */
struct tapdata { float *x; size_t frames; uint64_t *gp; uint8_t *bstart; uint32_t qmax; };

static int read_tap(const char *path, int ch, struct tapdata *t)
{
	char tpath[4096], line[128];
	size_t stride = sizeof(float) * (size_t)ch;

	memset(t, 0, sizeof *t);
	FILE *f = fopen(path, "re");
	if (!f) {
		fprintf(stderr, "test_pw_helper: %s: %s\n", path, strerror(errno));
		return -1;
	}
	long sz = -1;
	if (fseek(f, 0, SEEK_END) == 0)
		sz = ftell(f);
	if (sz < 0 || (size_t)sz % stride != 0 || fseek(f, 0, SEEK_SET) != 0) {
		fprintf(stderr, "test_pw_helper: %s: not a whole number of %d-channel frames\n", path, ch);
		fclose(f);
		return -1;
	}
	t->frames = (size_t)sz / stride;
	t->x = malloc((size_t)sz + stride);
	t->gp = malloc((t->frames + 1) * sizeof *t->gp);
	t->bstart = calloc(t->frames + 1, 1);
	if (!t->x || !t->gp || !t->bstart || fread(t->x, stride, t->frames, f) != t->frames) {
		fprintf(stderr, "test_pw_helper: %s: cannot read\n", path);
		fclose(f);
		return -1;
	}
	fclose(f);

	snprintf(tpath, sizeof tpath, "%s.ticks", path);
	f = fopen(tpath, "re");
	if (!f) {
		fprintf(stderr, "test_pw_helper: %s: %s\n", tpath, strerror(errno));
		return -1;
	}
	size_t i = 0;
	while (fgets(line, sizeof line, f)) {
		unsigned long long pos;
		unsigned long n;
		if (sscanf(line, "%llu %lu", &pos, &n) != 2)
			continue;
		if (n > t->qmax)
			t->qmax = (uint32_t)n;
		if (n > 0 && i < t->frames)
			t->bstart[i] = 1;
		for (unsigned long j = 0; j < n && i < t->frames; j++, i++)
			t->gp[i] = (uint64_t)pos == POS_UNKNOWN ? POS_UNKNOWN : (uint64_t)pos + j;
	}
	fclose(f);
	if (i != t->frames) {
		fprintf(stderr, "test_pw_helper: %s covers %zu of %zu frames\n", tpath, i, t->frames);
		return -1;
	}
	return 0;
}

/* Frame lookup by content: two channels of one frame, or (mono) one channel
 * of two consecutive frames, make a 64-bit key. */
struct ktab { uint64_t *key; int64_t *val; size_t mask; };

static uint64_t pair_key(float a, float b)
{
	return ((uint64_t)fbits(a) << 32) | fbits(b);
}

static uint64_t sig_key(int64_t k, int ch)
{
	return ch >= 2 ? pair_key(sig(k, 0), sig(k, 1)) : pair_key(sig(k, 0), sig(k + 1, 0));
}

static int ktab_build(struct ktab *t, int64_t kmin, int64_t kmax, int ch)
{
	size_t n = (size_t)(kmax - kmin), cap = 1024;

	while (cap < 2 * n)
		cap <<= 1;
	t->key = malloc(cap * sizeof *t->key);
	t->val = malloc(cap * sizeof *t->val);
	if (!t->key || !t->val)
		return -1;
	t->mask = cap - 1;
	for (size_t i = 0; i < cap; i++)
		t->val[i] = -1;
	for (int64_t k = kmin; k < kmax; k++) {
		uint64_t key = sig_key(k, ch);
		size_t h = (size_t)splitmix64(key) & t->mask;
		while (t->val[h] >= 0 && t->key[h] != key)
			h = (h + 1) & t->mask;
		if (t->val[h] < 0) {
			t->key[h] = key;
			t->val[h] = k;
		}
	}
	return 0;
}

static int64_t ktab_find(const struct ktab *t, uint64_t key)
{
	size_t h = (size_t)splitmix64(key) & t->mask;

	while (t->val[h] >= 0) {
		if (t->key[h] == key)
			return t->val[h];
		h = (h + 1) & t->mask;
	}
	return -1;
}

static int frame_is_zero(const float *f, int ch)
{
	for (int c = 0; c < ch; c++)
		if (fbits(f[c]) != 0)
			return 0;
	return 1;
}

static int frame_matches(const float *f, int ch, int64_t k, int64_t kmin, int64_t kmax)
{
	if (k < kmin || k >= kmax)
		return 0;
	for (int c = 0; c < ch; c++)
		if (fbits(f[c]) != fbits(sig(k, c)))
			return 0;
	return 1;
}

struct procmap { float *v; uint64_t base; size_t span; };

static float proc_at(const struct procmap *p, uint64_t gp, long lag)
{
	if (gp == POS_UNKNOWN)
		return NAN;
	int64_t idx = (int64_t)gp - (int64_t)p->base + lag;
	if (idx < 0 || (uint64_t)idx >= p->span)
		return NAN;
	return p->v[idx];
}

/* Offline omni over raw frames [s, e): returns e - s + L mono frames, where
 * out[(i - s) + L] is what the live engine's processed output carries at the
 * engine output index that carries raw frame i. */
static float *offline_omni(const struct tapdata *raw, int ch, size_t s, size_t e, size_t want_latency)
{
	g16mic_params p;

	g16mic_params_default(&p);
	p.mode = G16MIC_MODE_OMNI;
	g16mic_engine *eng = g16mic_engine_create(ch, G16MIC_RATE, NULL, G16MIC_CAL_MISSING, &p);
	if (!eng)
		return NULL;
	size_t L = g16mic_engine_latency(eng), len = e - s, total = len + L;
	float *mono = malloc(total * sizeof(float));
	float *rawo = malloc((size_t)FEED_CHUNK * (size_t)ch * sizeof(float));
	float *zeros = calloc((size_t)FEED_CHUNK * (size_t)ch, sizeof(float));
	if (L != want_latency || !mono || !rawo || !zeros) {
		if (L != want_latency)
			fprintf(stderr, "test_pw_helper: the offline engine's latency is %zu, not %zu\n", L, want_latency);
		free(mono);
		mono = NULL;
		goto out;
	}
	for (size_t done = 0; done < total;) {
		size_t n = SPA_MIN((size_t)FEED_CHUNK, total - done);
		const float *src = zeros;
		if (done < len) {
			n = SPA_MIN(n, len - done);
			src = raw->x + (s + done) * (size_t)ch;
		}
		g16mic_engine_process(eng, src, n, rawo, mono + done);
		done += n;
	}
out:
	free(rawo);
	free(zeros);
	g16mic_engine_destroy(eng);
	return mono;
}

/* On a mismatch: which lag of processed against raw fits the offline omni
 * best, over one window. */
static void diagnose_lag(const struct tapdata *raw, const struct procmap *pm, size_t i0, size_t w,
			 const float *off, size_t off_index0)
{
	long best = 0;
	double best_err = INFINITY;

	for (long d = -LAG_SEARCH; d <= LAG_SEARCH; d++) {
		double m = 0.0;
		for (size_t j = 0; j < w && m < best_err; j++) {
			float v = proc_at(pm, raw->gp[i0 + j], d);
			if (isnan(v)) {
				m = INFINITY;
				break;
			}
			double err = fabs((double)v - (double)off[off_index0 + j]);
			if (err > m)
				m = err;
		}
		if (m < best_err) {
			best_err = m;
			best = d;
		}
	}
	if (isfinite(best_err))
		printf("  processed fits the offline omni best %ld frames from the raw tap's graph position (max error %.3g)\n",
		       best, best_err);
	else
		printf("  processed does not fit the offline omni at any lag within %d frames\n", LAG_SEARCH);
}

/* Input frame index at graph position gp from the source log, or -1. */
static int64_t srclog_k_at_pos(const struct srclog *s, uint64_t gp)
{
	for (size_t r = 0; r < s->len; r++)
		if (s->pos[r] != POS_UNKNOWN && gp >= s->pos[r] && gp < s->pos[r] + s->n[r])
			return s->k[r] + (int64_t)(gp - s->pos[r]);
	return -1;
}

/* --last-pos/--last-frames: g16-mic's last accepted cycle (input at graph
 * positions P..P+F-1) must come out whole: in RAW at position + L bit for
 * bit and, with PROC, as the offline omni engine's output for the same input
 * followed by g16mic_engine_flush() (the frames of the last cycle leave the
 * engine only through that flush). The offline engine starts SETTLE_FRAMES
 * of contiguous input before the cycle, as cmd_compare's processed check. */
static void check_last(const struct opts *o, const struct srclog *src, const struct tapdata *raw,
		       const struct tapdata *proc, int ch, size_t L)
{
	const uint64_t P = (uint64_t)o->last_pos;
	const size_t F = (size_t)o->last_frames;
	size_t *ridx = malloc(F * sizeof *ridx), *pidx = malloc(F * sizeof *pidx);
	int64_t *kat = malloc(F * sizeof *kat);
	size_t no_input = 0, raw_missing = 0, raw_wrong = 0, proc_missing = 0, proc_wrong = 0, missing = 0;
	double max_err = 0.0;
	float *mono = NULL, *rawo = NULL, *in = NULL;
	g16mic_engine *eng = NULL;

	if (!ridx || !pidx || !kat) {
		verdict(0, "out of memory");
		goto out;
	}
	for (size_t j = 0; j < F; j++) {
		ridx[j] = SIZE_MAX;
		pidx[j] = SIZE_MAX;
		kat[j] = srclog_k_at_pos(src, P + j);
	}
	for (size_t i = 0; i < raw->frames; i++) {
		uint64_t gp = raw->gp[i];
		if (gp != POS_UNKNOWN && gp >= P + L && gp < P + L + F)
			ridx[gp - P - L] = i;
	}
	if (proc)
		for (size_t i = 0; i < proc->frames; i++) {
			uint64_t gp = proc->gp[i];
			if (gp != POS_UNKNOWN && gp >= P + L && gp < P + L + F)
				pidx[gp - P - L] = i;
		}

	/* the offline engine: input from k_first - SETTLE_FRAMES (or the log's
	 * first frame) to the cycle's last frame, then the flush */
	int64_t k_first = kat[0], k_last = kat[F - 1];
	int contiguous = k_first >= 0 && k_last == k_first + (int64_t)F - 1;
	int64_t k0 = 0;
	size_t len = 0;
	if (proc && contiguous) {
		g16mic_params prm;
		g16mic_params_default(&prm);
		prm.mode = G16MIC_MODE_OMNI;
		eng = g16mic_engine_create(ch, G16MIC_RATE, NULL, G16MIC_CAL_MISSING, &prm);
		k0 = SPA_MAX(src->k[0], k_first - (int64_t)SETTLE_FRAMES);
		len = (size_t)(k_last + 1 - k0);
		mono = malloc((len + L) * sizeof(float));
		rawo = malloc((size_t)FEED_CHUNK * (size_t)ch * sizeof(float));
		in = malloc((size_t)FEED_CHUNK * (size_t)ch * sizeof(float));
		if (!eng || !mono || !rawo || !in || g16mic_engine_latency(eng) != L) {
			verdict(0, "cannot run the offline omni engine at latency %zu", L);
			goto out;
		}
		for (size_t done = 0; done < len;) {
			size_t n = SPA_MIN((size_t)FEED_CHUNK, len - done);
			for (size_t j = 0; j < n; j++)
				for (int c = 0; c < ch; c++)
					in[j * (size_t)ch + (size_t)c] = sig(k0 + (int64_t)(done + j), c);
			g16mic_engine_process(eng, in, n, rawo, mono + done);
			done += n;
		}
		for (size_t done = len; done < len + L;) {
			size_t n = g16mic_engine_flush(eng, rawo, mono + done, SPA_MIN((size_t)FEED_CHUNK, len + L - done));
			if (n == 0)
				break;
			done += n;
		}
		if (k_first - k0 < (int64_t)SETTLE_FRAMES)
			printf("  last cycle: only %" PRId64 " frames of input before it to settle the offline engine\n",
			       k_first - k0);
	} else if (proc) {
		printf("  last cycle: the source log has no contiguous input at graph positions %" PRIu64 "..%" PRIu64
		       "; processed not checked\n", P, P + F - 1);
	}

	for (size_t j = 0; j < F; j++) {
		int miss = 0;
		int64_t k = kat[j];
		if (k < 0) {
			no_input++;
			missing++;
			continue;
		}
		if (ridx[j] == SIZE_MAX) {
			raw_missing++;
			miss = 1;
		} else {
			const float *f = raw->x + ridx[j] * (size_t)ch;
			int same = 1;
			for (int c = 0; c < ch; c++)
				if (fbits(f[c]) != fbits(sig(k, c)))
					same = 0;
			if (!same) {
				raw_wrong++;
				miss = 1;
			}
		}
		if (proc) {
			if (pidx[j] == SIZE_MAX || !mono) {
				proc_missing++;
				miss = 1;
			} else {
				double err = fabs((double)proc->x[pidx[j]] - (double)mono[(size_t)(k - k0) + L]);
				if (err > max_err)
					max_err = err;
				if (err > TOL) {
					proc_wrong++;
					miss = 1;
				}
			}
		}
		missing += (size_t)miss;
	}
	printf("  last cycle: graph positions %" PRIu64 "..%" PRIu64 " (%zu frames), output at +%zu: %zu without input"
	       " in the source log, raw %zu missing and %zu wrong, processed %zu missing and %zu over tolerance"
	       " (max error %.3g)%s\n",
	       P, P + F - 1, F, L, no_input, raw_missing, raw_wrong, proc_missing, proc_wrong, max_err,
	       proc ? "" : " (no processed tap)");
	printf("last_missing=%zu\n", missing);
	verdict(missing == 0,
		"every frame of the last accepted cycle arrived at the engine latency (%zu frames, %zu missing;"
		" raw bit for bit%s)",
		F, missing, proc ? ", processed = offline omni with its tail flushed" : "");
out:
	g16mic_engine_destroy(eng);
	free(mono);
	free(rawo);
	free(in);
	free(ridx);
	free(pidx);
	free(kat);
}

static int cmd_compare(const struct opts *o)
{
	struct srclog src, osrc;
	struct tapdata raw, proc;
	struct ktab tab, otab;
	int ch = (int)o->channels;

	memset(&src, 0, sizeof src);
	memset(&osrc, 0, sizeof osrc);
	memset(&tab, 0, sizeof tab);
	memset(&otab, 0, sizeof otab);
	memset(&proc, 0, sizeof proc);
	if (!o->input_log || !o->raw || ch < 1 || (o->latency < 0 && !o->strict && !o->report_gaps) ||
	    (o->latency < 0 && (o->processed || o->last_pos >= 0)) || ((o->last_pos >= 0) != (o->last_frames > 0)) ||
	    (o->expect_zero_fill >= 0 && o->expect_gap < 0)) {
		fputs("usage: test_pw_helper compare --input-log SRC.log --raw RAW [--processed PROC] --channels C"
		      " --latency L [--strict] [--quiet] [--last-pos P --last-frames F] [--report-gaps] [--expect-gap N"
		      " [--expect-zero-fill Z]] [--old-log OLD.log] [--allow-delays]"
		      " (--latency is optional with --strict or --report-gaps and no --processed or --last-pos)\n", stderr);
		return EXIT_USAGE;
	}
	const int timed = o->latency >= 0;
	size_t L = timed ? (size_t)o->latency : 0;
	if (read_srclog(o->input_log, &src) != 0) {
		verdict(0, "cannot read the source log %s", o->input_log);
		return 1;
	}
	/* The source numbers its frames contiguously and may have emitted up to
	 * a flush period more than its log shows yet; frames that far past the
	 * last record still count as input (they are not timed). */
	int64_t kmin = src.k[0], kmax = src.k[src.len - 1] + (int64_t)src.n[src.len - 1] + 2 * G16MIC_RATE;
	if (kmax - kmin > (int64_t)1 << 24) {
		verdict(0, "the source log covers %" PRId64 " frames; this checker stops at 2^24", kmax - kmin);
		return 1;
	}
	if (read_tap(o->raw, ch, &raw) != 0) {
		verdict(0, "cannot read the raw tap %s", o->raw);
		return 1;
	}
	if (ktab_build(&tab, kmin, kmax, ch) != 0) {
		verdict(0, "out of memory");
		return 1;
	}
	/* --old-log: the previous stream's frames, to tell a stale frame of the
	 * old source from any other frame that is not input */
	int64_t okmin = 0, okmax = 0;
	if (o->old_log) {
		if (read_srclog(o->old_log, &osrc) != 0) {
			verdict(0, "cannot read the previous stream's source log %s", o->old_log);
			return 1;
		}
		okmin = osrc.k[0];
		okmax = osrc.k[osrc.len - 1] + (int64_t)osrc.n[osrc.len - 1] + 2 * G16MIC_RATE;
		if (okmax - okmin > (int64_t)1 << 24) {
			verdict(0, "the previous source log covers %" PRId64 " frames; this checker stops at 2^24", okmax - okmin);
			return 1;
		}
		if (ktab_build(&otab, okmin, okmax, ch) != 0) {
			verdict(0, "out of memory");
			return 1;
		}
	}

	/* raw: every non-zero frame is one input frame, bit for bit, in order */
	const size_t R = raw.frames;
	int64_t *kmap = malloc((R + 1) * sizeof *kmap);
	/* delays before frame i (--allow-delays): zero frames between input
	 * frames, and the tap's own graph position jumps */
	uint64_t *zbefore = malloc((R + 1) * sizeof *zbefore);
	uint64_t *sbefore = malloc((R + 1) * sizeof *sbefore);
	if (!kmap || !zbefore || !sbefore) {
		free(zbefore);
		free(sbefore);
		verdict(0, "out of memory");
		return 1;
	}
	size_t matched = 0, zeros = 0, zeros_lead = 0, bad = 0, fwd_gaps = 0, back = 0;
	size_t stale = 0, stale_lead = 0, stale_after = 0;  /* --old-log: frames of the previous stream (part of bad) */
	size_t last_i = SIZE_MAX;                       /* the tap frame holding the last input frame */
	int64_t last = -1;
	/* --report-gaps: measured against the furthest input frame seen, so a
	 * repeat followed by a jump forward is counted once each */
	int64_t furthest = -1, first_k = -1;
	uint64_t gap_total = 0, repeat_frames = 0, zero_fill_mid = 0, zeros_pending = 0;
	/* --allow-delays: the tap's own graph position jumps since the last
	 * input frame (pend_skip); a forward gap there, no larger than the
	 * jump and the jump no longer than CONSUMER_XRUN_MAX, is the tap's own
	 * loss (its node missed those cycles and PipeWire moved on:
	 * consumer_lost_frames, not g16-mic's), the rest of the jump a delay */
	uint64_t skip_total = 0, pend_skip = 0, consumer_lost = 0;
	for (size_t i = 0; i < R; i++) {
		const float *f = raw.x + i * (size_t)ch;
		kmap[i] = -1;
		if (i > 0 && raw.gp[i] != POS_UNKNOWN && raw.gp[i - 1] != POS_UNKNOWN && raw.gp[i] > raw.gp[i - 1] + 1)
			pend_skip += raw.gp[i] - raw.gp[i - 1] - 1;
		zbefore[i] = zero_fill_mid;
		sbefore[i] = skip_total;
		if (frame_is_zero(f, ch)) {
			zeros++;
			if (matched == 0)
				zeros_lead++;
			else
				zeros_pending++;
			continue;
		}
		int64_t k = -1;
		if (last >= 0 && frame_matches(f, ch, last + 1, kmin, kmax))
			k = last + 1;
		else if (ch >= 2 || i + 1 < R) {
			uint64_t key = ch >= 2 ? pair_key(f[0], f[1]) : pair_key(f[0], raw.x[(i + 1) * (size_t)ch]);
			k = ktab_find(&tab, key);
			if (k >= 0 && !frame_matches(f, ch, k, kmin, kmax))
				k = -1;
		}
		if (k < 0) {
			int64_t ko = -1;
			if (o->old_log && (ch >= 2 || i + 1 < R)) {
				uint64_t key = ch >= 2 ? pair_key(f[0], f[1]) : pair_key(f[0], raw.x[(i + 1) * (size_t)ch]);
				ko = ktab_find(&otab, key);
				if (ko >= 0 && !frame_matches(f, ch, ko, okmin, okmax))
					ko = -1;
			}
			if (ko >= 0) {
				if (stale < 5)
					printf("  raw frame %zu (graph position %" PRIu64 ") is frame %" PRId64
					       " of the previous stream\n", i, raw.gp[i], ko);
				stale++;
				if (matched == 0)
					stale_lead++;
				else
					stale_after++;
			} else if (bad - stale < 5) {
				printf("  raw frame %zu (graph position %" PRIu64 ") is not an input frame\n", i, raw.gp[i]);
			}
			bad++;
			continue;
		}
		int consumer_gap = 0;
		if (o->allow_delays && last >= 0 && k > last + 1 && furthest == last &&
		    (uint64_t)(k - last - 1) <= pend_skip && pend_skip <= CONSUMER_XRUN_MAX) {
			consumer_gap = 1;
			consumer_lost += (uint64_t)(k - last - 1);
			pend_skip -= (uint64_t)(k - last - 1);
			printf("  raw tap: input frame %" PRId64 " follows %" PRId64 " at tap frame %zu (the tap's own"
			       " missed cycle: consumer loss)\n", k, last, i);
		} else if (last >= 0 && k != last + 1) {
			if (k <= last)
				back++;
			else
				fwd_gaps++;
			printf("  raw tap: input frame %" PRId64 " follows %" PRId64 " at tap frame %zu (%s)\n", k, last, i,
			       k <= last ? "backwards" : "trimmed gap");
		}
		skip_total += pend_skip;
		pend_skip = 0;
		sbefore[i] = skip_total;
		kmap[i] = k;
		if (first_k < 0)
			first_k = k;
		last = k;
		last_i = i;
		matched++;
		zero_fill_mid += zeros_pending;  /* zeros between two input frames */
		zeros_pending = 0;
		zbefore[i] = zero_fill_mid;
		if (furthest >= 0 && k <= furthest) {
			repeat_frames++;
		} else {
			if (furthest >= 0 && !consumer_gap)
				gap_total += (uint64_t)(k - furthest - 1);
			furthest = k;
		}
	}
	if (o->allow_delays)
		printf("delay_zero_frames=%" PRIu64 "\ndelay_skip_frames=%" PRIu64 "\nconsumer_lost_frames=%" PRIu64 "\n",
		       zero_fill_mid, skip_total, consumer_lost);
	printf("  raw tap: %zu frames: %zu input frames bit for bit, %zu zero-filled (%zu before the first),"
	       " %zu forward gaps, %zu backwards, %zu not input\n",
	       R, matched, zeros, zeros_lead, fwd_gaps, back, bad);
	verdict(bad == 0 && back == 0 && matched > 0 && 2 * matched >= R,
		"raw output is the input bit for bit, in order (%zu of %zu frames)", matched, R);
	if (o->strict) {
		/* nothing lost or repeated: after the first input frame every frame
		 * is the next input frame (a zero fill is an underrun, a forward gap
		 * dropped audio, a backward step repeated it) */
		size_t zero_fills = zeros - zeros_lead;
		size_t allowed = o->allow_delays ? (size_t)zero_fill_mid : 0;
		verdict(zero_fills == allowed && fwd_gaps == 0 && back == 0 && bad == 0 && matched > 0 && 10 * matched >= 9 * R,
			"raw is one contiguous run of input frames: no gaps, repeats or zero fills after the first%s"
			" (%zu of %zu frames matched, %zu leading zeros, %zu zero fills after the first, %zu forward gaps,"
			" %zu backwards, %zu not input)",
			o->allow_delays ? " but delays (zeros between input frames, judged in the latency below)" : "",
			matched, R, zeros_lead, zero_fills, fwd_gaps, back, bad);
	}
	if (o->old_log) {
		printf("stale_frames=%zu\n", stale);
		printf("stale_lead_frames=%zu\n", stale_lead);
		verdict(stale == 0,
			"no frame of the previous stream (%s): %zu stale frames, %zu before the first new frame and %zu after it",
			o->old_log, stale, stale_lead, stale_after);
	}
	if (o->report_gaps) {
		/* After the last input frame: the zeros that complete its own tap
		 * buffer (a zero-padded last quantum, eos_pad), and the frames of
		 * any later buffers (silence after the stream ended; not judged). */
		size_t eos_zero = 0, after_eos = 0;
		if (last_i != SIZE_MAX) {
			size_t i = last_i + 1;
			for (; i < R && !raw.bstart[i] && frame_is_zero(raw.x + i * (size_t)ch, ch); i++)
				eos_zero++;
			while (i < R && !raw.bstart[i])
				i++;
			after_eos = R - i;
		}
		long want_zero = o->expect_zero_fill >= 0 ? o->expect_zero_fill : o->allow_delays ? (long)zero_fill_mid : 0;
		printf("gap_frames_total=%" PRIu64 "\n", gap_total);
		printf("gap_count=%zu\n", fwd_gaps);
		printf("repeat_frames=%" PRIu64 "\n", repeat_frames);
		printf("zero_fill_frames=%" PRIu64 "\n", zero_fill_mid);
		printf("trailing_zero_frames=%" PRIu64 "\n", matched ? zeros_pending : 0);
		printf("eos_zero_frames=%zu\n", eos_zero);
		printf("after_eos_frames=%zu\n", after_eos);
		printf("not_input_frames=%zu\n", bad);
		printf("last_frame=%" PRId64 "\n", furthest);
		/* graph frames the source's own clock moved on without it
		 * producing a buffer (its driver skipped a cycle), between the
		 * tap's first and furthest input frame: a capture counts those in
		 * capture_gap (graph frames), though they never were input */
		uint64_t clock_skip = 0;
		for (size_t r = 1; first_k >= 0 && r < src.len; r++) {
			if (src.k[r] <= first_k || src.k[r] > furthest || src.pos[r] == POS_UNKNOWN ||
			    src.pos[r - 1] == POS_UNKNOWN)
				continue;
			uint64_t want = src.pos[r - 1] + src.n[r - 1];
			if (src.pos[r] > want)
				clock_skip += src.pos[r] - want;
		}
		printf("src_clock_skip_frames=%" PRIu64 "\n", clock_skip);
		if (o->expect_gap >= 0)
			verdict(matched > 0 && gap_total == (uint64_t)o->expect_gap && repeat_frames == 0 &&
					zero_fill_mid == (uint64_t)want_zero && bad == 0,
				"raw lost exactly the counted %ld frames and has exactly the counted %ld zero-filled frames"
				" (gap_frames_total %" PRIu64 ", repeat_frames %" PRIu64 ", zero_fill_frames %" PRIu64
				", not_input_frames %zu)",
				o->expect_gap, want_zero, gap_total, repeat_frames, zero_fill_mid, bad);
	}
	/* end-to-end latency, from the source's graph position to the raw tap's;
	 * measured (latency_first/latency_last: at the first and the last timed
	 * frame) with or without --latency, judged only with it */
	int64_t lat_min = INT64_MAX, lat_max = INT64_MIN, lat_first = 0, lat_last = 0, delay_acc = 0;
	size_t lat_n = 0;
	/* timed at the first frame of every run of input frames and of every
	 * tap buffer: within one of those the latency cannot change */
	for (size_t i = 0; i < R; i++) {
		int run_start = i == 0 || kmap[i - 1] != kmap[i] - 1;
		int buf_start = i == 0 || raw.gp[i] == POS_UNKNOWN || raw.gp[i - 1] == POS_UNKNOWN ||
				raw.gp[i] != raw.gp[i - 1] + 1;
		if (kmap[i] < 0 || raw.gp[i] == POS_UNKNOWN || !(run_start || buf_start))
			continue;
		long r = srclog_find(&src, kmap[i]);
		if (r < 0 || src.pos[r] == POS_UNKNOWN)
			continue;
		int64_t lat = (int64_t)raw.gp[i] - ((int64_t)src.pos[r] + (kmap[i] - src.k[r]));
		if (lat_n == 0)
			lat_first = lat;
		lat_last = lat;
		lat_n++;
		/* judged: less the delay accepted so far. A rise above L is
		 * accepted only as far as the delays the tap shows before this
		 * frame (zero frames between input frames, its own position
		 * jumps) cover it; a zero or a jump need not raise it (the
		 * source's own clock skip moves both sides alike) */
		if (o->allow_delays && timed) {
			int64_t budget = (int64_t)(zbefore[i] + sbefore[i]);
			int64_t want = lat - (int64_t)L;
			if (want > delay_acc && want <= budget)
				delay_acc = want;
			lat -= delay_acc;
		}
		lat_min = SPA_MIN(lat_min, lat);
		lat_max = SPA_MAX(lat_max, lat);
	}
	if (lat_n > 0)
		printf("latency_first=%" PRId64 "\nlatency_last=%" PRId64 "\n", lat_first, lat_last);
	if (!timed) {
		printf("  no --latency: the end-to-end latency and processed checks were skipped\n");
		goto done;
	}
	/* the capture and both outputs run in the same graph cycle: a frame
	 * leaves exactly the engine latency after it arrived */
	int64_t lat_want = (int64_t)L;
	if (lat_n == 0)
		verdict(0, "no raw frame could be timed against the source log");
	else
		verdict(lat_min == lat_want && lat_max == lat_want,
			"end-to-end latency %" PRId64 "..%" PRId64 " samples (want exactly %" PRId64
			": the engine latency, delivered in the capture's own graph cycle)",
			lat_min, lat_max, lat_want);

	/* processed: at the raw tap's graph positions, the offline omni of the
	 * same frames, at the same engine latency (lag 0) */
	if (o->processed) {
		struct procmap pm = { 0 };
		if (read_tap(o->processed, 1, &proc) != 0) {
			verdict(0, "cannot read the processed tap %s", o->processed);
			goto done;
		}
		uint64_t pmin = POS_UNKNOWN, pmax = 0;
		for (size_t i = 0; i < proc.frames; i++) {
			if (proc.gp[i] == POS_UNKNOWN)
				continue;
			pmin = SPA_MIN(pmin, proc.gp[i]);
			pmax = SPA_MAX(pmax, proc.gp[i]);
		}
		if (pmin == POS_UNKNOWN || pmax - pmin > ((uint64_t)1 << 26)) {
			verdict(0, "the processed tap's graph positions are missing or span too far");
			goto done;
		}
		pm.base = pmin;
		pm.span = (size_t)(pmax - pmin + 1);
		pm.v = malloc(pm.span * sizeof(float));
		if (!pm.v) {
			verdict(0, "out of memory");
			goto done;
		}
		for (size_t i = 0; i < pm.span; i++)
			pm.v[i] = NAN;
		for (size_t i = 0; i < proc.frames; i++)
			if (proc.gp[i] != POS_UNKNOWN)
				pm.v[proc.gp[i] - pmin] = proc.x[i];

		size_t compared = 0, over = 0, missing = 0, segments = 0;
		double max_err = 0.0;
		int diagnosed = 0;
		for (size_t i = 0; i < R;) {
			if (kmap[i] < 0 || raw.gp[i] == POS_UNKNOWN) {
				i++;
				continue;
			}
			size_t s = i, e = i + 1;
			while (e < R && kmap[e] == kmap[e - 1] + 1 && raw.gp[e] != POS_UNKNOWN && raw.gp[e] == raw.gp[e - 1] + 1)
				e++;
			i = e;
			if (e - s < MIN_SEGMENT)
				continue;
			float *off = offline_omni(&raw, ch, s, e, L);
			if (!off) {
				verdict(0, "cannot run the offline omni engine at latency %zu", L);
				free(pm.v);
				goto done;
			}
			segments++;
			size_t seg_over = 0;
			for (size_t j = s + SETTLE_FRAMES; j < e; j++) {
				if (raw.gp[j] < pmin || raw.gp[j] > pmax)
					continue;  /* outside the processed tap's window */
				float v = proc_at(&pm, raw.gp[j], 0);
				if (isnan(v)) {
					missing++;
					continue;
				}
				double err = fabs((double)v - (double)off[(j - s) + L]);
				if (err > max_err)
					max_err = err;
				if (err > TOL)
					seg_over++;
				compared++;
			}
			over += seg_over;
			if ((seg_over || missing) && !diagnosed) {
				size_t i0 = s + SETTLE_FRAMES;
				diagnose_lag(&raw, &pm, i0, SPA_MIN((size_t)LAG_WINDOW, e - i0), off, (i0 - s) + L);
				diagnosed = 1;
			}
			free(off);
		}
		printf("  processed tap: %zu frames; %zu contiguous raw segments of at least %d frames;"
		       " %zu frames compared after %d settling frames each\n",
		       proc.frames, segments, MIN_SEGMENT, compared, SETTLE_FRAMES);
		verdict(compared >= (size_t)G16MIC_RATE && over == 0 && missing == 0,
			"processed = offline omni of the same frames at lag 0 (max error %.3g, tolerance %.0e;"
			" %zu over, %zu missing, %zu compared)",
			max_err, TOL, over, missing, compared);
		free(pm.v);
	}

	if (o->last_pos >= 0) {
		if (o->processed && !proc.x && read_tap(o->processed, 1, &proc) != 0) {
			verdict(0, "cannot read the processed tap %s", o->processed);
			goto done;
		}
		/* the window is the last 100 ms before a stop: counted xruns (if
		 * any) came before it, so it arrives that much later */
		check_last(o, &src, &raw, o->processed ? &proc : NULL, ch,
			   L + (o->allow_delays ? (size_t)delay_acc : 0));
	}

done:
	free(kmap);
	free(zbefore);
	free(sbefore);
	free(tab.key);
	free(tab.val);
	free(raw.x);
	free(raw.gp);
	free(raw.bstart);
	free(proc.x);
	free(proc.gp);
	free(proc.bstart);
	free(otab.key);
	free(otab.val);
	free(src.pos);
	free(src.k);
	free(src.n);
	free(osrc.pos);
	free(osrc.k);
	free(osrc.n);
	return n_fail ? 1 : 0;
}

/* ---- main ------------------------------------------------------------------- */

static int usage(void)
{
	fputs("usage: test_pw_helper source|tap|graph|compare ... (see the comment at the top of test_pw_helper.c)\n", stderr);
	return EXIT_USAGE;
}

int main(int argc, char **argv)
{
	struct opts o;

	if (argc < 2)
		return usage();
	const char *cmd = argv[1];
	if (strcmp(cmd, "graph") == 0)
		return cmd_graph();
	if (parse_opts(argc - 2, argv + 2, &o) != 0)
		return usage();
	if (o.quiet)
		sig_gain = SIG_QUIET_GAIN;
	if (strcmp(cmd, "source") == 0)
		return cmd_source(&o);
	if (strcmp(cmd, "tap") == 0)
		return cmd_tap(&o);
	if (strcmp(cmd, "compare") == 0)
		return cmd_compare(&o);
	return usage();
}
