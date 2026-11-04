/* SPDX-License-Identifier: MIT */
/* test_pw_helper.c: the PipeWire client side of test_pw_live.sh. A test-only
 * program, never installed. It talks to whatever daemon PIPEWIRE_REMOTE and
 * PIPEWIRE_RUNTIME_DIR name; test_pw_live.sh points them at its private one.
 *
 *   source --name N --channels C [--class Audio/Source] [--props k=v,...]
 *          [--start K] --log FILE
 *       An output stream that looks like a microphone: media.class
 *       Audio/Source (or --class), node.name N, F32 48 kHz, C channels (1:
 *       MONO, 2: FL FR, more: AUX0..), no autoconnect. Frame k carries
 *       sig(k, c) on channel c, a deterministic 24-bit value scaled to
 *       [-0.1, 0.1) (peak -20 dBFS, far below the engine's limiter ceiling,
 *       so omni stays linear). k starts at --start (default 0). Every buffer
 *       adds a line "<graph position> <first k> <frames>" to FILE. Runs until
 *       SIGTERM or SIGINT; exits 0.
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
 *       --latency L
 *       Checks tap files against the source's log: RAW must be the input bit
 *       for bit (gaps reported), its end-to-end latency must be exactly L
 *       plus one graph quantum (host.c reads its outputs on the capture's
 *       clock, one cycle behind it), and PROC, at the same graph positions,
 *       must equal an offline omni engine fed the same frames. PASS/FAIL lines; exit 0 if all pass, 1 otherwise.
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
#define POS_UNKNOWN UINT64_MAX
#define SRC_RECS (1u << 18)          /* source buffers logged: over an hour at 1024 frames */
#define TAP_RECS (1u << 16)
#define TICK_MS 100
#define TAP_GRACE_S 15               /* a tap gives up this long after its S seconds */
#define FEED_CHUNK 1024

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

/* Integer hashing and one exact int-to-float conversion and multiply, so the
 * source and compare produce the same bits. */
static float sig(int64_t k, int c)
{
	uint64_t h = splitmix64(SIG_SEED ^ ((uint64_t)k * 8u + (uint64_t)c));
	int32_t v = (int32_t)(h >> 40) - 8388608;  /* 24 bits -> [-2^23, 2^23) */

	return (float)v * SIG_SCALE;
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
	const char *input_log, *raw, *processed;
	long channels, start, latency;
	double seconds;
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
	for (int i = 0; i < argc; i += 2) {
		const char *k = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;

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
		else if (strcmp(k, "--channels") == 0) {
			if (parse_long(v, 1, G16MIC_MAX_CH, &o->channels) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--start") == 0) {
			if (parse_long(v, 0, (long)1 << 40, &o->start) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--latency") == 0) {
			if (parse_long(v, 0, 1 << 20, &o->latency) != 0)
				return bad_opt(k, v);
		} else if (strcmp(k, "--seconds") == 0) {
			if (parse_double(v, 0.01, 600.0, &o->seconds) != 0)
				return bad_opt(k, v);
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
};

static void src_process(void *data)
{
	struct src *s = data;
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
	.io_changed = src_io_changed,
	.process = src_process,
};

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
		fputs("usage: test_pw_helper source --name N --channels C --log FILE [--start K] [--class C] [--props k=v,...]\n", stderr);
		return EXIT_USAGE;
	}
	int ch = (int)o->channels;
	default_positions(ch, pos);
	FILE *log = fopen(o->log, "we");
	if (!log) {
		fprintf(stderr, "test_pw_helper: %s: %s\n", o->log, strerror(errno));
		return 1;
	}
	fprintf(log, "# test_pw_helper source name=%s channels=%d start=%ld\n", o->name, ch, o->start);
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
	if (!props || apply_props(props, o->props) != 0) {
		fputs("test_pw_helper: bad --props\n", stderr);
		pw_properties_free(props);
		rc = EXIT_USAGE;
		goto out;
	}
	pw_thread_loop_lock(s->pw.tl);
	s->stream = pw_stream_new(s->pw.core, o->name, props);
	int res = -ENOMEM;
	if (s->stream) {
		pw_stream_add_listener(s->stream, &s->listener, &src_events, s);
		params[0] = audio_format(&bld, ch, pos);
		res = pw_stream_connect(s->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
					PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
	}
	pw_thread_loop_unlock(s->pw.tl);
	if (res < 0) {
		fprintf(stderr, "test_pw_helper: cannot offer source %s: %s\n", o->name, spa_strerror(res));
		rc = 1;
		goto out;
	}

	size_t flushed = 0;
	for (;;) {
		int sig_no = wait_tick(&sigs);
		flushed = src_flush(s, log, flushed);
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
	if (atomic_load(&s->lost))
		fprintf(stderr, "test_pw_helper: source %s: %" PRIu64 " buffers not logged (log full)\n",
			o->name, (uint64_t)atomic_load(&s->lost));

out:
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

struct tapdata { float *x; size_t frames; uint64_t *gp; uint32_t qmax; };

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
	if (!t->x || !t->gp || fread(t->x, stride, t->frames, f) != t->frames) {
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

static int cmd_compare(const struct opts *o)
{
	struct srclog src;
	struct tapdata raw, proc;
	struct ktab tab;
	int ch = (int)o->channels;

	memset(&src, 0, sizeof src);
	memset(&tab, 0, sizeof tab);
	memset(&proc, 0, sizeof proc);
	if (!o->input_log || !o->raw || ch < 1 || o->latency < 0) {
		fputs("usage: test_pw_helper compare --input-log SRC.log --raw RAW [--processed PROC] --channels C --latency L\n", stderr);
		return EXIT_USAGE;
	}
	size_t L = (size_t)o->latency;
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

	/* raw: every non-zero frame is one input frame, bit for bit, in order */
	const size_t R = raw.frames;
	int64_t *kmap = malloc((R + 1) * sizeof *kmap);
	if (!kmap) {
		verdict(0, "out of memory");
		return 1;
	}
	size_t matched = 0, zeros = 0, zeros_lead = 0, bad = 0, fwd_gaps = 0, back = 0;
	int64_t last = -1;
	for (size_t i = 0; i < R; i++) {
		const float *f = raw.x + i * (size_t)ch;
		kmap[i] = -1;
		if (frame_is_zero(f, ch)) {
			zeros++;
			if (matched == 0)
				zeros_lead++;
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
			if (bad < 5)
				printf("  raw frame %zu (graph position %" PRIu64 ") is not an input frame\n", i, raw.gp[i]);
			bad++;
			continue;
		}
		if (last >= 0 && k != last + 1) {
			if (k <= last)
				back++;
			else
				fwd_gaps++;
			printf("  raw tap: input frame %" PRId64 " follows %" PRId64 " at tap frame %zu (%s)\n", k, last, i,
			       k <= last ? "backwards" : "trimmed gap");
		}
		kmap[i] = k;
		last = k;
		matched++;
	}
	printf("  raw tap: %zu frames: %zu input frames bit for bit, %zu zero-filled (%zu before the first),"
	       " %zu forward gaps, %zu backwards, %zu not input\n",
	       R, matched, zeros, zeros_lead, fwd_gaps, back, bad);
	verdict(bad == 0 && back == 0 && matched > 0 && 2 * matched >= R,
		"raw output is the input bit for bit, in order (%zu of %zu frames)", matched, R);

	/* end-to-end latency, from the source's graph position to the raw tap's */
	uint32_t q = raw.qmax ? raw.qmax : 1024;
	int64_t lat_min = INT64_MAX, lat_max = INT64_MIN;
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
		lat_min = SPA_MIN(lat_min, lat);
		lat_max = SPA_MAX(lat_max, lat);
		lat_n++;
	}
	int64_t lat_want = (int64_t)L + (int64_t)q;
	if (lat_n == 0)
		verdict(0, "no raw frame could be timed against the source log");
	else
		verdict(lat_min == lat_want && lat_max == lat_want,
			"end-to-end latency %" PRId64 "..%" PRId64 " samples (want exactly %" PRId64
			": engine %zu + one quantum of %u)",
			lat_min, lat_max, lat_want, L, q);

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

done:
	free(kmap);
	free(tab.key);
	free(tab.val);
	free(raw.x);
	free(raw.gp);
	free(proc.x);
	free(proc.gp);
	free(src.pos);
	free(src.k);
	free(src.n);
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
	if (strcmp(cmd, "source") == 0)
		return cmd_source(&o);
	if (strcmp(cmd, "tap") == 0)
		return cmd_tap(&o);
	if (strcmp(cmd, "compare") == 0)
		return cmd_compare(&o);
	return usage();
}
