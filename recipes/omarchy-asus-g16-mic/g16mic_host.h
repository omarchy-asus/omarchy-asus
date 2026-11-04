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
	uint64_t ring_overflow;        /* samples dropped between capture and the output nodes */
	uint64_t ring_underflow;       /* samples the output nodes had to zero-fill */
	uint64_t reconnects;           /* times the named source went away while captured */
	uint64_t wrong_links;          /* times something other than the named source was linked into the capture */
	long pid;
} g16mic_status;

const char *g16mic_src_state_name(g16mic_src_state s);  /* "waiting","connected","refused" */

/* Key=value lines, in this order: pid, source, source_state, refuse_reason,
 * mode_requested, mode_active, spatial (available|UNAVAILABLE),
 * spatial_reason, omni (calibrated|uncalibrated), degraded (0|1), confidence,
 * doa_az_deg, steer_az_deg, vad, frames_in, frames_out, blocks, fallbacks,
 * mode_switches, refused_switches, nonfinite_samples, limiter_blocks,
 * telemetry_dropped, ring_overflow, ring_underflow, reconnects, wrong_links.
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
	double run_seconds;       /* > 0: stop (with the tail flush) after this long */
	const char *status_dir;   /* NULL: g16mic_status_dir() */
} g16mic_host_config;

/* Runs the daemon until SIGINT/SIGTERM or run_seconds. Returns the process
 * exit code: 0 after a clean stop, 1 on a PipeWire or setup failure, 3 if
 * another g16-mic is already running with the same status dir. */
int g16mic_host_run(const g16mic_host_config *cfg);

#endif /* G16MIC_HOST_H */
