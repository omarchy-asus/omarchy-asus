/* SPDX-License-Identifier: MIT */
/* host.c: the PipeWire side of the g16-mic daemon.
 *
 * Tested live by test_pw_live (test_pw_live.sh + test_pw_helper.c): it runs
 * this file against a private PipeWire daemon and WirePlumber that load only
 * null/dummy drivers (no ALSA, Bluetooth, Pulse or JACK; no sound), feeds it
 * a synthetic named source beside a decoy source and a sink monitor, and
 * checks the outputs bit for bit (raw) and against an offline omni engine
 * (processed), the links, a remove/re-add of the source and the SIGTERM
 * stop. It skips only where the pipewire or wireplumber binaries are
 * missing (the PKGBUILD's checkdepends puts both in the clean chroot, so it
 * runs there). Every decision is delegated to pure functions with their own
 * unit tests: which node to capture (g16mic_match_source, match.c,
 * test_match.c), whether the spatial modes may run
 * (g16mic_calib_check_spatial, calib.c), the processing (engine.c) and the
 * status file (status.c, test_status.c). What is left here is wiring: the
 * registry, the streams, the hand-off between threads, and the stop
 * sequence.
 *
 * Same graph cycle: the capture and both outputs run in one graph cycle.
 * The outputs are TRIGGER streams; the capture's process callback runs the
 * engine over the cycle's frames, publishes them in a cycle slot and
 * triggers both outputs, which copy that slot in the same cycle. There is
 * no ring between them, so nothing builds up or runs dry in steady state,
 * and the end-to-end latency is exactly the engine latency (test_pw_live
 * step 5 checks the raw output at exactly that delay).
 *
 * RED -> GREEN (test_pw_live step 9): the outputs used to read rings a
 * cycle behind the capture by graph clock position. With a source on its
 * own driver, a late or overlapping cycle made an output find the previous
 * cycle's frames not yet written, zero-fill a quantum (ring_underflow) and
 * then, a cycle later, find two quanta and discard one (ring_overflow):
 * both counters grew in steady state, worse under CPU load, and every count
 * was lost or repeated audio. The same-cycle hand-off removed both.
 *
 * Threads:
 *   - the PipeWire thread loop: registry and stream events, engine creation
 *     (all allocation), connect/disconnect, output activation;
 *   - PipeWire's data thread(s): the three RT_PROCESS callbacks. They never
 *     allocate, lock, sleep or do I/O. The capture callback is the only
 *     writer of the two cycle slots and of the telemetry queue: it fills
 *     the slot the outputs are not reading, publishes it with a sequence
 *     number (release) and triggers the outputs; each output callback only
 *     reads the slot of the newest sequence number (acquire) and checks,
 *     after copying, that the slot was not overwritten meanwhile;
 *   - a worker thread: drains the telemetry queue and rewrites the status
 *     file every 250 ms;
 *   - the main thread: waits for signals with sigtimedwait() (all three are
 *     blocked in every thread before any thread starts, so delivery does not
 *     depend on PipeWire's signal handling), applies mode requests and runs
 *     deferred stream teardowns.
 *
 * What it never does: capture anything but the source named by node.name
 * (no "first available", no fallback target, no reconnect by any other
 * key), change the default source, or start by itself.
 */
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw-types.h>
#include <spa/param/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/defs.h>
#include <spa/utils/result.h>

#include "g16mic.h"
#include "g16mic_host.h"

#define NODE_CAP 256
#define LINK_CAP 512
#define SCRATCH_FRAMES 8192          /* largest cycle a slot carries (and slice the engine processes at once) */
#define TELEM_CAP 64
#define STATUS_PERIOD_MS 250
#define TICK_MS 100

/* bits of the active-outputs mask (deactivate_outputs, retire_engine) */
#define OUT_PROCESSED 1
#define OUT_RAW 2

enum teardown { TD_NONE = 0, TD_LOST, TD_REMOVED, TD_WRONG_LINK, TD_ERROR, TD_STOP };

struct node_ent {
	uint32_t id;
	char name[128];
	char media_class[64];
	char device_class[32];
	int has_device_class;
	int channels;  /* audio.channels if the node exposes it, else 0 */
	/* audio.channel of its output ports (not monitors), by port.id; bit i
	 * of port_seen says port i was announced */
	uint32_t port_pos[G16MIC_MAX_CH];
	uint32_t port_seen;
};

struct link_ent { uint32_t id, out_node, in_node; };

/* The engine the capture callback uses. Swapped as one pointer. */
struct live {
	g16mic_engine *e;
	int channels;
	uint64_t gen;
};

/* One record a capture callback queues for the worker. */
struct telem {
	g16mic_stats eng;
	uint64_t gen;
	uint64_t ring_overflow, ring_underflow;
	int source_state;
};

struct host;

/* One capture cycle's output, as the outputs copy it in the same cycle:
 * frames mono samples and frames * channels interleaved raw samples.
 * Written only by the capture callback, into the slot of the next sequence
 * number; published by host.seq (see capture_process). */
struct cycle_slot {
	float *mono;  /* SCRATCH_FRAMES samples */
	float *raw;   /* SCRATCH_FRAMES * G16MIC_MAX_CH samples */
	size_t frames;
	int channels;
};

struct out_stream {
	struct host *h;
	struct pw_stream *stream;
	struct spa_hook listener;
	int channels;
	int is_raw;
	uint32_t pos[G16MIC_MAX_CH];  /* channel positions offered */
	/* active: set (thread-loop thread) while the stream is activated, i.e.
	 * while a capture streams; the capture callback triggers it only then.
	 * resync: raised on activation and when it starts streaming; its next
	 * process call takes the newest slot as its starting point instead of
	 * counting the cycles before it as missed. */
	atomic_int active, resync;
	/* the sequence number of the last slot this output consumed; touched
	 * only by its own process callback */
	uint64_t last_seq;
};

/* What the worker needs from the thread-loop side; guarded by mu (neither
 * side is real-time). */
struct shared {
	pthread_mutex_t mu;
	g16mic_src_state state;
	char refuse[32];
	char unavailable[32];
	uint64_t reconnects, wrong_links, host_fallbacks, host_refused;
	int host_degraded;
	g16mic_mode desired;
	g16mic_stats base;   /* counters of engines already retired */
	g16mic_stats idle;   /* what to show while no engine runs (counters zero) */
	int engine_live;
	uint64_t gen;
};

struct host {
	const g16mic_host_config *cfg;
	/* node.group and node.link-group of all three streams (see
	 * group_props) */
	char group[48];
	char status_dir[PATH_MAX];
	int have_status_dir;

	struct pw_thread_loop *tl;
	struct pw_context *context;
	struct pw_core *core;
	struct spa_hook core_listener;
	struct pw_registry *registry;
	struct spa_hook registry_listener;

	struct node_ent nodes[NODE_CAP];
	size_t n_nodes;
	int table_full_logged;
	struct link_ent links[LINK_CAP];
	size_t n_links;

	struct pw_stream *capture;
	struct spa_hook capture_listener;
	uint32_t capture_source_id;  /* registry id of the matched source */
	uint32_t capture_node_id;    /* our capture stream's node id, once known */
	enum teardown pending;       /* set from stream callbacks, run by service() */

	uint32_t blocked_id;         /* a source id we will not reconnect to until it goes away */
	g16mic_src_state blocked_state;
	char blocked_reason[32];

	struct out_stream processed, raw;

	_Atomic(struct live *) live;
	atomic_int rt_busy;
	atomic_int raw_channels;     /* channel count of the raw output, 0 while it is being rebuilt */
	atomic_int source_state;
	int capture_streaming;       /* thread-loop thread: the capture is STREAMING, outputs activated */
	int tail_outputs;            /* thread-loop thread: outputs that carried the live engine (retire_engine) */

	/* The same-cycle hand-off. seq: the newest published slot (slot
	 * [seq & 1]; 0 = none yet). wseq: the slot being written (seq + 1 while
	 * the capture callback fills it), so an output can tell its copy was
	 * overwritten. */
	struct cycle_slot slot[2];
	_Atomic uint64_t seq, wseq;
	/* Samples lost (overflow: produced, never delivered) or made up
	 * (underflow: zeros delivered for want of audio) between the capture
	 * and the outputs; the status's ring_overflow / ring_underflow. Never
	 * reset. */
	_Atomic uint64_t out_overflow, out_underflow;
	float *cap_raw, *cap_mono;   /* where frames beyond a slot's SCRATCH_FRAMES go */
	g16mic_spsc telem;

	g16mic_calib cal;
	int cal_ok;
	g16mic_cal_status cal_load;
	g16mic_cal_status spatial_status;
	char spatial_err[256];
	g16mic_params params;
	g16mic_mode desired;
	uint64_t gen;

	struct shared sh;

	pthread_t worker;
	int worker_started;
	atomic_int worker_stop;
	atomic_int core_failed;
};

/* ---- small helpers -------------------------------------------------------- */

static void sleep_us(long us)
{
	struct timespec ts = { .tv_sec = us / 1000000, .tv_nsec = (us % 1000000) * 1000 };

	while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
		;
}

static double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void copy_str(char *dst, size_t len, const char *src)
{
	snprintf(dst, len, "%s", src ? src : "");
}

static void add_counters(g16mic_stats *acc, const g16mic_stats *s)
{
	acc->frames_in += s->frames_in;
	acc->frames_out += s->frames_out;
	acc->blocks += s->blocks;
	acc->fallbacks += s->fallbacks;
	acc->mode_switches += s->mode_switches;
	acc->refused_switches += s->refused_switches;
	acc->nonfinite_samples += s->nonfinite_samples;
	acc->limiter_blocks += s->limiter_blocks;
}

static void zero_counters(g16mic_stats *s)
{
	s->frames_in = s->frames_out = s->blocks = s->fallbacks = 0;
	s->mode_switches = s->refused_switches = s->nonfinite_samples = s->limiter_blocks = 0;
}

static void set_state(struct host *h, g16mic_src_state st, const char *reason)
{
	const char *why = reason ? reason : "";

	atomic_store(&h->source_state, (int)st);
	pthread_mutex_lock(&h->sh.mu);
	int changed = h->sh.state != st || strcmp(h->sh.refuse, why) != 0;
	h->sh.state = st;
	copy_str(h->sh.refuse, sizeof h->sh.refuse, why);
	pthread_mutex_unlock(&h->sh.mu);
	if (!changed)
		return;
	if (*why)
		fprintf(stderr, "g16-mic: source %s: %s (%s)\n", h->cfg->source_name, g16mic_src_state_name(st), why);
	else
		fprintf(stderr, "g16-mic: source %s: %s\n", h->cfg->source_name, g16mic_src_state_name(st));
}

/* Removes our listener first, so the destroy's own state change cannot be
 * mistaken for a failure of the next capture stream. */
static void destroy_capture_stream(struct host *h)
{
	if (!h->capture)
		return;
	spa_hook_remove(&h->capture_listener);
	pw_stream_destroy(h->capture);
	h->capture = NULL;
}

/* ---- the status file (worker thread) -------------------------------------- */

static void compose_status(struct host *h, const struct telem *rec, g16mic_status *st)
{
	const struct shared *sh = &h->sh;

	memset(st, 0, sizeof *st);
	pthread_mutex_lock(&h->sh.mu);
	if (rec && sh->engine_live && rec->gen == sh->gen)
		st->eng = rec->eng;
	else
		st->eng = sh->idle;
	add_counters(&st->eng, &sh->base);
	st->eng.mode_requested = sh->desired;
	st->eng.fallbacks += sh->host_fallbacks;
	st->eng.refused_switches += sh->host_refused;
	if (sh->host_degraded)
		st->eng.degraded = 1;
	st->source_state = sh->state;
	copy_str(st->refuse_reason, sizeof st->refuse_reason, sh->refuse);
	copy_str(st->unavailable_reason, sizeof st->unavailable_reason, sh->unavailable);
	st->reconnects = sh->reconnects;
	st->wrong_links = sh->wrong_links;
	pthread_mutex_unlock(&h->sh.mu);

	copy_str(st->source_name, sizeof st->source_name, h->cfg->source_name);
	st->telemetry_dropped = g16mic_spsc_dropped(&h->telem);
	st->ring_overflow = atomic_load(&h->out_overflow);
	st->ring_underflow = atomic_load(&h->out_underflow);
	st->pid = (long)getpid();
}

static void *worker_main(void *arg)
{
	struct host *h = arg;
	struct telem rec, last;
	int have = 0, warned = 0;

	memset(&last, 0, sizeof last);
	while (!atomic_load(&h->worker_stop)) {
		while (g16mic_spsc_pop(&h->telem, &rec)) {
			last = rec;
			have = 1;
		}
		if (h->have_status_dir) {
			g16mic_status st;
			compose_status(h, have ? &last : NULL, &st);
			if (g16mic_status_write_atomic(h->status_dir, &st) != 0 && !warned) {
				fprintf(stderr, "g16-mic: cannot write the status file in %s: %s\n",
					h->status_dir, strerror(errno));
				warned = 1;
			}
		}
		sleep_us(STATUS_PERIOD_MS * 1000L);
	}
	return NULL;
}

/* ---- real-time callbacks -------------------------------------------------- */

/* RT-safe: runs the output's TRIGGER cycle (out_process, then its
 * consumers) inside the current graph cycle. A negative return (the output
 * is not linked, or not running yet) is nothing to act on: there is no
 * consumer waiting for this cycle. */
static void trigger_output(struct out_stream *o)
{
	if (atomic_load(&o->active) && o->stream)
		(void)pw_stream_trigger_process(o->stream);
}

static void capture_process(void *data)
{
	struct host *h = data;
	struct pw_buffer *b = pw_stream_dequeue_buffer(h->capture);

	if (!b)
		return;
	/* rt_busy covers the engine and the triggers: retire_engine and
	 * destroy_output wait for it to drop before freeing what they use. */
	atomic_store(&h->rt_busy, 1);
	struct live *L = atomic_load(&h->live);
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;

	/* Fill the slot the outputs are not reading: the one of the next
	 * sequence number. wseq tells an output still copying it (it may run
	 * on another data thread) that it is being overwritten. */
	uint64_t next = atomic_load_explicit(&h->seq, memory_order_relaxed) + 1;
	struct cycle_slot *sl = &h->slot[next & 1];
	atomic_store_explicit(&h->wseq, next, memory_order_relaxed);
	atomic_thread_fence(memory_order_release);
	sl->frames = 0;
	sl->channels = 0;

	if (L && d && d->data && d->chunk) {
		int ch = L->channels;
		uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)ch;
		uint32_t off = SPA_MIN(d->chunk->offset, d->maxsize);
		uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - off);
		const float *in = SPA_PTROFF(d->data, off, const float);
		size_t frames = size / stride;
		size_t first = SPA_MIN(frames, (size_t)SCRATCH_FRAMES);

		/* the whole cycle goes through the engine, so its state stays
		 * continuous; a slot carries the first SCRATCH_FRAMES */
		if (first > 0)
			g16mic_engine_process(L->e, in, first, sl->raw, sl->mono);
		for (size_t done = first; done < frames; ) {
			size_t n = SPA_MIN(frames - done, (size_t)SCRATCH_FRAMES);
			g16mic_engine_process(L->e, in + done * (size_t)ch, n, h->cap_raw, h->cap_mono);
			done += n;
		}
		if (frames > first) {
			/* a cycle beyond 8192 frames (170 ms): more than any
			 * output buffer takes; what does not fit is counted */
			uint64_t lost = 0;
			if (atomic_load(&h->processed.active))
				lost += frames - first;
			if (atomic_load(&h->raw.active) && atomic_load(&h->raw_channels) == ch)
				lost += (uint64_t)(frames - first) * (uint64_t)ch;
			atomic_fetch_add(&h->out_overflow, lost);
		}
		sl->frames = first;
		sl->channels = ch;

		struct telem rec;
		g16mic_engine_get_stats(L->e, &rec.eng);
		rec.gen = L->gen;
		rec.ring_overflow = atomic_load(&h->out_overflow);
		rec.ring_underflow = atomic_load(&h->out_underflow);
		rec.source_state = atomic_load(&h->source_state);
		g16mic_spsc_push(&h->telem, &rec);
	}
	pw_stream_queue_buffer(h->capture, b);

	/* Publish the slot, then run both outputs in this same cycle. A cycle
	 * without an engine (a format change in progress) publishes an empty
	 * slot, so a linked consumer still runs its cycle (on zeros, counted). */
	atomic_store_explicit(&h->seq, next, memory_order_release);
	trigger_output(&h->processed);
	trigger_output(&h->raw);
	atomic_store(&h->rt_busy, 0);
}

/* RT-safe: zeros n samples into dst and counts them as made up. */
static void out_zero(struct host *h, float *dst, size_t n)
{
	memset(dst, 0, n * sizeof(float));
	atomic_fetch_add(&h->out_underflow, (uint64_t)n);
}

/* The output's half of the same-cycle hand-off. It runs when the capture
 * triggers it, in the capture's graph cycle and after it (TRIGGER stream in
 * the capture's node.group), so the newest slot is this cycle's audio: the
 * output carries the capture's cycle with no further delay, and both outputs
 * carry the same cycle. Anything else is counted, never hidden: a run with
 * no new slot delivers zeros (ring_underflow), a skipped slot and a slot
 * overwritten while it was being copied are lost (ring_overflow; a torn copy
 * is zeroed, never delivered). In steady state, with one driver and one
 * quantum for all three streams, none of these happen. */
static void out_process(void *data)
{
	struct out_stream *o = data;
	struct host *h = o->h;
	struct pw_buffer *b = pw_stream_dequeue_buffer(o->stream);

	if (!b)
		return;
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;
	if (!d || !d->data || !d->chunk) {
		pw_stream_queue_buffer(o->stream, b);
		return;
	}
	size_t ch = (size_t)o->channels;
	uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)ch;
	size_t maxframes = d->maxsize / stride;
	float *dst = d->data;
	size_t frames;

	uint64_t s = atomic_load_explicit(&h->seq, memory_order_acquire);
	const struct cycle_slot *sl = &h->slot[s & 1];
	/* just activated or (re)started streaming: the newest slot is where
	 * this output starts, the cycles before it were never its to carry */
	if (atomic_exchange(&o->resync, 0) && s > 0)
		o->last_seq = s - 1;

	if (s == 0 || s == o->last_seq) {
		/* no new capture cycle since this output's last run */
		frames = b->requested ? (size_t)b->requested : s > 0 ? sl->frames : 0;
		frames = SPA_MIN(frames, maxframes);
		out_zero(h, dst, frames * ch);
	} else {
		/* exactly the capture's cycle, whatever the consumer asked
		 * for: what the capture produced is what goes out, so an
		 * output never pads or drops to fit a request (at 48 kHz the
		 * request is that same quantum) */
		size_t avail = sl->frames;
		int chs = sl->channels;
		frames = SPA_MIN(avail, maxframes);
		if (s - o->last_seq > 1)
			/* this output missed whole capture cycles; their
			 * slots are gone (counted at this cycle's size) */
			atomic_fetch_add(&h->out_overflow, (s - o->last_seq - 1) * (uint64_t)avail * ch);
		o->last_seq = s;
		if (avail > frames)
			atomic_fetch_add(&h->out_overflow, (uint64_t)(avail - frames) * ch);
		if (!o->is_raw) {
			memcpy(dst, sl->mono, frames * sizeof(float));
		} else if ((size_t)chs == ch) {
			memcpy(dst, sl->raw, frames * ch * sizeof(float));
		} else {
			/* the raw output is being rebuilt for a new channel
			 * count; nothing of this width to carry */
			out_zero(h, dst, frames * ch);
			avail = 0;
		}
		/* the capture may have started this slot's next use (two
		 * cycles on) while we copied: then the copy may be torn */
		atomic_thread_fence(memory_order_acquire);
		if (avail > 0 && atomic_load_explicit(&h->wseq, memory_order_relaxed) >= s + 2) {
			memset(dst, 0, frames * ch * sizeof(float));
			atomic_fetch_add(&h->out_overflow, (uint64_t)frames * ch);
		}
	}
	d->chunk->offset = 0;
	d->chunk->stride = (int32_t)stride;
	d->chunk->size = (uint32_t)(frames * stride);
	pw_stream_queue_buffer(o->stream, b);
}

/* ---- engine lifecycle (thread-loop thread) -------------------------------- */

/* Which outputs are activated (OUT_PROCESSED | OUT_RAW). */
static int active_outputs(struct host *h)
{
	return (atomic_load(&h->processed.active) ? OUT_PROCESSED : 0) | (atomic_load(&h->raw.active) ? OUT_RAW : 0);
}

/* Takes the engine away from the capture callback, waits until no callback
 * still uses it, folds its counters into the totals and frees it.
 *
 * Its tail (the last engine-latency frames still inside it) is not flushed:
 * the outputs carry only what a capture cycle hands them in that cycle, and
 * with the capture going away there is no later cycle to carry it. That tail
 * is counted as lost (ring_overflow) for each output in `outputs` (the ones
 * that were active): at most the engine latency (272 frames, 5.7 ms, for
 * uncalibrated omni) at a source loss, a channel-count change or a stop,
 * never in steady state. Mode switches never retire the engine
 * (handle_mode_request asks the live engine to switch). */
static void retire_engine(struct host *h, int outputs)
{
	struct live *old = atomic_exchange(&h->live, NULL);

	/* outputs deactivated earlier (the capture paused or failed) carried
	 * this engine's audio too */
	outputs |= h->tail_outputs;
	h->tail_outputs = 0;
	if (!old)
		return;
	while (atomic_load(&h->rt_busy))
		sleep_us(50);

	uint64_t tail = (uint64_t)g16mic_engine_latency(old->e), lost = 0;
	if (outputs & OUT_PROCESSED)
		lost += tail;
	if ((outputs & OUT_RAW) && atomic_load(&h->raw_channels) == old->channels)
		lost += tail * (uint64_t)old->channels;
	atomic_fetch_add(&h->out_overflow, lost);

	g16mic_stats s;
	g16mic_engine_get_stats(old->e, &s);
	pthread_mutex_lock(&h->sh.mu);
	add_counters(&h->sh.base, &s);
	h->sh.idle = s;
	zero_counters(&h->sh.idle);
	h->sh.engine_live = 0;
	pthread_mutex_unlock(&h->sh.mu);

	g16mic_engine_destroy(old->e);
	free(old);
}

/* Thread-loop thread. An output that (re)starts streaming (a consumer has
 * linked) starts at the newest slot. Whether the capture triggers it is
 * decided by activation (activate_output), not by this state. */
static void out_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct out_stream *o = data;

	(void)old;
	(void)error;
	if (state == PW_STREAM_STATE_STREAMING)
		atomic_store(&o->resync, 1);
}

static const struct pw_stream_events out_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = out_state_changed,
	.process = out_process,
};

/* Thread-loop thread. The outputs are TRIGGER streams: the graph never runs
 * them on its own, only the capture's trigger does. An active TRIGGER output
 * linked to a consumer is part of its driver's cycle, and the consumer waits
 * for it every cycle; with no capture to trigger it, that wait never ends
 * and the consumer's whole graph cycle stalls (a call app's speaker output
 * on the same driver, for one). So an output is active only while a capture
 * streams: activated when the capture reaches STREAMING, deactivated before
 * the capture pauses or goes away. */
static void activate_output(struct out_stream *o)
{
	if (!o->stream || atomic_load(&o->active))
		return;
	atomic_store(&o->resync, 1);
	pw_stream_set_active(o->stream, true);
	atomic_store(&o->active, 1);
}

/* Returns 1 if the output was active. */
static int deactivate_output(struct out_stream *o)
{
	if (!o->stream || !atomic_exchange(&o->active, 0))
		return 0;
	pw_stream_set_active(o->stream, false);
	return 1;
}

static void activate_outputs(struct host *h)
{
	h->capture_streaming = 1;
	activate_output(&h->processed);
	activate_output(&h->raw);
}

/* Returns which outputs were active (OUT_PROCESSED | OUT_RAW). */
static int deactivate_outputs(struct host *h)
{
	h->capture_streaming = 0;
	int was = (deactivate_output(&h->processed) ? OUT_PROCESSED : 0) | (deactivate_output(&h->raw) ? OUT_RAW : 0);
	h->tail_outputs |= was;
	return was;
}

/* Clears active first and waits out any capture callback in flight, so the
 * capture never triggers a stream that is being destroyed. */
static void destroy_output(struct out_stream *o)
{
	atomic_store(&o->active, 0);
	if (!o->stream)
		return;
	while (atomic_load(&o->h->rt_busy))
		sleep_us(50);
	spa_hook_remove(&o->listener);
	pw_stream_destroy(o->stream);
	o->stream = NULL;
}

/* pos: the channel positions to offer (ch of them); NULL offers MONO for one
 * channel and AUX0.. otherwise. */
/* The capture and both outputs carry one node.group, so PipeWire schedules
 * them with one driver: the source's (the G16's ALSA source is its own
 * driver). The outputs are TRIGGER streams that the capture's process
 * callback runs (pw_stream_trigger_process) after it has handed them this
 * cycle's audio, so they carry the capture's cycle in that same cycle, and
 * their consumers run after them. This is module-filter-chain's pattern.
 * Before it the outputs read rings a cycle behind the capture by graph clock
 * position, and with a source on its own driver a late or overlapping cycle
 * made them zero-fill and then discard a quantum (test_pw_live step 9).
 * node.link-group marks the three as one filter, so the session manager
 * never links one of them into another. */
static void group_props(struct host *h, struct pw_properties *props)
{
	pw_properties_set(props, PW_KEY_NODE_GROUP, h->group);
	pw_properties_set(props, PW_KEY_NODE_LINK_GROUP, h->group);
}

static int create_output(struct host *h, struct out_stream *o, const char *name, const char *desc, int ch, int is_raw,
			 const uint32_t *pos)
{
	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
	const struct spa_pod *params[1];

	/* priority.session/driver 0 and node.virtual: these nodes should not
	 * attract the session manager's default-source choice or drive the
	 * graph. No AUTOCONNECT: they wait to be linked by an application. */
	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CLASS, "Audio/Source",
		PW_KEY_NODE_NAME, name,
		PW_KEY_NODE_DESCRIPTION, desc,
		"node.virtual", "true",
		"priority.session", "0",
		"priority.driver", "0",
		NULL);
	if (!props)
		return -1;
	if (is_raw)
		pw_properties_set(props, "stream.dont-remix", "true");
	group_props(h, props);

	o->h = h;
	o->channels = ch;
	o->is_raw = is_raw;
	o->last_seq = 0;
	atomic_store(&o->active, 0);
	atomic_store(&o->resync, 1);
	for (int i = 0; i < ch && i < G16MIC_MAX_CH; i++)
		o->pos[i] = pos ? pos[i] : ch == 1 ? SPA_AUDIO_CHANNEL_MONO : SPA_AUDIO_CHANNEL_AUX0 + (uint32_t)i;
	o->stream = pw_stream_new(h->core, name, props);
	if (!o->stream)
		return -1;
	pw_stream_add_listener(o->stream, &o->listener, &out_events, o);

	struct spa_audio_info_raw info;
	memset(&info, 0, sizeof info);
	info.format = SPA_AUDIO_FORMAT_F32;
	info.rate = G16MIC_RATE;
	info.channels = (uint32_t)ch;
	for (int i = 0; i < ch && i < G16MIC_MAX_CH; i++)
		info.position[i] = o->pos[i];
	params[0] = spa_format_audio_raw_build(&bld, SPA_PARAM_EnumFormat, &info);

	/* TRIGGER: run only by the capture's trigger, in its cycle.
	 * INACTIVE: until a capture streams (activate_output). */
	int res = pw_stream_connect(o->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
				    PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_TRIGGER |
					    PW_STREAM_FLAG_INACTIVE,
				    params, 1);
	if (res < 0) {
		fprintf(stderr, "g16-mic: cannot offer %s: %s\n", name, spa_strerror(res));
		destroy_output(o);
		return -1;
	}
	return 0;
}

/* The raw output's channel positions: the captured source's own, so a
 * consumer asking for the usual layout (FL FR for a stereo microphone) gets
 * the channels as they are. They come from the negotiated format when it
 * carries positions, else (a capture that asked for no layout negotiates an
 * unpositioned format) from the audio.channel of the source's output ports,
 * by port.id. Positions it cannot carry over (unknown, missing or a
 * duplicate) become AUX0.. for every channel. Before this the raw output
 * always said AUX0..; test_pw_live's raw tap asks for the source's FL FR
 * and checks the samples bit for bit. */
static void raw_positions(const struct spa_audio_info_raw *fmt, const struct node_ent *src, int ch, uint32_t *pos)
{
	const uint32_t *from = NULL;

	if (fmt && !(fmt->flags & SPA_AUDIO_FLAG_UNPOSITIONED))
		from = fmt->position;
	else if (src && ch <= G16MIC_MAX_CH && ch < 32 && (src->port_seen & ((1u << ch) - 1)) == (1u << ch) - 1)
		from = src->port_pos;
	int ok = from != NULL;
	for (int i = 0; ok && i < ch; i++) {
		uint32_t p = from[i];
		if (p == SPA_AUDIO_CHANNEL_UNKNOWN || p == SPA_AUDIO_CHANNEL_NA)
			ok = 0;
		for (int j = 0; ok && j < i; j++)
			if (from[j] == p)
				ok = 0;
	}
	for (int i = 0; i < ch; i++)
		pos[i] = ok ? from[i] : SPA_AUDIO_CHANNEL_AUX0 + (uint32_t)i;
}

/* Makes the raw output carry `ch` channels at positions `pos`. Only called
 * while no engine is live (the capture callback publishes empty slots
 * meanwhile). A raw output (re)created while the capture streams is
 * activated at once; otherwise capture_state_changed activates it. */
static void ensure_raw_output(struct host *h, int ch, const uint32_t *pos)
{
	if (h->raw.stream && h->raw.channels == ch && memcmp(h->raw.pos, pos, (size_t)ch * sizeof *pos) == 0) {
		atomic_store(&h->raw_channels, ch);
		return;
	}
	atomic_store(&h->raw_channels, 0);
	destroy_output(&h->raw);
	if (create_output(h, &h->raw, "g16_mic_raw", "G16 mic (raw passthrough)", ch, 1, pos) == 0) {
		atomic_store(&h->raw_channels, ch);
		if (h->capture_streaming)
			activate_output(&h->raw);
	}
}

static g16mic_cal_status spatial_check(struct host *h, int ch)
{
	char layout[192];
	struct utsname u;

	if (!h->cal_ok) {
		snprintf(h->spatial_err, sizeof h->spatial_err, "%s",
			 h->cfg->calib_path ? h->cfg->calib_path : "no calibration file");
		return h->cal_load;
	}
	snprintf(layout, sizeof layout, "%s/%dch", h->cfg->source_name, ch);
	if (uname(&u) != 0)
		u.release[0] = 0;
	g16mic_cal_context ctx = {
		.stream_channels = ch,
		.layout = layout,
		.kernel_release = u.release,
		.now = time(NULL),
	};
	h->spatial_err[0] = 0;
	return g16mic_calib_check_spatial(&h->cal, &ctx, h->spatial_err, sizeof h->spatial_err);
}

static void fill_idle(struct host *h, g16mic_stats *s, g16mic_mode active)
{
	memset(s, 0, sizeof *s);
	s->mode_requested = h->desired;
	s->mode_active = active;
	s->spatial_available = h->spatial_status == G16MIC_CAL_OK;
	s->spatial_reason = h->spatial_status;
	s->omni_calibrated = h->cal_ok && g16mic_calib_omni_usable(&h->cal, h->cal.channels);
	s->steer_az_deg = h->params.steer_az_deg;
}

/* Called once the capture's channel count is known. All allocation for the
 * real-time path happens here. */
static int setup_engine(struct host *h, int ch, const uint32_t *raw_pos)
{
	retire_engine(h, active_outputs(h));
	ensure_raw_output(h, ch, raw_pos);

	g16mic_cal_status st = spatial_check(h, ch);
	h->spatial_status = st;

	g16mic_params p = h->params;
	g16mic_mode mode = h->desired;
	int fell_back = 0;
	if (g16mic_mode_is_spatial(mode) && st != G16MIC_CAL_OK) {
		fprintf(stderr, "g16-mic: mode %s: UNAVAILABLE (%s: %s); running omni\n",
			g16mic_mode_name(mode), g16mic_cal_status_name(st), h->spatial_err);
		mode = G16MIC_MODE_OMNI;
		fell_back = 1;
	}
	p.mode = mode;
	const g16mic_calib *cal = h->cal_ok ? &h->cal : NULL;
	g16mic_engine *e = g16mic_engine_create(ch, G16MIC_RATE, cal, st, &p);
	if (!e && mode != G16MIC_MODE_RAW) {
		fprintf(stderr, "g16-mic: cannot start mode %s with %d channels; passing raw\n",
			g16mic_mode_name(mode), ch);
		p.mode = mode = G16MIC_MODE_RAW;
		fell_back = 1;
		e = g16mic_engine_create(ch, G16MIC_RATE, cal, st, &p);
	}
	if (!e) {
		fprintf(stderr, "g16-mic: cannot create the processing engine for %d channels\n", ch);
		return -1;
	}
	struct live *L = calloc(1, sizeof *L);
	if (!L) {
		g16mic_engine_destroy(e);
		return -1;
	}
	L->e = e;
	L->channels = ch;
	L->gen = ++h->gen;

	pthread_mutex_lock(&h->sh.mu);
	if (fell_back) {
		h->sh.host_fallbacks++;
		h->sh.host_degraded = 1;
		copy_str(h->sh.unavailable, sizeof h->sh.unavailable, g16mic_cal_status_name(st));
	} else {
		h->sh.host_degraded = 0;
		h->sh.unavailable[0] = 0;
	}
	fill_idle(h, &h->sh.idle, mode);
	h->sh.gen = L->gen;
	h->sh.engine_live = 1;
	pthread_mutex_unlock(&h->sh.mu);

	atomic_store(&h->live, L);
	fprintf(stderr, "g16-mic: capturing %d channels from %s, mode %s, latency %zu frames\n",
		ch, h->cfg->source_name, g16mic_mode_name(mode), g16mic_engine_latency(e));
	return 0;
}

/* ---- the capture stream (thread-loop thread) ------------------------------ */

static void check_links(struct host *h)
{
	if (!h->capture || h->capture_node_id == SPA_ID_INVALID)
		return;
	for (size_t i = 0; i < h->n_links; i++) {
		const struct link_ent *l = &h->links[i];
		if (l->in_node == h->capture_node_id && l->out_node != h->capture_source_id) {
			fprintf(stderr, "g16-mic: node %u was linked into the capture (expected only %u); disconnecting\n",
				l->out_node, h->capture_source_id);
			h->pending = TD_WRONG_LINK;
			return;
		}
	}
}

static void capture_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct host *h = data;

	switch (state) {
	case PW_STREAM_STATE_ERROR:
		fprintf(stderr, "g16-mic: capture stream error: %s\n", error ? error : "unknown");
		h->pending = TD_ERROR;
		break;
	case PW_STREAM_STATE_UNCONNECTED:
		if (old != PW_STREAM_STATE_UNCONNECTED && h->pending == TD_NONE)
			h->pending = TD_ERROR;
		break;
	case PW_STREAM_STATE_PAUSED:
	case PW_STREAM_STATE_STREAMING:
		h->capture_node_id = pw_stream_get_node_id(h->capture);
		set_state(h, G16MIC_SRC_CONNECTED, "");
		check_links(h);
		break;
	default:
		break;
	}
	/* the outputs run only while the capture can trigger them (see
	 * activate_output) */
	if (state == PW_STREAM_STATE_STREAMING)
		activate_outputs(h);
	else if (h->capture_streaming)
		deactivate_outputs(h);
}

static void capture_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
	struct host *h = data;
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
	if (info.format != SPA_AUDIO_FORMAT_F32 || info.rate != G16MIC_RATE ||
	    info.channels < 1 || info.channels > G16MIC_MAX_CH) {
		fprintf(stderr, "g16-mic: unusable capture format (format %u, %u Hz, %u channels; need F32, %d Hz, 1-%d)\n",
			(unsigned)info.format, (unsigned)info.rate, (unsigned)info.channels, G16MIC_RATE, G16MIC_MAX_CH);
		h->pending = TD_ERROR;
		return;
	}
	uint32_t pos[G16MIC_MAX_CH];
	const struct node_ent *src = NULL;
	for (size_t i = 0; i < h->n_nodes; i++)
		if (h->nodes[i].id == h->capture_source_id)
			src = &h->nodes[i];
	raw_positions(&info, src, (int)info.channels, pos);
	if (setup_engine(h, (int)info.channels, pos) != 0)
		h->pending = TD_ERROR;
}

static const struct pw_stream_events capture_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = capture_state_changed,
	.param_changed = capture_param_changed,
	.process = capture_process,
};

static int connect_capture(struct host *h, uint32_t source_id)
{
	uint8_t pod_buf[1024];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
	const struct spa_pod *params[1];

	struct pw_properties *props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Audio",
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_ROLE, "Communication",
		PW_KEY_NODE_NAME, "g16_mic_capture",
		PW_KEY_NODE_DESCRIPTION, "G16 mic capture",
		PW_KEY_TARGET_OBJECT, h->cfg->source_name,
		"node.dont-fallback", "true",
		"node.dont-reconnect", "true",
		"stream.dont-remix", "true",
		"stream.capture.sink", "false",
		NULL);
	if (!props)
		return -1;
	group_props(h, props);
	h->capture = pw_stream_new(h->core, "g16-mic capture", props);
	if (!h->capture)
		return -1;
	h->capture_source_id = source_id;
	h->capture_node_id = SPA_ID_INVALID;
	h->pending = TD_NONE;
	pw_stream_add_listener(h->capture, &h->capture_listener, &capture_events, h);

	/* F32 at 48 kHz, no channel count: the source's own channels pass. */
	struct spa_audio_info_raw info;
	memset(&info, 0, sizeof info);
	info.format = SPA_AUDIO_FORMAT_F32;
	info.rate = G16MIC_RATE;
	params[0] = spa_format_audio_raw_build(&bld, SPA_PARAM_EnumFormat, &info);

	int res = pw_stream_connect(h->capture, PW_DIRECTION_INPUT, PW_ID_ANY,
				    PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
				    params, 1);
	if (res < 0) {
		fprintf(stderr, "g16-mic: cannot connect the capture: %s\n", spa_strerror(res));
		destroy_capture_stream(h);
		return -1;
	}
	fprintf(stderr, "g16-mic: connecting to %s (node %u)\n", h->cfg->source_name, source_id);
	return 0;
}

static void teardown_capture(struct host *h, enum teardown why)
{
	h->pending = TD_NONE;
	if (!h->capture)
		return;
	uint32_t src = h->capture_source_id;

	/* Outputs inactive first, before the capture goes: a TRIGGER output
	 * left active with no capture to trigger it would stall its consumer's
	 * graph cycle (activate_output). Then the engine (its tail is counted
	 * as lost, see retire_engine), then the capture. */
	int was_active = deactivate_outputs(h);
	retire_engine(h, was_active);
	destroy_capture_stream(h);
	h->pending = TD_NONE;
	h->capture_node_id = SPA_ID_INVALID;
	h->capture_source_id = SPA_ID_INVALID;

	switch (why) {
	case TD_REMOVED:
		pthread_mutex_lock(&h->sh.mu);
		h->sh.reconnects++;
		pthread_mutex_unlock(&h->sh.mu);
		set_state(h, G16MIC_SRC_WAITING, "");
		break;
	case TD_WRONG_LINK:
		pthread_mutex_lock(&h->sh.mu);
		h->sh.wrong_links++;
		pthread_mutex_unlock(&h->sh.mu);
		h->blocked_id = src;
		h->blocked_state = G16MIC_SRC_REFUSED;
		copy_str(h->blocked_reason, sizeof h->blocked_reason, "wrong-link");
		set_state(h, G16MIC_SRC_REFUSED, "wrong-link");
		break;
	case TD_ERROR:
		h->blocked_id = src;
		h->blocked_state = G16MIC_SRC_REFUSED;
		copy_str(h->blocked_reason, sizeof h->blocked_reason, "stream-error");
		set_state(h, G16MIC_SRC_REFUSED, "stream-error");
		break;
	default:
		set_state(h, G16MIC_SRC_WAITING, "");
		break;
	}
}

/* Decides, from the node table alone, whether to capture; never picks
 * anything but the named node. */
static void rematch(struct host *h)
{
	g16mic_node_info info[NODE_CAP];
	size_t idx = 0;

	for (size_t i = 0; i < h->n_nodes; i++) {
		info[i].id = h->nodes[i].id;
		info[i].node_name = h->nodes[i].name;
		info[i].media_class = h->nodes[i].media_class;
		info[i].device_class = h->nodes[i].has_device_class ? h->nodes[i].device_class : NULL;
	}
	g16mic_match_result r = g16mic_match_source(h->cfg->source_name, info, h->n_nodes, &idx);
	if (r != G16MIC_MATCH_FOUND) {
		if (h->capture)
			teardown_capture(h, TD_LOST);
		if (r == G16MIC_MATCH_ABSENT)
			set_state(h, G16MIC_SRC_WAITING, "");
		else
			set_state(h, G16MIC_SRC_REFUSED, g16mic_match_result_name(r));
		return;
	}
	uint32_t id = h->nodes[idx].id;
	if (h->capture && h->capture_source_id == id)
		return;
	if (h->capture)
		teardown_capture(h, TD_LOST);
	if (id == h->blocked_id) {
		set_state(h, h->blocked_state, h->blocked_reason);
		return;
	}
	if (connect_capture(h, id) != 0)
		set_state(h, G16MIC_SRC_REFUSED, "stream-error");
}

/* Runs deferred teardowns, then re-decides. Never called from inside a
 * capture stream callback (destroying a stream there is not allowed). */
static void service(struct host *h)
{
	if (h->pending != TD_NONE)
		teardown_capture(h, h->pending);
	rematch(h);
}

/* ---- registry (thread-loop thread) ---------------------------------------- */

static uint32_t dict_u32(const struct spa_dict *props, const char *key)
{
	const char *v = spa_dict_lookup(props, key);
	char *end;

	if (!v || !*v)
		return SPA_ID_INVALID;
	errno = 0;
	unsigned long n = strtoul(v, &end, 10);
	if (errno || *end != 0 || n >= SPA_ID_INVALID)
		return SPA_ID_INVALID;
	return (uint32_t)n;
}

static void registry_global(void *data, uint32_t id, uint32_t permissions, const char *type,
			    uint32_t version, const struct spa_dict *props)
{
	struct host *h = data;

	(void)permissions;
	(void)version;
	if (!props || !type)
		return;
	if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
		const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
		const char *mclass = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
		const char *dclass = spa_dict_lookup(props, "device.class");
		if (!name)
			return;
		/* Audio nodes, plus anything carrying the wanted name so the
		 * matcher can refuse it by class. */
		if (!(mclass && strncmp(mclass, "Audio/", 6) == 0) && strcmp(name, h->cfg->source_name) != 0)
			return;
		if (h->n_nodes >= NODE_CAP) {
			if (!h->table_full_logged)
				fprintf(stderr, "g16-mic: more than %d audio nodes; ignoring the rest\n", NODE_CAP);
			h->table_full_logged = 1;
			return;
		}
		struct node_ent *n = &h->nodes[h->n_nodes++];
		memset(n, 0, sizeof *n);
		n->id = id;
		copy_str(n->name, sizeof n->name, name);
		copy_str(n->media_class, sizeof n->media_class, mclass);
		n->has_device_class = dclass != NULL;
		copy_str(n->device_class, sizeof n->device_class, dclass);
		const char *chs = spa_dict_lookup(props, PW_KEY_AUDIO_CHANNELS);
		n->channels = chs ? atoi(chs) : 0;
		service(h);
	} else if (strcmp(type, PW_TYPE_INTERFACE_Link) == 0) {
		if (h->n_links >= LINK_CAP)
			return;
		struct link_ent *l = &h->links[h->n_links++];
		l->id = id;
		l->out_node = dict_u32(props, PW_KEY_LINK_OUTPUT_NODE);
		l->in_node = dict_u32(props, PW_KEY_LINK_INPUT_NODE);
		check_links(h);
		service(h);
	} else if (strcmp(type, PW_TYPE_INTERFACE_Port) == 0) {
		uint32_t node = dict_u32(props, PW_KEY_NODE_ID), idx = dict_u32(props, PW_KEY_PORT_ID);
		const char *dir = spa_dict_lookup(props, PW_KEY_PORT_DIRECTION);
		const char *mon = spa_dict_lookup(props, PW_KEY_PORT_MONITOR);
		const char *chan = spa_dict_lookup(props, PW_KEY_AUDIO_CHANNEL);
		if (!dir || strcmp(dir, "out") != 0 || (mon && strcmp(mon, "true") == 0) || !chan || idx >= G16MIC_MAX_CH ||
		    idx >= 32)
			return;
		for (size_t i = 0; i < h->n_nodes; i++) {
			if (h->nodes[i].id == node) {
				h->nodes[i].port_pos[idx] = spa_type_audio_channel_from_short_name(chan);
				h->nodes[i].port_seen |= 1u << idx;
				break;
			}
		}
	}
}

static void registry_global_remove(void *data, uint32_t id)
{
	struct host *h = data;

	for (size_t i = 0; i < h->n_links; i++) {
		if (h->links[i].id == id) {
			h->links[i] = h->links[--h->n_links];
			return;
		}
	}
	for (size_t i = 0; i < h->n_nodes; i++) {
		if (h->nodes[i].id != id)
			continue;
		if (h->capture && h->capture_source_id == id) {
			teardown_capture(h, TD_REMOVED);
		} else if (h->blocked_id == id) {
			/* the stream had already failed on its way out */
			pthread_mutex_lock(&h->sh.mu);
			h->sh.reconnects++;
			pthread_mutex_unlock(&h->sh.mu);
		}
		if (h->blocked_id == id)
			h->blocked_id = SPA_ID_INVALID;
		h->nodes[i] = h->nodes[--h->n_nodes];
		service(h);
		return;
	}
}

static const struct pw_registry_events registry_events = {
	PW_VERSION_REGISTRY_EVENTS,
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static void core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
	struct host *h = data;

	(void)seq;
	fprintf(stderr, "g16-mic: PipeWire error on %u: %s (%s)\n", id, message ? message : "", spa_strerror(res));
	if (id == PW_ID_CORE && res == -EPIPE)
		atomic_store(&h->core_failed, 1);
}

static const struct pw_core_events core_events = {
	PW_VERSION_CORE_EVENTS,
	.error = core_error,
};

/* ---- mode requests (main thread, thread loop locked) ---------------------- */

static void handle_mode_request(struct host *h)
{
	char path[PATH_MAX + 16], word[32];
	g16mic_mode m;

	if (!h->have_status_dir)
		return;
	snprintf(path, sizeof path, "%s/mode-request", h->status_dir);
	FILE *f = fopen(path, "re");
	if (!f) {
		fprintf(stderr, "g16-mic: SIGUSR1 without %s\n", path);
		return;
	}
	size_t n = fread(word, 1, sizeof word - 1, f);
	fclose(f);
	unlink(path);
	word[n] = 0;
	while (n > 0 && (word[n - 1] == '\n' || word[n - 1] == ' ' || word[n - 1] == '\t' || word[n - 1] == '\r'))
		word[--n] = 0;
	if (g16mic_mode_parse(word, &m) != 0) {
		fprintf(stderr, "g16-mic: ignoring unknown mode request '%s'\n", word);
		return;
	}

	struct live *L = atomic_load(&h->live);
	int ok;
	if (L) {
		ok = g16mic_engine_request_mode(L->e, m) == 0;
	} else {
		ok = !(g16mic_mode_is_spatial(m) && h->spatial_status != G16MIC_CAL_OK);
		if (!ok) {
			pthread_mutex_lock(&h->sh.mu);
			h->sh.host_refused++;
			pthread_mutex_unlock(&h->sh.mu);
		}
	}
	if (!ok) {
		fprintf(stderr, "g16-mic: mode %s refused: UNAVAILABLE (%s: %s)\n", g16mic_mode_name(m),
			g16mic_cal_status_name(h->spatial_status), h->spatial_err);
		return;
	}
	h->desired = m;
	pthread_mutex_lock(&h->sh.mu);
	h->sh.desired = m;
	h->sh.host_degraded = 0;
	h->sh.unavailable[0] = 0;
	h->sh.idle.mode_requested = m;
	if (!L)
		h->sh.idle.mode_active = m;
	pthread_mutex_unlock(&h->sh.mu);
	fprintf(stderr, "g16-mic: mode %s\n", g16mic_mode_name(m));
}

/* ---- run ------------------------------------------------------------------ */

static int status_owned_by_live_process(const char *dir)
{
	char path[PATH_MAX + 16];
	long pid;

	snprintf(path, sizeof path, "%s/status", dir);
	if (g16mic_status_read_pid(path, &pid) != 0)
		return 0;
	return pid != (long)getpid() && g16mic_pid_alive(pid);
}

static void free_buffers(struct host *h)
{
	g16mic_spsc_free(&h->telem);
	free(h->cap_raw);
	free(h->cap_mono);
	for (int i = 0; i < 2; i++) {
		free(h->slot[i].raw);
		free(h->slot[i].mono);
	}
}

static int alloc_buffers(struct host *h)
{
	size_t raw = (size_t)SCRATCH_FRAMES * G16MIC_MAX_CH;

	if (g16mic_spsc_init(&h->telem, sizeof(struct telem), TELEM_CAP) != 0)
		return -1;
	h->cap_raw = calloc(raw, sizeof(float));
	h->cap_mono = calloc(SCRATCH_FRAMES, sizeof(float));
	if (!h->cap_raw || !h->cap_mono)
		return -1;
	for (int i = 0; i < 2; i++) {
		h->slot[i].raw = calloc(raw, sizeof(float));
		h->slot[i].mono = calloc(SCRATCH_FRAMES, sizeof(float));
		if (!h->slot[i].raw || !h->slot[i].mono)
			return -1;
	}
	return 0;
}

int g16mic_host_run(const g16mic_host_config *cfg)
{
	sigset_t sigs;
	int rc = 0;

	if (!cfg || !cfg->source_name)
		return 1;

	/* Block before any thread exists so every thread inherits the mask and
	 * only sigtimedwait() below receives these. */
	sigemptyset(&sigs);
	sigaddset(&sigs, SIGINT);
	sigaddset(&sigs, SIGTERM);
	sigaddset(&sigs, SIGUSR1);
	pthread_sigmask(SIG_BLOCK, &sigs, NULL);

	struct host *h = calloc(1, sizeof *h);
	if (!h)
		return 1;
	h->cfg = cfg;
	snprintf(h->group, sizeof h->group, "g16-mic-%ld", (long)getpid());
	h->capture_source_id = SPA_ID_INVALID;
	h->capture_node_id = SPA_ID_INVALID;
	h->blocked_id = SPA_ID_INVALID;
	atomic_init(&h->live, NULL);

	if (cfg->status_dir)
		h->have_status_dir = snprintf(h->status_dir, sizeof h->status_dir, "%s", cfg->status_dir) <
				     (int)sizeof h->status_dir;
	else
		h->have_status_dir = g16mic_status_dir(h->status_dir, sizeof h->status_dir) == 0;
	if (!h->have_status_dir)
		fputs("g16-mic: XDG_RUNTIME_DIR is not set: no status file, and set-mode cannot reach this run\n", stderr);
	else if (status_owned_by_live_process(h->status_dir)) {
		fprintf(stderr, "g16-mic: already running (see %s/status)\n", h->status_dir);
		free(h);
		return 3;
	}

	/* calibration */
	if (cfg->calib_path) {
		char err[256];
		h->cal_load = g16mic_calib_load(cfg->calib_path, &h->cal, err, sizeof err);
		h->cal_ok = h->cal_load == G16MIC_CAL_OK;
		if (!h->cal_ok && h->cal_load != G16MIC_CAL_MISSING)
			fprintf(stderr, "g16-mic: calibration %s: %s: %s\n", cfg->calib_path,
				g16mic_cal_status_name(h->cal_load), err);
	} else {
		h->cal_load = G16MIC_CAL_MISSING;
	}
	g16mic_params_default(&h->params);
	h->params.mode = cfg->mode;
	h->params.steer_az_deg = cfg->steer_az_deg;
	h->desired = cfg->mode;
	h->spatial_status = spatial_check(h, h->cal_ok ? h->cal.channels : 1);

	if (alloc_buffers(h) != 0) {
		fputs("g16-mic: out of memory\n", stderr);
		free_buffers(h);
		free(h);
		return 1;
	}
	pthread_mutex_init(&h->sh.mu, NULL);
	h->sh.state = G16MIC_SRC_WAITING;
	h->sh.desired = h->desired;
	fill_idle(h, &h->sh.idle,
		  g16mic_mode_is_spatial(h->desired) && h->spatial_status != G16MIC_CAL_OK ? G16MIC_MODE_OMNI : h->desired);

	pw_init(NULL, NULL);
	h->tl = pw_thread_loop_new("g16-mic", NULL);
	if (!h->tl) {
		rc = 1;
		goto out_deinit;
	}
	h->context = pw_context_new(pw_thread_loop_get_loop(h->tl), NULL, 0);
	if (!h->context || pw_thread_loop_start(h->tl) < 0) {
		fputs("g16-mic: cannot start the PipeWire loop\n", stderr);
		rc = 1;
		goto out_loop;
	}

	pw_thread_loop_lock(h->tl);
	h->core = pw_context_connect(h->context,
				     pw_properties_new(PW_KEY_APP_NAME, "g16-mic", NULL), 0);
	if (!h->core) {
		pw_thread_loop_unlock(h->tl);
		fprintf(stderr, "g16-mic: cannot connect to PipeWire: %s\n", strerror(errno));
		rc = 1;
		goto out_stop;
	}
	pw_core_add_listener(h->core, &h->core_listener, &core_events, h);
	if (create_output(h, &h->processed, "g16_mic_processed", "G16 mic (processed)", 1, 0, NULL) != 0) {
		pw_thread_loop_unlock(h->tl);
		rc = 1;
		goto out_stop;
	}
	h->registry = pw_core_get_registry(h->core, PW_VERSION_REGISTRY, 0);
	pw_registry_add_listener(h->registry, &h->registry_listener, &registry_events, h);
	pw_thread_loop_unlock(h->tl);

	if (pthread_create(&h->worker, NULL, worker_main, h) == 0)
		h->worker_started = 1;
	else
		fputs("g16-mic: cannot start the status thread; running without a status file\n", stderr);

	double deadline = cfg->run_seconds > 0 ? now_s() + cfg->run_seconds : 0;
	struct timespec tick = { .tv_sec = 0, .tv_nsec = TICK_MS * 1000000L };
	for (;;) {
		int sig = sigtimedwait(&sigs, NULL, &tick);
		if (sig == SIGINT || sig == SIGTERM)
			break;
		if (atomic_load(&h->core_failed)) {
			fputs("g16-mic: lost the PipeWire connection\n", stderr);
			rc = 1;
			break;
		}
		pw_thread_loop_lock(h->tl);
		if (sig == SIGUSR1)
			handle_mode_request(h);
		service(h);
		pw_thread_loop_unlock(h->tl);
		if (deadline > 0 && now_s() >= deadline)
			break;
	}

	/* Stop: outputs inactive (before the capture goes, see
	 * activate_output), the engine retired (its tail, at most the engine
	 * latency, counted as lost), the capture destroyed, then the rest. */
	pw_thread_loop_lock(h->tl);
	int was_active = deactivate_outputs(h);
	retire_engine(h, was_active);
	destroy_capture_stream(h);
	pw_thread_loop_unlock(h->tl);

out_stop:
	pw_thread_loop_stop(h->tl);
	destroy_output(&h->raw);
	destroy_output(&h->processed);
	destroy_capture_stream(h);
	if (h->registry) {
		spa_hook_remove(&h->registry_listener);
		pw_proxy_destroy((struct pw_proxy *)h->registry);
	}
	if (h->core) {
		spa_hook_remove(&h->core_listener);
		pw_core_disconnect(h->core);
	}
out_loop:
	if (h->context)
		pw_context_destroy(h->context);
	pw_thread_loop_destroy(h->tl);
out_deinit:
	pw_deinit();

	if (h->worker_started) {
		atomic_store(&h->worker_stop, 1);
		pthread_join(h->worker, NULL);
	}
	if (h->have_status_dir) {
		char path[PATH_MAX + 16];
		snprintf(path, sizeof path, "%s/status", h->status_dir);
		unlink(path);
		snprintf(path, sizeof path, "%s/mode-request", h->status_dir);
		unlink(path);
	}
	struct live *L = atomic_exchange(&h->live, NULL);
	if (L) {
		g16mic_engine_destroy(L->e);
		free(L);
	}
	pthread_mutex_destroy(&h->sh.mu);
	free_buffers(h);
	free(h);
	return rc;
}
