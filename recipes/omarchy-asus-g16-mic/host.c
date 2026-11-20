/* SPDX-License-Identifier: MIT */
/* host.c: the PipeWire side of the g16-mic daemon.
 *
 * Tested live by test_pw_live (test_pw_live.sh + test_pw_helper.c): it runs
 * this file against a private PipeWire daemon and WirePlumber that load only
 * null/dummy drivers (no ALSA, Bluetooth, Pulse or JACK; no sound), feeds it
 * a synthetic named source beside a decoy source and a sink monitor, and
 * checks the outputs bit for bit (raw) and against an offline omni engine
 * (processed), the links, a remove/re-add of the source, the stop drain,
 * contention and overload. It skips only where the pipewire or wireplumber
 * binaries are missing (the PKGBUILD's checkdepends puts both in the clean
 * chroot, so it runs there). Every decision is delegated to pure functions
 * with their own unit tests: which node to capture (g16mic_match_source,
 * match.c, test_match.c), whether the spatial modes may run
 * (g16mic_calib_check_spatial, calib.c), the processing (engine.c), the
 * hand-off between the capture and the outputs (handoff.c, test_handoff.c)
 * and the status file (status.c, test_status.c). What is left here is
 * wiring: the registry, the streams, the threads, real time, and the stop
 * and source-loss sequences.
 *
 * Hand-off: the capture and both outputs carry one node.group, so one driver
 * (the source's) schedules them. The outputs are TRIGGER streams; the
 * capture's process callback gives each cycle to g16mic_handoff_capture,
 * which runs the engine and pushes the cycle (mono, and the raw frames) into
 * a bounded, preallocated, lock-free queue per output that a consumer is
 * reading, then triggers both outputs. An output's process callback takes
 * exactly one quantum from its queue (g16mic_handoff_output with the
 * buffer's requested size, else the capture's cycle size) and its buffer
 * carries exactly that, never more. That matters: PipeWire's output adapter
 * (audioconvert) consumes one quantum per graph cycle and keeps the rest of
 * a larger buffer inside itself, where it is neither visible nor counted (it
 * added a hidden cycle of latency, was dropped uncounted at a stop or source
 * loss, and reached a reconnected stream ahead of its own audio). So all
 * buffering is in our own queue, where it is counted.
 *
 * In steady state each output takes the capture's cycle in that same cycle,
 * so the end-to-end latency is exactly the engine latency (test_pw_live step
 * 5). When a trigger is refused (the output's previous cycle is not finished)
 * or an output run is missed, that cycle's audio waits in the queue and the
 * added latency grows by it (queue_added_frames and queue_added_ms now,
 * queue_max_added_frames and queue_max_added_ms observed). There is no
 * catch-up: an output never delivers more than one quantum a run. The one
 * way back is the latency trim (g16mic_handoff.h): once both outputs have
 * held a whole extra cycle for G16MIC_HF_TRIM_HOLDOFF_MS (1 s), the capture
 * withholds a cycle from both, at most one per G16MIC_HF_TRIM_EVERY_CYCLES
 * (4) cycles and only a cycle that is quiet on every channel (below -60
 * dBFS, so never speech or a marker), counted in latency_trimmed_frames
 * (samples) and latency_trimmed_cycles, never reset and not a loss. Without
 * it sporadic graph xruns would ratchet the queue to its bound and then
 * overflow. On input that is never quiet the latency stays. The hard
 * bound is the queue's capacity, G16MIC_HF_CAP_CYCLES (8) cycles (170.7 ms
 * at a 1024-frame quantum; status queue_capacity_cycles, queue_bound_ms).
 * Beyond it the OLDEST audio is dropped and counted exactly (overflow); an
 * output with nothing queued delivers zeros, counted (underflow). The
 * status's ring_overflow is the sum of every loss cause, ring_underflow the
 * zeros the outputs had to make up; eos_pad counts the zeros that complete
 * the last quantum at the end of a stream (not a loss). Both outputs take
 * the same cycles, so processed and raw stay sample aligned. No counter is
 * ever reset.
 *
 * Epochs: each engine starts a new epoch (setup_engine, before the new
 * capture's first cycle). Anything still queued from an earlier epoch is
 * dropped and counted (stale_dropped), never delivered after the new
 * stream's audio, so a reconnected source never carries the old source's
 * tail; after a source loss the queues are emptied and counted anyway. An
 * output that starts streaming (a consumer links late) starts at current
 * audio, not the backlog (late_link_discarded): for G16MIC_HF_START_CYCLES
 * capture cycles after the link (out_state_changed, start_output) or the
 * output's first active cycle (capture_process, relink), an output that
 * still holds more than the cycle just pushed, right after the capture's
 * push, restarts at that cycle. That check is after the push of the same
 * graph cycle on purpose: right after a link PipeWire can run the output
 * BEFORE the capture in a cycle (the link schedules it as well as our
 * trigger, which it then refuses), so the run takes the previous cycle;
 * once the order turns normal such an output took the cycle before the
 * capture's every cycle, one cycle behind for good (test_pw_live step 6:
 * latency 1296 = 272 + 1024, queue_added_frames 1024). Round 2 looked only
 * at the output's own first 4 runs, which a longer output-first spell
 * outlasted.
 *
 * Stop (SIGINT, SIGTERM, run_seconds): g16mic_handoff_begin_stop; from then
 * on the capture accepts no input and instead pushes the engine's latency
 * tail once (the last 272 frames of accepted audio for uncalibrated omni).
 * The capture keeps triggering both outputs every cycle, and they deliver
 * the queue quantum by quantum (the tail zero-padded to a whole quantum,
 * eos_pad) until g16mic_handoff_drained says each has delivered its last
 * buffer and run once more after it, i.e. the last accepted cycle has
 * passed through the graph. If the capture stops delivering cycles meanwhile,
 * the control thread pushes the tail itself and triggers the outputs once
 * per quantum period. The control thread waits at most G16MIC_HF_DRAIN_MS
 * (500 ms). Only then are the outputs deactivated and the capture
 * destroyed; whatever could not be delivered (no consumer, a stalled
 * consumer) is counted exactly as drain_lost.
 *
 * Source loss (removed, lost, error, wrong link): the engine is taken from
 * the capture callback and its tail flushed into the queues on the control
 * thread (g16mic_handoff_flush_tail). With no capture to trigger them, the
 * outputs are triggered from here once per quantum period for at most
 * G16MIC_HF_TAIL_WINDOW_MS (50 ms), until each is drained; the tail and
 * everything still queued after that is counted exactly as source_lost_tail
 * per output. Nothing of it can reach a reconnected stream.
 *
 * Real time: the data thread is made real-time by PipeWire's own mechanism,
 * libpipewire-module-rt, which client.conf loads first in context.modules
 * (RLIMIT_RTPRIO, else RTKit, else the realtime portal; never root, never a
 * sched_setscheduler of our own). The worker reads the data thread's actual
 * policy and priority and reports them (rt_status, rt_policy, rt_priority,
 * and rt_reason when it is not real-time).
 *
 * RED -> GREEN:
 *   - test_pw_live step 9: the outputs used to read rings a cycle behind the
 *     capture by graph clock position; with a source on its own driver both
 *     ring counters grew in steady state. A same-cycle hand-off fixed it.
 *   - test_handoff and test_pw_live steps 10-13: that same-cycle hand-off had
 *     two slots and no slack. Under build-load contention with no real-time
 *     scheduling one refused or late output trigger lost a whole cycle:
 *     ring_overflow grew by 3072, one 1024-frame cycle on both outputs (1024
 *     mono + 2 x 1024 raw). A stop or source loss also dropped the engine
 *     tail. The bounded queue, real time through module-rt, the drain and
 *     the tail flush fixed both.
 *   - test_handoff (j) and test_pw_live step 6: a late listener that
 *     PipeWire first ran before the capture stayed one cycle behind for
 *     good. The start window, checked after the capture's push, fixed it.
 *   - test_handoff (k)-(o): nothing brought added latency back, so sporadic
 *     graph xruns could ratchet it up to the bound and then overflow
 *     (test_pw_live step 12 at a load average of 43 on 16 cores: +8192).
 *     The quiet-only latency trim brings it back in pauses; step 12's
 *     signal has no quiet cycle, so there latency_trimmed_frames stays 0.
 *   - test_pw_live steps 6 and 10-13 and the consumer stall: a first queue
 *     caught up by writing several cycles into one output buffer. The
 *     adapter kept what did not fit the quantum hidden, so latency grew a
 *     cycle after a reconnect (1296 instead of 272 frames), the last
 *     accepted cycle never arrived at a stop although drain_lost was 0, a
 *     source loss lost 272 raw frames uncounted, and a reconnected stream
 *     started with the old tail. Exact-quantum buffers, with all buffering
 *     in the counted queue, fixed them.
 *
 * Threads:
 *   - the PipeWire thread loop: registry and stream events, engine creation
 *     (all allocation), connect/disconnect, output activation, the
 *     source-loss tail window;
 *   - PipeWire's data thread(s): the three RT_PROCESS callbacks. They never
 *     allocate, lock, sleep or do I/O. The capture callback is the only
 *     producer of the hand-off and of the telemetry queue; each output
 *     callback is the only consumer of its own queue;
 *   - a worker thread: drains the telemetry queue, reads the data thread's
 *     scheduling, and rewrites the status file every 250 ms;
 *   - the main thread: waits for signals with sigtimedwait() (all three are
 *     blocked in every thread before any thread starts, so delivery does not
 *     depend on PipeWire's signal handling), applies mode requests, runs
 *     deferred stream teardowns and the stop drain.
 *
 * What it never does: capture anything but the source named by node.name
 * (no "first available", no fallback target, no reconnect by any other
 * key), change the default source, or start by itself.
 */
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/audio/raw-types.h>
#include <spa/param/buffers.h>
#include <spa/param/format-utils.h>
#include <spa/pod/builder.h>
#include <spa/utils/defs.h>
#include <spa/utils/result.h>

#include "g16mic.h"
#include "g16mic_handoff.h"
#include "g16mic_host.h"

#define NODE_CAP 256
#define LINK_CAP 512
#define TELEM_CAP 64
#define STATUS_PERIOD_MS 250
#define TICK_MS 100
#define RT_CHECK_PERIODS 20          /* re-read the data thread's scheduling every 5 s */
#define DRAIN_STEP_US 2000

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
	int source_state;
};

struct host;

struct out_stream {
	struct host *h;
	struct pw_stream *stream;
	struct spa_hook listener;
	int channels;
	int is_raw;
	int idx;                      /* G16MIC_HF_PROCESSED or G16MIC_HF_RAW */
	uint32_t pos[G16MIC_MAX_CH];  /* channel positions offered */
	/* active: set (thread-loop thread) while the stream is activated, i.e.
	 * while a capture streams or the source-loss tail window runs; it is
	 * triggered only then. busy: its process callback is running (the
	 * control thread waits it out before g16mic_handoff_abandon or a
	 * destroy). */
	atomic_int active, busy;
	/* data thread (capture_process): active as it last saw it; a rise
	 * relinks the output's queue at the cycle it pushes next */
	int seen_active;
	/* thread-loop thread: the stream left STREAMING while deactivated; the
	 * hand-off's consuming flag drops at settle_consuming */
	int unconsume_pending;
	/* Graph cycles this output's node missed (graph_missed): its driver
	 * ran a cycle without running the output, PipeWire's graph-xrun
	 * recovery after g16-mic's data thread ran late, so every consumer got
	 * a quantum of PipeWire's silence for it while the audio stays in the
	 * queue (queue_added_frames grows by it). position: the driver's
	 * spa_io_position (io_changed); the data thread keeps the last run's
	 * clock and position in last_*; pos_reset (set on a state change or
	 * activation) makes the next run start over, so a link, an unlink or a
	 * driver change is never counted. missed: frames, at 48 kHz. */
	_Atomic(struct spa_io_position *) position;
	atomic_int pos_reset;
	uint64_t last_pos, last_dur;
	uint32_t last_clock;
	int have_last;
	_Atomic uint64_t missed;
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

/* The data thread's observed scheduling; written and read by the worker
 * only. */
struct rt_report {
	int known, logged;
	char status[16];   /* "realtime", "not-realtime", "unknown" */
	char policy[16];   /* "fifo", "rr", "other", "batch", "idle", "unknown" */
	int priority;
	char reason[64];
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
	/* rt_busy: a capture callback is running (the engine, the hand-off,
	 * the triggers). cap_gate: the control thread owns the hand-off's
	 * producer side (flush_tail); a capture callback that sees it set
	 * recycles its buffer and touches nothing else. */
	atomic_int rt_busy, cap_gate;
	atomic_int raw_channels;     /* channel count of the raw output, 0 while it is being rebuilt */
	atomic_int source_state;
	int capture_streaming;       /* thread-loop thread: the capture is STREAMING, outputs activated */
	int stop_requested;          /* thread-loop lock: the stop drain runs; no reconnect, no reset_stop */

	/* The bounded per-output queues between the capture and the outputs
	 * (handoff.c). */
	g16mic_handoff *hf;
	/* The graph position and frame count of the last cycle the hand-off
	 * accepted, stored by the capture callback for the stop log. The
	 * position is the driver's clock position in 48 kHz samples, read from
	 * the spa_io_position the capture was handed (capture_io_changed), the
	 * one every node of that driver shares; pw_stream_get_time_n()'s ticks
	 * count from the stream's own base and line up with nothing else. */
	_Atomic uint64_t last_ticks, last_frames;
	_Atomic(struct spa_io_position *) cap_position;
	atomic_int last_valid;
	/* Capture cycles that triggered the outputs (not gated), counted by the
	 * capture callback: the stop drain's sign that the capture still runs
	 * them (else it triggers them itself, fallback_trigger). */
	_Atomic uint64_t cap_cycles;
	/* The data thread's tid, recorded once by the capture callback, for the
	 * worker's real-time report. */
	atomic_int data_tid;
	int rt_requested;            /* module-rt is in the client context (see g16mic_host_run) */
	struct rt_report rt;         /* worker thread only */
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
	atomic_store(&h->cap_position, NULL);
}

/* ---- the status file (worker thread) -------------------------------------- */

static double cycles_ms(uint64_t cycles, size_t cycle_frames)
{
	return (double)cycles * (double)cycle_frames * 1000.0 / (double)G16MIC_RATE;
}

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

	/* The hand-off's counters: ring_overflow is every sample lost between
	 * the capture and the outputs, whatever the cause (each cause also has
	 * its own field), ring_underflow the zeros the outputs made up, eos_pad
	 * the zeros that completed the last quantum at an end of stream,
	 * latency_trimmed_frames the quiet samples the latency trim withheld
	 * (not a loss, not in ring_overflow). The added latency (now and
	 * observed) is the larger of the two outputs'. */
	g16mic_hf_stats hs;
	g16mic_handoff_get_stats(h->hf, &hs);
	size_t cf = hs.last_cycle_frames ? (size_t)hs.last_cycle_frames : 1024;
	uint64_t max_depth = 0, added = 0, max_added = 0;
	st->ring_overflow = g16mic_handoff_lost_samples(&hs);
	st->ring_underflow = 0;
	for (int i = 0; i < G16MIC_HF_NOUT; i++) {
		st->ring_underflow += hs.out[i].underflow;
		st->eos_pad += hs.out[i].eos_pad;
		st->late_runs += hs.out[i].late_runs;
		st->stale_dropped += hs.out[i].stale_dropped;
		st->late_link_discarded += hs.out[i].late_link_discarded;
		st->drain_lost += hs.out[i].drain_lost;
		st->source_lost_tail += hs.out[i].source_lost_tail;
		st->latency_trimmed_frames += hs.out[i].latency_trimmed;
		if (hs.out[i].max_depth > max_depth)
			max_depth = hs.out[i].max_depth;
		if (hs.out[i].added_frames > added)
			added = hs.out[i].added_frames;
		if (hs.out[i].max_added_frames > max_added)
			max_added = hs.out[i].max_added_frames;
	}
	st->queue_capacity_cycles = G16MIC_HF_CAP_CYCLES;
	st->queue_bound_ms = cycles_ms(G16MIC_HF_CAP_CYCLES, cf);
	st->queue_max_depth_cycles = max_depth;
	st->queue_added_frames = added;
	st->queue_added_ms = (double)added * 1000.0 / (double)G16MIC_RATE;
	st->queue_max_added_frames = max_added;
	st->latency_trimmed_cycles = hs.latency_trims;
	st->queue_max_added_ms = (double)max_added * 1000.0 / (double)G16MIC_RATE;
	st->capture_gap = hs.capture_gap_frames;
	st->tail_flushed = hs.tail_flushed_frames;
	st->trigger_refused = hs.trigger_refused;
	st->graph_missed_processed_frames = atomic_load_explicit(&h->processed.missed, memory_order_relaxed);
	st->graph_missed_raw_frames = atomic_load_explicit(&h->raw.missed, memory_order_relaxed);
	st->trigger_errno = hs.trigger_errno;

	st->rt_requested = h->rt_requested;
	copy_str(st->rt_status, sizeof st->rt_status, h->rt.known ? h->rt.status : "unknown");
	copy_str(st->rt_policy, sizeof st->rt_policy, h->rt.known ? h->rt.policy : "unknown");
	st->rt_priority = h->rt.known ? h->rt.priority : 0;
	copy_str(st->rt_reason, sizeof st->rt_reason, h->rt.reason);
	st->pid = (long)getpid();
}

static const char *policy_name(int pol)
{
	switch (pol) {
	case SCHED_FIFO: return "fifo";
	case SCHED_RR: return "rr";
	case SCHED_OTHER: return "other";
	case SCHED_BATCH: return "batch";
	case SCHED_IDLE: return "idle";
	default: return "unknown";
	}
}

/* Reads the data thread's actual scheduling (the tid the capture callback
 * recorded) into h->rt. Real-time means FIFO or RR, whoever granted it
 * (module-rt via RLIMIT_RTPRIO, RTKit or the realtime portal). Logs the
 * first observation. */
static void check_rt(struct host *h, pid_t tid)
{
	struct rt_report *r = &h->rt;
	struct sched_param sp;

	memset(&sp, 0, sizeof sp);
	int pol = sched_getscheduler(tid);
	if (pol < 0 || sched_getparam(tid, &sp) != 0) {
		copy_str(r->status, sizeof r->status, "unknown");
		copy_str(r->policy, sizeof r->policy, "unknown");
		r->priority = 0;
		snprintf(r->reason, sizeof r->reason, "cannot read the data thread: %s", strerror(errno));
	} else {
		/* RTKit grants SCHED_RR | SCHED_RESET_ON_FORK */
		pol &= ~SCHED_RESET_ON_FORK;
		int rt = pol == SCHED_FIFO || pol == SCHED_RR;
		copy_str(r->status, sizeof r->status, rt ? "realtime" : "not-realtime");
		copy_str(r->policy, sizeof r->policy, policy_name(pol));
		r->priority = sp.sched_priority;
		r->reason[0] = 0;
		if (!rt && !h->rt_requested) {
			copy_str(r->reason, sizeof r->reason, "not requested");
		} else if (!rt) {
			struct rlimit rl;
			char lim[21]; /* up to 20 digits */
			if (getrlimit(RLIMIT_RTPRIO, &rl) != 0)
				copy_str(lim, sizeof lim, "?");
			else if (rl.rlim_cur == RLIM_INFINITY)
				copy_str(lim, sizeof lim, "unlimited");
			else
				snprintf(lim, sizeof lim, "%llu", (unsigned long long)rl.rlim_cur);
			snprintf(r->reason, sizeof r->reason, "RLIMIT_RTPRIO %s; RTKit/portal refused it", lim);
		}
	}
	r->known = 1;
	if (!r->logged) {
		r->logged = 1;
		if (r->reason[0])
			fprintf(stderr, "g16-mic: data thread scheduling: %s priority %d (%s: %s)\n", r->policy, r->priority,
				r->status, r->reason);
		else
			fprintf(stderr, "g16-mic: data thread scheduling: %s priority %d (%s)\n", r->policy, r->priority,
				r->status);
	}
}

static void *worker_main(void *arg)
{
	struct host *h = arg;
	struct telem rec, last;
	int have = 0, warned = 0;
	unsigned periods = 0;

	memset(&last, 0, sizeof last);
	while (!atomic_load(&h->worker_stop)) {
		while (g16mic_spsc_pop(&h->telem, &rec)) {
			last = rec;
			have = 1;
		}
		pid_t tid = (pid_t)atomic_load(&h->data_tid);
		if (tid > 0 && (!h->rt.known || periods % RT_CHECK_PERIODS == 0))
			check_rt(h, tid);
		periods++;
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
 * consumers). The result goes to the hand-off: a refusal (the output's
 * previous cycle is not finished, or it is not linked yet) is counted with
 * its errno, and the cycle waits in the output's queue for its next run. */
static void trigger_output(struct out_stream *o)
{
	if (atomic_load(&o->active) && o->stream)
		g16mic_handoff_note_trigger(o->h->hf, o->idx, pw_stream_trigger_process(o->stream));
}

static void capture_process(void *data)
{
	struct host *h = data;
	struct pw_buffer *b = pw_stream_dequeue_buffer(h->capture);

	if (!b)
		return;
	/* rt_busy covers the engine, the hand-off and the triggers:
	 * take_engine, destroy_output and the teardowns wait for it to drop
	 * before freeing or taking over what they use. */
	atomic_store(&h->rt_busy, 1);
	if (atomic_load(&h->cap_gate)) {
		/* the control thread is flushing the engine tail (it is the
		 * hand-off's producer meanwhile) or the capture is going away */
		pw_stream_queue_buffer(h->capture, b);
		atomic_store(&h->rt_busy, 0);
		return;
	}
	/* the data thread's tid, once, for the worker's real-time report (no
	 * syscall per cycle) */
	if (atomic_load_explicit(&h->data_tid, memory_order_relaxed) == 0)
		atomic_store(&h->data_tid, (int)gettid());

	struct live *L = atomic_load(&h->live);
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;
	struct pw_time t;
	int have_ticks = pw_stream_get_time_n(h->capture, &t, sizeof t) == 0;
	uint64_t ticks = have_ticks ? t.ticks : 0;

	const float *in = NULL;
	size_t frames = 0;
	int ch = L ? L->channels : 0;
	if (L && d && d->data && d->chunk) {
		uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)ch;
		uint32_t off = SPA_MIN(d->chunk->offset, d->maxsize);
		uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - off);
		in = SPA_PTROFF(d->data, off, const float);
		frames = size / stride;
	}
	/* Whether the hand-off accepted this cycle: it was not stopping before
	 * the call, and the call did not push the stop tail instead (the
	 * stopping state goes to 2 only in the call that pushes it). Kept for
	 * the stop log, read by the control thread only once stopping is 2. */
	int st0 = g16mic_handoff_stopping(h->hf);
	/* An output that became active since the last cycle starts at the
	 * cycle pushed next (relink), and its start window opens: for
	 * G16MIC_HF_START_CYCLES cycles the hand-off restarts it at the cycle
	 * just pushed if, right after the push, it still holds an older one
	 * (PipeWire ran it before this capture in earlier cycles; see the top
	 * of the file). */
	struct out_stream *outs[2] = { &h->processed, &h->raw };
	for (int i = 0; i < 2; i++) {
		int a = atomic_load(&outs[i]->active) && outs[i]->stream;
		if (a && !outs[i]->seen_active && st0 == G16MIC_HF_RUNNING)
			g16mic_handoff_relink(h->hf, outs[i]->idx);
		outs[i]->seen_active = a;
	}
	g16mic_handoff_capture(h->hf, L ? L->e : NULL, in, frames, ch, ticks, have_ticks);
	if (st0 == G16MIC_HF_RUNNING && L && frames > 0 && g16mic_handoff_stopping(h->hf) != G16MIC_HF_STOPPED) {
		struct spa_io_position *p = atomic_load_explicit(&h->cap_position, memory_order_relaxed);
		int have_pos = p && p->clock.rate.num != 0 && p->clock.rate.denom != 0;
		uint64_t gpos = have_pos ? (uint64_t)((double)p->clock.position * (double)G16MIC_RATE *
							      (double)p->clock.rate.num / (double)p->clock.rate.denom + 0.5)
					 : 0;
		atomic_store_explicit(&h->last_ticks, gpos, memory_order_relaxed);
		atomic_store_explicit(&h->last_frames, (uint64_t)frames, memory_order_relaxed);
		atomic_store_explicit(&h->last_valid, have_pos ? 1 : 2, memory_order_release);
	}

	if (L) {
		struct telem rec;
		g16mic_engine_get_stats(L->e, &rec.eng);
		rec.gen = L->gen;
		rec.source_state = atomic_load(&h->source_state);
		g16mic_spsc_push(&h->telem, &rec);
	}
	pw_stream_queue_buffer(h->capture, b);

	/* Run both outputs, every cycle, whatever the cycle carried and
	 * whether or not a stop is in progress: a cycle without an engine (a
	 * format change in progress) still triggers them, so a linked consumer
	 * runs its cycle (on zeros, counted as underflow), and during the stop
	 * drain these triggers deliver the queues and the tail quantum by
	 * quantum until g16mic_handoff_drained. */
	trigger_output(&h->processed);
	trigger_output(&h->raw);
	atomic_fetch_add_explicit(&h->cap_cycles, 1, memory_order_relaxed);
	atomic_store(&h->rt_busy, 0);
}

/* RT-safe: counts the driver cycles since this output's last run that did
 * not run it (graph_missed). Only between two runs on the same clock and
 * the same quantum, with no state change or activation in between, and only
 * up to G16MIC_HF_CAP_CYCLES cycles at once: a longer silence is the output
 * being idle (unlinked, paused), not a missed cycle. */
static void note_run_position(struct out_stream *o)
{
	struct spa_io_position *p = atomic_load_explicit(&o->position, memory_order_relaxed);

	if (atomic_exchange_explicit(&o->pos_reset, 0, memory_order_relaxed))
		o->have_last = 0;
	if (!p || p->clock.duration == 0 || p->clock.rate.num == 0 || p->clock.rate.denom == 0) {
		o->have_last = 0;
		return;
	}
	uint64_t pos = p->clock.position, dur = p->clock.duration;
	if (o->have_last && p->clock.id == o->last_clock && dur == o->last_dur && pos > o->last_pos + dur &&
	    (pos - o->last_pos) % dur == 0 && (pos - o->last_pos) / dur - 1 <= G16MIC_HF_CAP_CYCLES) {
		uint64_t frames = pos - o->last_pos - dur;
		frames = (uint64_t)((double)frames * (double)G16MIC_RATE * (double)p->clock.rate.num /
				    (double)p->clock.rate.denom + 0.5);
		atomic_fetch_add_explicit(&o->missed, frames, memory_order_relaxed);
	}
	o->last_pos = pos;
	o->last_dur = dur;
	o->last_clock = p->clock.id;
	o->have_last = 1;
}

/* An output's process callback: takes exactly one quantum from its queue,
 * the buffer's requested size (else the capture's last cycle size, which
 * g16mic_handoff_output uses for requested 0), and the chunk carries
 * exactly that, never more: PipeWire's adapter would keep the rest of a
 * larger buffer hidden (see the top of the file). Zeros it has to deliver
 * for want of audio are counted (underflow); at the end of a stream the
 * last quantum is zero-padded (eos_pad), and once stopped and empty it
 * delivers nothing. */
static void out_process(void *data)
{
	struct out_stream *o = data;
	struct host *h = o->h;

	atomic_store(&o->busy, 1);
	note_run_position(o);
	struct pw_buffer *b = pw_stream_dequeue_buffer(o->stream);
	if (!b) {
		atomic_store(&o->busy, 0);
		return;
	}
	struct spa_data *d = b->buffer->n_datas > 0 ? &b->buffer->datas[0] : NULL;
	if (!d || !d->data || !d->chunk) {
		pw_stream_queue_buffer(o->stream, b);
		atomic_store(&o->busy, 0);
		return;
	}
	size_t ch = (size_t)o->channels;
	uint32_t stride = (uint32_t)sizeof(float) * (uint32_t)ch;
	size_t maxframes = d->maxsize / stride;
	size_t frames = 0;
	/* A run that starts after its output was deactivated (a trigger
	 * signalled just before) leaves the hand-off alone: the control thread
	 * clears active, then waits for busy to drop, then owns the queue
	 * (g16mic_handoff_abandon). */
	if (atomic_load(&o->active))
		frames = g16mic_handoff_output(h->hf, o->idx, d->data, maxframes, (int)ch, (size_t)b->requested);
	if (frames > maxframes)
		frames = maxframes;

	d->chunk->offset = 0;
	d->chunk->stride = (int32_t)stride;
	d->chunk->size = (uint32_t)(frames * stride);
	pw_stream_queue_buffer(o->stream, b);
	atomic_store(&o->busy, 0);
}

/* ---- engine lifecycle (thread-loop thread) -------------------------------- */

static void wait_rt_idle(struct host *h)
{
	while (atomic_load(&h->rt_busy))
		sleep_us(50);
}

static void wait_outputs_idle(struct host *h)
{
	while (atomic_load(&h->processed.busy) || atomic_load(&h->raw.busy))
		sleep_us(50);
}

/* Takes the engine away from the capture callback and returns it (NULL if
 * none ran); no capture callback uses it once this returns. */
static struct live *take_engine(struct host *h)
{
	struct live *old = atomic_exchange(&h->live, NULL);

	if (old)
		wait_rt_idle(h);
	return old;
}

/* Folds a taken engine's counters into the totals and frees it. Its tail
 * is not lost here: the stop and source-loss paths have flushed it into the
 * hand-off before (g16mic_handoff_capture after begin_stop, or
 * g16mic_handoff_flush_tail), and the hand-off counts whatever of it could
 * not be delivered. Mode switches never retire the engine
 * (handle_mode_request asks the live engine to switch). */
static void free_engine(struct host *h, struct live *old)
{
	if (!old)
		return;
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

/* Makes the control thread the hand-off's producer: no capture callback
 * touches the hand-off once this returns, until ungate_capture. */
static void gate_capture(struct host *h)
{
	atomic_store(&h->cap_gate, 1);
	wait_rt_idle(h);
}

static void ungate_capture(struct host *h)
{
	atomic_store(&h->cap_gate, 0);
}

/* Thread-loop thread. An output's queue is filled only while a consumer
 * reads it (STREAMING); one that starts streaming starts at current audio
 * (the hand-off discards the backlog, counted as late_link_discarded).
 * Whether the capture triggers it is decided by activation
 * (activate_output), not by this state.
 *
 * An output we deactivated ourselves (the capture paused or is going away)
 * leaves STREAMING with its consumer still linked. Its queue stays counted
 * as consuming until the source-loss or stop path has pushed the engine
 * tail and accounted for it (g16mic_handoff_abandon), or until it is
 * activated again: otherwise a tail flushed after that state change would
 * go into no queue and be neither delivered nor counted. settle_consuming
 * applies the deferred change. */
static void out_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
	struct out_stream *o = data;

	(void)error;
	atomic_store(&o->pos_reset, 1);
	if (state == PW_STREAM_STATE_STREAMING) {
		o->unconsume_pending = 0;
		g16mic_handoff_set_consuming(o->h->hf, o->idx, 1);
		/* the start window: a consumer that links while we run starts at
		 * current audio at exactly the engine latency, whichever order
		 * PipeWire runs the output and the capture in its first cycles */
		g16mic_handoff_start_output(o->h->hf, o->idx);
	} else if (old == PW_STREAM_STATE_STREAMING) {
		if (atomic_load(&o->active))
			g16mic_handoff_set_consuming(o->h->hf, o->idx, 0);
		else
			o->unconsume_pending = 1;
	}
}

/* Thread-loop thread: applies a consuming change out_state_changed
 * deferred, once the tail has been accounted for or before reactivation. */
static void settle_consuming(struct out_stream *o)
{
	if (!o->unconsume_pending)
		return;
	o->unconsume_pending = 0;
	g16mic_handoff_set_consuming(o->h->hf, o->idx, 0);
}

/* Thread-loop thread. Once the format is set, asks for buffers that hold
 * ONE quantum of up to G16MIC_HF_MAX_FRAMES (8192, PipeWire's default quantum
 * limit) frames: out_process never writes more than one quantum, so a larger
 * buffer would only invite a multi-quantum write the adapter keeps hidden. */
static void out_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
	struct out_stream *o = data;
	uint8_t pod_buf[512];
	struct spa_pod_builder bld = SPA_POD_BUILDER_INIT(pod_buf, sizeof pod_buf);
	const struct spa_pod *params[1];

	if (!param || id != SPA_PARAM_Format || !o->stream)
		return;
	int stride = (int)sizeof(float) * o->channels;
	int want = G16MIC_HF_MAX_FRAMES * stride;
	params[0] = spa_pod_builder_add_object(&bld, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
		SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
		SPA_PARAM_BUFFERS_size, SPA_POD_CHOICE_RANGE_Int(want, want, INT32_MAX),
		SPA_PARAM_BUFFERS_stride, SPA_POD_Int(stride));
	if (params[0])
		pw_stream_update_params(o->stream, params, 1);
}

/* Keeps the output's spa_io_position (graph_missed). */
static void out_io_changed(void *data, uint32_t id, void *area, uint32_t size)
{
	struct out_stream *o = data;

	if (id != SPA_IO_Position)
		return;
	atomic_store(&o->pos_reset, 1);
	atomic_store(&o->position,
		     area && size >= sizeof(struct spa_io_position) ? (struct spa_io_position *)area : NULL);
}

static const struct pw_stream_events out_events = {
	PW_VERSION_STREAM_EVENTS,
	.io_changed = out_io_changed,
	.state_changed = out_state_changed,
	.param_changed = out_param_changed,
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
	settle_consuming(o);
	atomic_store(&o->pos_reset, 1);
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

static void deactivate_outputs(struct host *h)
{
	h->capture_streaming = 0;
	deactivate_output(&h->processed);
	deactivate_output(&h->raw);
}

/* Clears active first and waits out any capture callback in flight and its
 * own process callback, so nothing triggers or runs a stream that is being
 * destroyed. Its queue stops filling (not consuming); a raw output rebuilt
 * for a new channel count starts consuming again when it streams. */
static void destroy_output(struct out_stream *o)
{
	atomic_store(&o->active, 0);
	if (!o->stream)
		return;
	wait_rt_idle(o->h);
	while (atomic_load(&o->busy))
		sleep_us(50);
	o->unconsume_pending = 0;
	g16mic_handoff_set_consuming(o->h->hf, o->idx, 0);
	spa_hook_remove(&o->listener);
	pw_stream_destroy(o->stream);
	o->stream = NULL;
}

/* pos: the channel positions to offer (ch of them); NULL offers MONO for one
 * channel and AUX0.. otherwise. */
/* The capture and both outputs carry one node.group, so PipeWire schedules
 * them with one driver: the source's (the G16's ALSA source is its own
 * driver). The outputs are TRIGGER streams that the capture's process
 * callback runs (pw_stream_trigger_process) after it has queued this cycle's
 * audio for them, so in steady state they carry the capture's cycle in that
 * same cycle, and their consumers run after them. This is
 * module-filter-chain's pattern; the bounded queue (see the top of the file)
 * absorbs a refused or late output run. node.link-group marks the three as
 * one filter, so the session manager never links one of them into another. */
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
	o->idx = is_raw ? G16MIC_HF_RAW : G16MIC_HF_PROCESSED;
	atomic_store(&o->active, 0);
	atomic_store(&o->busy, 0);
	o->unconsume_pending = 0;
	o->seen_active = 0;
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
 * while no engine is live (the capture callback hands over empty cycles
 * meanwhile; a cycle queued at another width is zero-filled by the hand-off
 * and counted). A raw output (re)created while the capture streams is
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
	/* A renegotiation while an engine runs: the old engine's tail goes
	 * into the hand-off (never silently lost), and the new epoch below
	 * drops whatever of it is still queued, counted as stale_dropped,
	 * since it belongs to the old format. */
	struct live *old = take_engine(h);
	if (old) {
		gate_capture(h);
		if (g16mic_handoff_stopping(h->hf) != G16MIC_HF_STOPPED)
			g16mic_handoff_flush_tail(h->hf, old->e);
		if (!h->stop_requested)
			g16mic_handoff_reset_stop(h->hf);
		ungate_capture(h);
		free_engine(h, old);
	}
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

	/* a new stream: nothing queued from before may reach it */
	g16mic_handoff_new_epoch(h->hf);
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

/* Keeps the capture's spa_io_position, for the stop log's graph position. */
static void capture_io_changed(void *data, uint32_t id, void *area, uint32_t size)
{
	struct host *h = data;

	if (id == SPA_IO_Position)
		atomic_store(&h->cap_position,
			     area && size >= sizeof(struct spa_io_position) ? (struct spa_io_position *)area : NULL);
}

static const struct pw_stream_events capture_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = capture_state_changed,
	.io_changed = capture_io_changed,
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
	ungate_capture(h);
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

/* Runs on the stream's data loop (pw_loop_invoke from fallback_trigger):
 * one trigger of an output, the same call the capture callback makes. */
static int do_fallback_trigger(struct spa_loop *loop, bool async, uint32_t seq, const void *data, size_t size,
			       void *user_data)
{
	struct out_stream *o = user_data;

	(void)loop;
	(void)async;
	(void)seq;
	(void)data;
	(void)size;
	trigger_output(o);
	return 0;
}

/* Control thread (thread loop locked), while no capture callback triggers
 * the outputs: the source-loss tail window, or a stop drain whose capture
 * stopped delivering cycles. stream.h documents pw_stream_trigger_process
 * as "RT safe" but not as callable from any thread, so it is not called
 * from here: the trigger is invoked onto the output's own data loop
 * (pw_stream_get_data_loop, libpipewire >= 1.1, see meson.build) and runs
 * there, like the capture's. The invoke blocks until it ran (a few
 * microseconds on a data loop that never blocks), so no queued trigger can
 * outlive the stream. */
static void fallback_trigger(struct out_stream *o)
{
	if (!atomic_load(&o->active) || !o->stream)
		return;
	struct pw_loop *loop = pw_stream_get_data_loop(o->stream);
	if (loop)
		pw_loop_invoke(loop, do_fallback_trigger, 0, NULL, 0, true, o);
}

/* An output is done when the hand-off says it is drained (not consuming,
 * or stopped and empty and run once more after its last buffer, so that
 * buffer has passed through the graph), or when it is inactive: nothing can
 * trigger it any more, so nothing more can be delivered (what is left is
 * counted by g16mic_handoff_abandon). */
static int output_done(struct host *h, struct out_stream *o)
{
	return g16mic_handoff_drained(h->hf, o->idx) || !atomic_load(&o->active);
}

static int outputs_done(struct host *h)
{
	return output_done(h, &h->processed) && output_done(h, &h->raw);
}

/* One quantum period in microseconds: the capture's last cycle (1024 frames
 * if none was seen yet). The fallback triggers run at this pace, the
 * graph's own, one quantum a trigger. */
static long quantum_us(struct host *h)
{
	g16mic_hf_stats hs;

	g16mic_handoff_get_stats(h->hf, &hs);
	uint64_t cf = hs.last_cycle_frames ? hs.last_cycle_frames : 1024;
	return (long)(cf * 1000000ull / (uint64_t)G16MIC_RATE) + 1;
}

static void teardown_capture(struct host *h, enum teardown why)
{
	h->pending = TD_NONE;
	if (!h->capture)
		return;
	uint32_t src = h->capture_source_id;

	/* The source is gone (or refused). 1. No capture callback touches the
	 * hand-off from here on, and the engine is taken from it. 2. Its tail
	 * (the last engine-latency frames of accepted audio) goes into the
	 * queues. 3. The outputs, still active while their consumers are
	 * linked, are triggered from here (no capture can), one quantum per
	 * quantum period, for at most G16MIC_HF_TAIL_WINDOW_MS, until each is
	 * drained (g16mic_handoff_drained: its last buffer has passed through):
	 * this holds the thread loop no longer than that window. 4. Outputs
	 * inactive (a TRIGGER output left active with no capture to trigger it
	 * would stall its consumer's graph cycle, see activate_output), their
	 * callbacks waited out, and the tail and everything still queued is
	 * counted exactly as source_lost_tail per output. 5. The capture goes.
	 * The queues are empty afterwards: nothing of the old stream is left to
	 * reach a reconnected one (and the next engine's new epoch would drop
	 * it, counted, if it were). */
	gate_capture(h);
	struct live *old = take_engine(h);
	/* a stop already in progress may have pushed the tail (stopping 2):
	 * never twice */
	if (old && g16mic_handoff_stopping(h->hf) != G16MIC_HF_STOPPED)
		g16mic_handoff_flush_tail(h->hf, old->e);
	free_engine(h, old);

	/* only outputs still active can be triggered (a capture that paused
	 * or failed has deactivated them already) */
	long step = quantum_us(h);
	double end = now_s() + G16MIC_HF_TAIL_WINDOW_MS / 1000.0;
	while (!outputs_done(h) && now_s() < end) {
		fallback_trigger(&h->processed);
		fallback_trigger(&h->raw);
		if (outputs_done(h))
			break;
		double left = end - now_s();
		if (left <= 0)
			break;
		sleep_us(SPA_MIN(step, (long)(left * 1e6) + 1));
	}

	deactivate_outputs(h);
	wait_rt_idle(h);
	wait_outputs_idle(h);
	g16mic_handoff_abandon(h->hf, G16MIC_HF_LOST_SOURCE);
	settle_consuming(&h->processed);
	settle_consuming(&h->raw);
	/* during the stop drain the stop stays in force */
	if (!h->stop_requested)
		g16mic_handoff_reset_stop(h->hf);
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
	/* the stop drain runs: no new capture */
	if (h->stop_requested)
		return;
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
	if (h->hf)
		g16mic_handoff_destroy(h->hf);
	h->hf = NULL;
}

static int alloc_buffers(struct host *h)
{
	if (g16mic_spsc_init(&h->telem, sizeof(struct telem), TELEM_CAP) != 0)
		return -1;
	h->hf = g16mic_handoff_create(G16MIC_MAX_CH, G16MIC_HF_CAP_CYCLES, G16MIC_HF_MAX_FRAMES);
	return h->hf ? 0 : -1;
}

static void sum_drain_lost(const g16mic_hf_stats *hs, uint64_t *lost)
{
	*lost = hs->out[0].drain_lost + hs->out[1].drain_lost;
}

/* Stop drain, main thread, thread loop locked: the capture has not run a
 * cycle for two quantum periods, so nothing triggers the outputs. The first
 * time, the capture is gated for good (from then on it can neither push the
 * tail a second time nor trigger the outputs alongside these fallback
 * triggers) and the control thread, now the hand-off's producer, pushes the
 * stop tail if the capture had not. Then one fallback trigger per output.
 * Returns 1 (the capture is gated). */
static int drain_without_capture(struct host *h, int gated)
{
	if (!gated) {
		gate_capture(h);
		gated = 1;
		struct live *L = atomic_load(&h->live);
		if (L && g16mic_handoff_stopping(h->hf) != G16MIC_HF_STOPPED)
			g16mic_handoff_flush_tail(h->hf, L->e);
	}
	fallback_trigger(&h->processed);
	fallback_trigger(&h->raw);
	return gated;
}

/* The stop (SIGINT, SIGTERM, run_seconds): see the top of the file. Main
 * thread, thread loop unlocked on entry and on return. */
static void stop_and_drain(struct host *h)
{
	double t0 = now_s(), limit = G16MIC_HF_DRAIN_MS / 1000.0;
	int logged_last = 0;

	pw_thread_loop_lock(h->tl);
	h->stop_requested = 1;
	g16mic_handoff_begin_stop(h->hf);
	pw_thread_loop_unlock(h->tl);

	/* The capture, still running, pushes the engine tail in its next
	 * cycle (stopping becomes 2) and keeps triggering both outputs every
	 * cycle, which deliver the queues and the tail one quantum a run. Wait
	 * until both are drained (each has delivered its last buffer and run
	 * once more, so the last accepted cycle has passed through the graph),
	 * at most G16MIC_HF_DRAIN_MS, or until there is no capture left. If the
	 * capture stops delivering cycles meanwhile (none for two quantum
	 * periods: a stalled source), the control thread pushes the tail and
	 * triggers the outputs itself once per quantum period. */
	long step = quantum_us(h);
	uint64_t seen = atomic_load_explicit(&h->cap_cycles, memory_order_relaxed);
	double last_cycle = now_s(), last_fallback = 0;
	int gated = 0;
	for (;;) {
		int st = g16mic_handoff_stopping(h->hf);
		if (st == G16MIC_HF_STOPPED && !logged_last) {
			logged_last = 1;
			int v = atomic_load_explicit(&h->last_valid, memory_order_acquire);
			if (v == 1)
				fprintf(stderr, "g16-mic: stop: last accepted cycle at graph position %llu (%llu frames)\n",
					(unsigned long long)atomic_load(&h->last_ticks),
					(unsigned long long)atomic_load(&h->last_frames));
			else if (v == 2)
				fprintf(stderr, "g16-mic: stop: last accepted cycle at graph position unknown (%llu frames)\n",
					(unsigned long long)atomic_load(&h->last_frames));
		}
		pw_thread_loop_lock(h->tl);
		int done = st == G16MIC_HF_STOPPED && outputs_done(h);
		int gone = !h->capture || !h->capture_streaming;
		pw_thread_loop_unlock(h->tl);
		if (done || gone || atomic_load(&h->core_failed))
			break;
		double now = now_s();
		if (now - t0 >= limit)
			break;
		uint64_t c = atomic_load_explicit(&h->cap_cycles, memory_order_relaxed);
		if (c != seen) {
			seen = c;
			last_cycle = now;
		} else if ((now - last_cycle) * 1e6 >= 2.0 * (double)step && (now - last_fallback) * 1e6 >= (double)step) {
			/* no capture cycle for two quantum periods (one would trip on
			 * ordinary scheduling jitter): a stalled capture */
			pw_thread_loop_lock(h->tl);
			if (h->capture && h->capture_streaming)
				gated = drain_without_capture(h, gated);
			pw_thread_loop_unlock(h->tl);
			last_fallback = now_s();
		}
		sleep_us(DRAIN_STEP_US);
	}

	/* Then: outputs inactive (before the capture goes, see
	 * activate_output), the capture stopped (gated), every callback waited
	 * out, and what could not be delivered counted exactly as drain_lost.
	 * If the capture never pushed the tail (it was not streaming), the tail
	 * is flushed here so that it is counted too. */
	pw_thread_loop_lock(h->tl);
	deactivate_outputs(h);
	gate_capture(h);
	wait_outputs_idle(h);
	struct live *old = take_engine(h);
	if (old && g16mic_handoff_stopping(h->hf) != G16MIC_HF_STOPPED)
		g16mic_handoff_flush_tail(h->hf, old->e);
	g16mic_handoff_abandon(h->hf, G16MIC_HF_LOST_DRAIN);
	settle_consuming(&h->processed);
	settle_consuming(&h->raw);
	free_engine(h, old);
	destroy_capture_stream(h);
	pw_thread_loop_unlock(h->tl);

	g16mic_hf_stats hs;
	uint64_t lost;
	g16mic_handoff_get_stats(h->hf, &hs);
	sum_drain_lost(&hs, &lost);
	if (!logged_last && atomic_load(&h->last_valid) == 0)
		fputs("g16-mic: stop: no accepted cycle\n", stderr);
	/* eos_pad and graph_missed_raw_frames on this line too: the status file
	 * is removed at exit, and test_pw_live step 10 checks the end-of-stream
	 * zeros and the graph xruns against them */
	fprintf(stderr,
		"g16-mic: stop: drained in %.0f ms, tail %llu frames, drain_lost %llu, eos_pad %llu,"
		" graph_missed_raw_frames %llu\n",
		(now_s() - t0) * 1000.0, (unsigned long long)hs.tail_flushed_frames, (unsigned long long)lost,
		(unsigned long long)(hs.out[0].eos_pad + hs.out[1].eos_pad),
		(unsigned long long)atomic_load_explicit(&h->raw.missed, memory_order_relaxed));
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
	/* Real time: client.conf (the default config of pw_context_new) loads
	 * libpipewire-module-rt first in context.modules, under the condition
	 * module.rt = !false, i.e. unless the context property module.rt is
	 * "false". It is relied on rather than loaded again here: loaded
	 * first, it installs its thread utils before any data loop thread
	 * starts, so the data thread is created real-time (RLIMIT_RTPRIO, else
	 * RTKit, else the realtime portal; never root, never a
	 * sched_setscheduler of ours), whereas a pw_context_load_module after
	 * pw_context_new would come after every other module, and a data loop
	 * already started by one of them would stay non-real-time. Its load
	 * failures are ignored there (nofail), so what is reported is the
	 * outcome, observed: the worker reads the data thread's scheduling
	 * (check_rt), and rt_reason says why it is not real-time. module.rt is
	 * set to "true" to make the request explicit. */
	h->rt_requested = 1;
	h->context = pw_context_new(pw_thread_loop_get_loop(h->tl), pw_properties_new("module.rt", "true", NULL), 0);
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

	stop_and_drain(h);

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
