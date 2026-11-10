/* SPDX-License-Identifier: MIT */
/* g16mic_host.h: the status file (status.c, in libg16mic) and the PipeWire
 * host (host.c, in the g16-mic executable).
 *
 * The status file is <status dir>/status, where the status dir is
 * $XDG_RUNTIME_DIR/g16-mic: one key=value pair a line, always in the order
 * g16mic_status_format() writes them, rewritten atomically (write
 * status.tmp, rename) about four times a second while the daemon runs and
 * removed when it stops. `g16-mic set-mode` writes <status dir>/mode-request
 * and sends the daemon SIGUSR1.
 *
 * Nothing in this header needs the PipeWire headers.
 */
#ifndef G16MIC_HOST_H
#define G16MIC_HOST_H

#include <stddef.h>
#include <stdint.h>

#include "g16mic.h"

typedef enum { G16MIC_SRC_WAITING = 0, G16MIC_SRC_CONNECTED, G16MIC_SRC_REFUSED } g16mic_src_state;

typedef struct {
	g16mic_stats eng;              /* the engine's counters, summed over every engine of this run */
	g16mic_src_state source_state;
	char source_name[128];         /* the node.name the user named */
	char refuse_reason[32];        /* g16mic_match_result_name(), "wrong-link" or "stream-error"; "" when none */
	char unavailable_reason[32];   /* why a requested spatial mode fell back (g16mic_cal_status_name); "" when none */
	uint64_t telemetry_dropped;    /* status records the real-time thread could not queue */
	uint64_t ring_overflow;        /* every sample lost between capture and the output nodes: queue
	                                * bound exceeded, oversize cycles, width changes, a stale tail
	                                * dropped at reconnect, and the drain and source-loss tail losses */
	uint64_t ring_underflow;       /* samples the output nodes delivered as zeros for want of audio */
	uint64_t eos_pad;              /* zero samples that completed the last quantum at an end of stream (not a loss) */
	uint64_t reconnects;           /* times the named source went away while captured */
	uint64_t wrong_links;          /* times something other than the named source was linked into the capture */
	int rt_requested;              /* 1 if g16-mic asked PipeWire's module-rt for real-time scheduling */
	char rt_status[16];            /* "realtime", "not-realtime", "unknown" (no data cycle seen yet) */
	char rt_policy[16];            /* observed policy of the data thread: fifo, rr, other, batch, idle, unknown */
	int rt_priority;               /* observed sched_priority */
	char rt_reason[64];            /* why not real-time; "" when real-time */
	uint64_t queue_capacity_cycles;  /* per output: the hard bound on queue depth */
	double queue_bound_ms;         /* max added latency the queue allows */
	uint64_t queue_max_depth_cycles; /* observed */
	uint64_t queue_added_frames;   /* added latency now, frames (the larger output's) */
	double queue_added_ms;         /* the same in ms */
	uint64_t queue_max_added_frames; /* observed max added latency, frames */
	double queue_max_added_ms;     /* the same in ms */
	uint64_t latency_trimmed_frames; /* quiet samples the latency trim withheld to bring added latency back
	                                  * to the target, both outputs (frames x channels, like ring_overflow);
	                                  * not a loss, not in ring_overflow; never reset */
	uint64_t latency_trimmed_cycles; /* the trims: capture cycles withheld (each from both outputs) */
	uint64_t late_runs;            /* output runs that found more than one cycle queued */
	uint64_t trigger_refused;      /* output triggers PipeWire refused while a consumer was linked */
	int trigger_errno;             /* errno of the last refusal, 0 if none */
	uint64_t graph_missed_processed_frames; /* graph cycles the output's node missed (a graph xrun: */
	uint64_t graph_missed_raw_frames;       /* the data thread ran late), frames: consumers got
	                                         * PipeWire's silence for them, the audio stayed queued */
	uint64_t capture_gap;          /* input frames that never reached the capture (its graph clock jumped);
	                                * input never seen, not output loss */
	uint64_t stale_dropped;        /* samples of a previous source dropped at reconnect, never delivered */
	uint64_t late_link_discarded;  /* backlog discarded when a consumer linked late */
	uint64_t drain_lost;           /* samples not delivered by the stop drain timeout */
	uint64_t source_lost_tail;     /* tail samples not delivered after a source loss */
	uint64_t tail_flushed;         /* engine tail frames flushed into the outputs */
	long pid;
} g16mic_status;

const char *g16mic_src_state_name(g16mic_src_state s);  /* "waiting","connected","refused" */

/* Key=value lines, in this order: pid, source, source_state, refuse_reason,
 * mode_requested, mode_active, spatial (available|UNAVAILABLE),
 * spatial_reason, omni (calibrated|uncalibrated), degraded (0|1), confidence,
 * doa_az_deg, steer_az_deg, vad, frames_in, frames_out, blocks, fallbacks,
 * mode_switches, refused_switches, nonfinite_samples, limiter_blocks,
 * telemetry_dropped, ring_overflow, ring_underflow, reconnects, wrong_links,
 * rt_requested (0|1), rt_status, rt_policy, rt_priority, rt_reason,
 * queue_capacity_cycles, queue_bound_ms, queue_max_depth_cycles,
 * queue_added_frames, queue_added_ms, queue_max_added_frames,
 * queue_max_added_ms, latency_trimmed_frames, latency_trimmed_cycles, late_runs,
 * trigger_refused, trigger_errno, graph_missed_processed_frames,
 * graph_missed_raw_frames, capture_gap, stale_dropped,
 * late_link_discarded, drain_lost, source_lost_tail, tail_flushed, eos_pad.
 * An empty string value is written as "none". Returns the length written
 * (without the NUL), or -1 if buf is too small (buf then holds a truncated,
 * NUL-terminated prefix when len > 0). */
int g16mic_status_format(const g16mic_status *s, char *buf, size_t len);

/* Creates dir (and missing parents) with mode 0700, writes dir/status.tmp
 * (mode 0600) and renames it over dir/status. No fsync: the file lives on a
 * tmpfs and only describes the running process. 0 ok, -1 on failure. */
int g16mic_status_write_atomic(const char *dir, const g16mic_status *s);

/* $XDG_RUNTIME_DIR/g16-mic. -1 if XDG_RUNTIME_DIR is unset, empty, not
 * absolute, or the result does not fit. */
int g16mic_status_dir(char *buf, size_t len);

/* Reads the pid= line of a status file. 0 ok, -1 if absent or unreadable. */
int g16mic_status_read_pid(const char *path, long *pid);

/* 1 if a process with this pid exists (kill(pid, 0) == 0 or EPERM), else 0. */
int g16mic_pid_alive(long pid);

/* ---- host.c --------------------------------------------------------------- */

typedef struct {
	const char *source_name;  /* exact node.name of the microphone to capture */
	const char *calib_path;   /* may be NULL: spatial modes then report "missing" */
	g16mic_mode mode;
	float steer_az_deg;
	double run_seconds;       /* > 0: stop (with the graceful drain) after this long */
	const char *status_dir;   /* NULL: g16mic_status_dir() */
} g16mic_host_config;

/* Runs the daemon until SIGINT/SIGTERM or run_seconds, then drains (bounded)
 * before tearing down. Returns the process exit code: 0 after a clean stop,
 * 1 on a PipeWire or setup failure, 3 if another g16-mic is already running
 * with the same status dir. */
int g16mic_host_run(const g16mic_host_config *cfg);

#endif /* G16MIC_HOST_H */
