/* SPDX-License-Identifier: MIT */
/* test_status.c: the status file `g16-mic status` reads (status.c). No
 * PipeWire needed: formatting, the atomic write into a private temp dir, the
 * status dir lookup, pid parsing and the liveness check. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "g16mic.h"
#include "g16mic_host.h"
#include "test_util.h"

static const char *const keys[] = {
	"pid", "source", "source_state", "refuse_reason", "mode_requested", "mode_active",
	"spatial", "spatial_reason", "omni", "degraded", "confidence", "doa_az_deg",
	"steer_az_deg", "vad", "frames_in", "frames_out", "blocks", "fallbacks",
	"mode_switches", "refused_switches", "nonfinite_samples", "limiter_blocks",
	"telemetry_dropped", "ring_overflow", "ring_underflow", "reconnects", "wrong_links",
	"rt_requested", "rt_status", "rt_policy", "rt_priority", "rt_reason",
	"queue_capacity_cycles", "queue_bound_ms", "queue_max_depth_cycles",
	"queue_added_frames", "queue_added_ms", "queue_max_added_frames", "queue_max_added_ms",
	"latency_trimmed_frames", "latency_trimmed_cycles", "late_runs",
	"trigger_refused", "trigger_errno", "graph_missed_processed_frames", "graph_missed_raw_frames", "capture_gap", "stale_dropped", "late_link_discarded",
	"drain_lost", "source_lost_tail", "tail_flushed", "eos_pad",
};
#define NKEYS (sizeof keys / sizeof keys[0])

static void sample_status(g16mic_status *s)
{
	memset(s, 0, sizeof *s);
	s->pid = 4242;
	snprintf(s->source_name, sizeof s->source_name, "%s", "alsa_input.test-source");
	s->source_state = G16MIC_SRC_CONNECTED;
	s->eng.mode_requested = G16MIC_MODE_BEAM;
	s->eng.mode_active = G16MIC_MODE_OMNI;
	s->eng.spatial_available = 0;
	s->eng.spatial_reason = G16MIC_CAL_UNVERIFIED;
	s->eng.omni_calibrated = 0;
	s->eng.degraded = 1;
	s->eng.confidence = 0.25f;
	s->eng.frames_in = 96000;
	s->eng.frames_out = 96000;
	s->eng.blocks = 375;
	s->eng.fallbacks = 3;
	s->eng.refused_switches = 1;
	s->telemetry_dropped = 7;
	s->ring_overflow = 11;
	s->ring_underflow = 13;
	s->reconnects = 2;
	s->wrong_links = 1;
	s->rt_requested = 1;
	snprintf(s->rt_status, sizeof s->rt_status, "%s", "not-realtime");
	snprintf(s->rt_policy, sizeof s->rt_policy, "%s", "other");
	s->rt_priority = 0;
	s->rt_reason[0] = 0;
	s->queue_capacity_cycles = 8;
	s->queue_bound_ms = 170.6667;
	s->queue_max_depth_cycles = 3;
	s->queue_added_frames = 1024;
	s->queue_added_ms = 21.33;
	s->queue_max_added_frames = 2048;
	s->queue_max_added_ms = 42.66;
	s->latency_trimmed_frames = 3072;
	s->latency_trimmed_cycles = 1;
	s->late_runs = 17;
	s->trigger_refused = 19;
	s->trigger_errno = 11;
	s->graph_missed_processed_frames = 1024;
	s->graph_missed_raw_frames = 2048;
	s->capture_gap = 23;
	s->stale_dropped = 29;
	s->late_link_discarded = 31;
	s->drain_lost = 37;
	s->source_lost_tail = 41;
	s->tail_flushed = 272;
	s->eos_pad = 752;
}

/* Every field at its widest: the largest status the daemon can write. */
static void worst_status(g16mic_status *s)
{
	memset(s, 0, sizeof *s);
	s->pid = 2147483647L;
	memset(s->source_name, 'x', sizeof s->source_name - 1);
	memset(s->refuse_reason, 'x', sizeof s->refuse_reason - 1);
	memset(s->unavailable_reason, 'x', sizeof s->unavailable_reason - 1);
	memset(s->rt_status, 'x', sizeof s->rt_status - 1);
	memset(s->rt_policy, 'x', sizeof s->rt_policy - 1);
	memset(s->rt_reason, 'x', sizeof s->rt_reason - 1);
	s->eng.confidence = -1e30f;
	s->eng.doa_az_deg = -1e30f;
	s->eng.steer_az_deg = -1e30f;
	s->eng.frames_in = s->eng.frames_out = s->eng.blocks = UINT64_MAX;
	s->eng.fallbacks = s->eng.mode_switches = s->eng.refused_switches = UINT64_MAX;
	s->eng.nonfinite_samples = s->eng.limiter_blocks = UINT64_MAX;
	s->telemetry_dropped = s->ring_overflow = s->ring_underflow = UINT64_MAX;
	s->reconnects = s->wrong_links = UINT64_MAX;
	s->rt_requested = 1;
	s->rt_priority = -2147483647 - 1;
	s->trigger_errno = -2147483647 - 1;
	s->queue_bound_ms = -1e300;
	s->queue_added_ms = -1e300;
	s->queue_max_added_ms = -1e300;
	s->latency_trimmed_frames = s->latency_trimmed_cycles = UINT64_MAX;
	s->queue_capacity_cycles = s->queue_max_depth_cycles = UINT64_MAX;
	s->queue_added_frames = s->queue_max_added_frames = UINT64_MAX;
	s->late_runs = s->trigger_refused = s->capture_gap = s->stale_dropped = UINT64_MAX;
	s->graph_missed_processed_frames = s->graph_missed_raw_frames = UINT64_MAX;
	s->late_link_discarded = s->drain_lost = s->source_lost_tail = s->tail_flushed = UINT64_MAX;
	s->eos_pad = UINT64_MAX;
}

/* Value of `key` in the formatted text, copied into out; 0 if found. */
static int value_of(const char *text, const char *key, char *out, size_t len)
{
	size_t kl = strlen(key);

	for (const char *p = text; p && *p; ) {
		const char *nl = strchr(p, '\n');
		size_t ll = nl ? (size_t)(nl - p) : strlen(p);

		if (ll > kl && strncmp(p, key, kl) == 0 && p[kl] == '=') {
			size_t vl = ll - kl - 1;
			if (vl >= len)
				vl = len - 1;
			memcpy(out, p + kl + 1, vl);
			out[vl] = 0;
			return 0;
		}
		p = nl ? nl + 1 : NULL;
	}
	return -1;
}

static void test_format(void)
{
	g16mic_status s;
	char buf[4096], v[64];

	sample_status(&s);
	int n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "format failed");
	CHECK_EQ_INT((size_t)n, strlen(buf), "return value is the length");

	/* every key, one per line, in the documented order, nothing else */
	const char *p = buf;
	for (size_t i = 0; i < NKEYS; i++) {
		size_t kl = strlen(keys[i]);
		CHECK(strncmp(p, keys[i], kl) == 0 && p[kl] == '=', "line %zu is %s", i, keys[i]);
		const char *nl = strchr(p, '\n');
		CHECK(nl != NULL, "line %zu ends in a newline", i);
		if (!nl)
			break;
		p = nl + 1;
	}
	CHECK(*p == 0, "no lines after eos_pad: \"%s\"", p);

	CHECK(value_of(buf, "pid", v, sizeof v) == 0 && strcmp(v, "4242") == 0, "pid=%s", v);
	CHECK(value_of(buf, "source", v, sizeof v) == 0 && strcmp(v, "alsa_input.test-source") == 0, "source=%s", v);
	CHECK(value_of(buf, "source_state", v, sizeof v) == 0 && strcmp(v, "connected") == 0, "source_state=%s", v);
	CHECK(value_of(buf, "refuse_reason", v, sizeof v) == 0 && strcmp(v, "none") == 0, "refuse_reason=%s", v);
	CHECK(value_of(buf, "mode_requested", v, sizeof v) == 0 && strcmp(v, "beam") == 0, "mode_requested=%s", v);
	CHECK(value_of(buf, "mode_active", v, sizeof v) == 0 && strcmp(v, "omni") == 0, "mode_active=%s", v);
	CHECK(strstr(buf, "\nspatial=UNAVAILABLE\n") != NULL, "spatial=UNAVAILABLE when spatial_available=0");
	CHECK(strstr(buf, "\nspatial_reason=unverified\n") != NULL, "spatial_reason=unverified");
	CHECK(strstr(buf, "\nomni=uncalibrated\n") != NULL, "omni=uncalibrated");
	CHECK(strstr(buf, "\ndegraded=1\n") != NULL, "degraded=1 is visible");
	CHECK(strstr(buf, "\nfallbacks=3\n") != NULL, "fallbacks counted");
	CHECK(strstr(buf, "\nrefused_switches=1\n") != NULL, "refused switches counted");
	CHECK(strstr(buf, "\ntelemetry_dropped=7\n") != NULL, "telemetry drops counted");
	CHECK(strstr(buf, "\nring_overflow=11\n") != NULL, "ring overflow counted");
	CHECK(strstr(buf, "\nring_underflow=13\n") != NULL, "ring underflow counted");
	CHECK(strstr(buf, "\nreconnects=2\n") != NULL, "reconnects counted");
	CHECK(strstr(buf, "\nwrong_links=1\n") != NULL, "wrong links counted");
	CHECK(strstr(buf, "\nrt_requested=1\n") != NULL, "rt requested shown");
	CHECK(strstr(buf, "\nrt_status=not-realtime\n") != NULL, "rt status shown");
	CHECK(strstr(buf, "\nrt_policy=other\n") != NULL, "rt policy shown");
	CHECK(strstr(buf, "\nrt_priority=0\n") != NULL, "rt priority shown");
	CHECK(strstr(buf, "\nrt_reason=none\n") != NULL, "an empty rt reason reads none");
	CHECK(strstr(buf, "\nqueue_capacity_cycles=8\n") != NULL, "queue capacity shown");
	CHECK(strstr(buf, "\nqueue_target_cycles=") == NULL, "no catch-up target any more");
	CHECK(strstr(buf, "\nqueue_bound_ms=170.7\n") != NULL, "queue bound shown, one decimal");
	CHECK(strstr(buf, "\nqueue_max_depth_cycles=3\n") != NULL, "observed queue depth shown");
	CHECK(strstr(buf, "\nqueue_added_frames=1024\n") != NULL, "added latency now shown, frames");
	CHECK(strstr(buf, "\nqueue_max_added_frames=2048\n") != NULL, "observed max added latency shown, frames");
	CHECK(strstr(buf, "\nqueue_max_added_ms=42.7\n") != NULL, "observed added latency shown");
	CHECK(strstr(buf, "\nqueue_added_ms=21.3\n") != NULL, "added latency now shown, ms");
	CHECK(strstr(buf, "\nlatency_trimmed_frames=3072\n") != NULL, "latency trim counted, samples");
	CHECK(strstr(buf, "\nlatency_trimmed_cycles=1\n") != NULL, "latency trim counted, cycles");
	CHECK(value_of(buf, "latency_trimmed_frames", v, sizeof v) == 0 && strcmp(v, "3072") == 0,
	      "latency_trimmed_frames=%s", v);
	CHECK(strstr(buf, "\nlate_runs=17\n") != NULL, "late runs counted");
	CHECK(strstr(buf, "\ntrigger_refused=19\n") != NULL, "refused triggers counted");
	CHECK(strstr(buf, "\ntrigger_errno=11\n") != NULL, "trigger errno shown");
	CHECK(strstr(buf, "\ngraph_missed_processed_frames=1024\n") != NULL, "processed graph misses counted");
	CHECK(strstr(buf, "\ngraph_missed_raw_frames=2048\n") != NULL, "raw graph misses counted");
	CHECK(strstr(buf, "\ncapture_gap=23\n") != NULL, "capture gap counted");
	CHECK(strstr(buf, "\nstale_dropped=29\n") != NULL, "stale tail drops counted");
	CHECK(strstr(buf, "\nlate_link_discarded=31\n") != NULL, "late-link discards counted");
	CHECK(strstr(buf, "\ndrain_lost=37\n") != NULL, "drain losses counted");
	CHECK(strstr(buf, "\nsource_lost_tail=41\n") != NULL, "source-loss tail counted");
	CHECK(strstr(buf, "\ntail_flushed=272\n") != NULL, "flushed tail counted");
	CHECK(strstr(buf, "\neos_pad=752\n") != NULL, "end-of-stream padding counted");
	CHECK(value_of(buf, "queue_added_frames", v, sizeof v) == 0 && strcmp(v, "1024") == 0, "queue_added_frames=%s", v);
	CHECK(value_of(buf, "queue_max_added_frames", v, sizeof v) == 0 && strcmp(v, "2048") == 0,
	      "queue_max_added_frames=%s", v);
	CHECK(value_of(buf, "eos_pad", v, sizeof v) == 0 && strcmp(v, "752") == 0, "eos_pad=%s", v);

	/* the healthy case reads the other way round */
	s.eng.spatial_available = 1;
	s.eng.spatial_reason = G16MIC_CAL_OK;
	s.eng.omni_calibrated = 1;
	s.eng.degraded = 0;
	s.source_state = G16MIC_SRC_REFUSED;
	snprintf(s.refuse_reason, sizeof s.refuse_reason, "%s", "wrong-link");
	n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "format failed");
	CHECK(strstr(buf, "\nspatial=available\n") != NULL, "spatial=available");
	CHECK(strstr(buf, "\nspatial_reason=ok\n") != NULL, "spatial_reason=ok");
	CHECK(strstr(buf, "\nomni=calibrated\n") != NULL, "omni=calibrated");
	CHECK(strstr(buf, "\ndegraded=0\n") != NULL, "degraded=0");
	CHECK(strstr(buf, "\nsource_state=refused\n") != NULL, "source_state=refused");
	CHECK(strstr(buf, "\nrefuse_reason=wrong-link\n") != NULL, "refuse_reason=wrong-link");

	s.source_state = G16MIC_SRC_WAITING;
	n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0 && strstr(buf, "\nsource_state=waiting\n") != NULL, "source_state=waiting");

	/* real time obtained, and a reason when it is not */
	s.rt_requested = 0;
	snprintf(s.rt_status, sizeof s.rt_status, "%s", "realtime");
	snprintf(s.rt_policy, sizeof s.rt_policy, "%s", "fifo");
	s.rt_priority = 88;
	n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "format failed");
	CHECK(strstr(buf, "\nrt_requested=0\n") != NULL, "rt_requested=0");
	CHECK(strstr(buf, "\nrt_status=realtime\n") != NULL, "rt_status=realtime");
	CHECK(strstr(buf, "\nrt_policy=fifo\n") != NULL, "rt_policy=fifo");
	CHECK(strstr(buf, "\nrt_priority=88\n") != NULL, "rt_priority=88");
	s.rt_status[0] = 0;
	snprintf(s.rt_reason, sizeof s.rt_reason, "%s", "module-rt-unavailable");
	n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "format failed");
	CHECK(strstr(buf, "\nrt_status=none\n") != NULL, "an empty rt status reads none");
	CHECK(strstr(buf, "\nrt_reason=module-rt-unavailable\n") != NULL, "rt reason shown");

	/* a non-finite latency reads 0, never nan */
	s.queue_bound_ms = NAN;
	s.queue_added_ms = -INFINITY;
	s.queue_max_added_ms = INFINITY;
	n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "format failed");
	CHECK(strstr(buf, "\nqueue_added_ms=0.0\n") != NULL, "-inf added latency now reads 0.0");
	CHECK(strstr(buf, "\nqueue_bound_ms=0.0\n") != NULL, "nan bound reads 0.0");
	CHECK(strstr(buf, "\nqueue_max_added_ms=0.0\n") != NULL, "inf added latency reads 0.0");
}

/* main.c reads the status file into an 8 KiB buffer and status.c formats it
 * into 4 KiB: the widest possible status fits both. */
static void test_worst_case_size(void)
{
	g16mic_status s;
	char buf[8192];

	worst_status(&s);
	int n = g16mic_status_format(&s, buf, sizeof buf);
	CHECK(n > 0, "the widest status formats into 8192 bytes");
	CHECK(n > 0 && n < 4096, "the widest status (%d bytes) fits the 4096-byte write buffer", n);
	CHECK(strstr(buf, "\neos_pad=18446744073709551615\n") != NULL, "last key still written");
	CHECK(strstr(buf, "\nqueue_max_added_frames=18446744073709551615\n") != NULL, "widest added latency written");
	CHECK(strstr(buf, "\nlatency_trimmed_frames=18446744073709551615\n") != NULL, "widest trim count written");
}

static void test_truncation(void)
{
	g16mic_status s;
	char full[4096], small[64];

	sample_status(&s);
	int n = g16mic_status_format(&s, full, sizeof full);
	CHECK(n > 0, "format failed");
	CHECK_EQ_INT(g16mic_status_format(&s, small, sizeof small), -1, "too small a buffer is -1");
	CHECK(memchr(small, 0, sizeof small) != NULL, "truncated output is still NUL-terminated");
	/* room for everything up to wrong_links (the old status) but not the new keys */
	const char *cut = strstr(full, "\nrt_requested=");
	CHECK(cut != NULL, "rt_requested present");
	if (cut) {
		char mid[4096];
		size_t old_len = (size_t)(cut - full) + 1;
		CHECK_EQ_INT(g16mic_status_format(&s, mid, old_len + 1), -1,
		             "a buffer that only fits the keys up to wrong_links is -1");
		CHECK(memchr(mid, 0, old_len + 1) != NULL, "that truncation is NUL-terminated");
	}
	CHECK_EQ_INT(g16mic_status_format(&s, full, (size_t)n), -1, "no room for the NUL is -1");
	CHECK_EQ_INT(g16mic_status_format(&s, full, (size_t)n + 1), n, "exact fit works");
	CHECK_EQ_INT(g16mic_status_format(&s, NULL, 0), -1, "NULL buffer is -1");
	CHECK_EQ_INT(g16mic_status_format(NULL, full, sizeof full), -1, "NULL status is -1");
}

static int read_file(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");

	if (!f)
		return -1;
	size_t n = fread(buf, 1, len - 1, f);
	buf[n] = 0;
	fclose(f);
	return (int)n;
}

static void test_write_atomic(void)
{
	char base[] = "/tmp/g16mic-test-status-XXXXXX";
	char dir[256], status[300], tmp[300], text[4096];
	struct stat st;
	g16mic_status s;

	if (!mkdtemp(base)) {
		CHECK(0, "mkdtemp: %s", strerror(errno));
		return;
	}
	snprintf(dir, sizeof dir, "%s/run/g16-mic", base);
	snprintf(status, sizeof status, "%s/status", dir);
	snprintf(tmp, sizeof tmp, "%s/status.tmp", dir);

	sample_status(&s);
	CHECK_EQ_INT(g16mic_status_write_atomic(dir, &s), 0, "first write");
	CHECK(stat(dir, &st) == 0 && S_ISDIR(st.st_mode), "status dir created (with its parent)");
	CHECK_EQ_INT(st.st_mode & 0777, 0700, "status dir is 0700");
	CHECK(stat(status, &st) == 0 && S_ISREG(st.st_mode), "status file exists");
	CHECK_EQ_INT(st.st_mode & 0177, 0, "status file is 0600 or tighter");
	CHECK(access(tmp, F_OK) != 0, "no status.tmp left behind");
	CHECK(read_file(status, text, sizeof text) > 0, "status readable");
	CHECK(strstr(text, "pid=4242\n") == text, "file starts with pid=4242");
	CHECK(strstr(text, "\nreconnects=2\n") != NULL, "first content");
	CHECK(strstr(text, "\ntail_flushed=272\n") != NULL, "the new keys reach the file");
	CHECK(strstr(text, "\nqueue_added_frames=1024\n") != NULL, "added latency now reaches the file");
	CHECK(strstr(text, "\nqueue_max_added_frames=2048\n") != NULL, "max added latency reaches the file");
	CHECK(strstr(text, "\neos_pad=752\n") != NULL, "eos padding reaches the file");
	CHECK(strstr(text, "\nlatency_trimmed_frames=3072\n") != NULL, "the latency trim reaches the file");
	CHECK(strstr(text, "\nlatency_trimmed_cycles=1\n") != NULL, "the trim cycles reach the file");
	CHECK(strstr(text, "\nqueue_added_ms=21.3\n") != NULL, "added latency now (ms) reaches the file");

	long pid = 0;
	CHECK_EQ_INT(g16mic_status_read_pid(status, &pid), 0, "read_pid on the written file");
	CHECK_EQ_INT(pid, 4242, "pid round-trips");

	/* a re-write replaces the content */
	s.pid = 777;
	s.reconnects = 9;
	CHECK_EQ_INT(g16mic_status_write_atomic(dir, &s), 0, "second write");
	CHECK(read_file(status, text, sizeof text) > 0, "status readable");
	CHECK(strstr(text, "pid=777\n") == text, "re-write replaced pid");
	CHECK(strstr(text, "\nreconnects=9\n") != NULL, "re-write replaced counters");
	CHECK(strstr(text, "\nreconnects=2\n") == NULL, "old content gone");
	CHECK(access(tmp, F_OK) != 0, "no status.tmp after the re-write");

	/* a path that cannot be a directory fails cleanly */
	char blocker[300], below[320];
	snprintf(blocker, sizeof blocker, "%s/plainfile", base);
	int fd = open(blocker, O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
	CHECK(fd >= 0, "create blocker file");
	if (fd >= 0)
		close(fd);
	snprintf(below, sizeof below, "%s/sub", blocker);
	CHECK_EQ_INT(g16mic_status_write_atomic(below, &s), -1, "a file in the way is -1");
	CHECK_EQ_INT(g16mic_status_write_atomic(NULL, &s), -1, "NULL dir is -1");

	unlink(status);
	unlink(tmp);
	rmdir(dir);
	char run[300];
	snprintf(run, sizeof run, "%s/run", base);
	rmdir(run);
	unlink(blocker);
	CHECK(rmdir(base) == 0, "temp dir left clean: %s", strerror(errno));
}

static void test_status_dir(void)
{
	char buf[256];
	const char *saved = getenv("XDG_RUNTIME_DIR");
	char *copy = saved ? strdup(saved) : NULL;

	setenv("XDG_RUNTIME_DIR", "/run/user/12345", 1);
	CHECK_EQ_INT(g16mic_status_dir(buf, sizeof buf), 0, "set");
	CHECK(strcmp(buf, "/run/user/12345/g16-mic") == 0, "dir is %s", buf);
	CHECK_EQ_INT(g16mic_status_dir(buf, 8), -1, "too small a buffer");

	setenv("XDG_RUNTIME_DIR", "", 1);
	CHECK_EQ_INT(g16mic_status_dir(buf, sizeof buf), -1, "empty");
	setenv("XDG_RUNTIME_DIR", "relative/dir", 1);
	CHECK_EQ_INT(g16mic_status_dir(buf, sizeof buf), -1, "relative");
	unsetenv("XDG_RUNTIME_DIR");
	CHECK_EQ_INT(g16mic_status_dir(buf, sizeof buf), -1, "unset");

	if (copy) {
		setenv("XDG_RUNTIME_DIR", copy, 1);
		free(copy);
	}
}

static void test_read_pid(void)
{
	char base[] = "/tmp/g16mic-test-pid-XXXXXX";
	char path[300];
	long pid = 0;

	if (!mkdtemp(base)) {
		CHECK(0, "mkdtemp: %s", strerror(errno));
		return;
	}
	snprintf(path, sizeof path, "%s/status", base);

	FILE *f = fopen(path, "w");
	CHECK(f != NULL, "create");
	if (f) {
		fputs("source=x\npid=31337\nmode_active=omni\n", f);
		fclose(f);
	}
	CHECK_EQ_INT(g16mic_status_read_pid(path, &pid), 0, "pid= not on the first line");
	CHECK_EQ_INT(pid, 31337, "parsed");

	f = fopen(path, "w");
	if (f) {
		fputs("source=apid=5\nxpid=6\n", f);
		fclose(f);
	}
	pid = 0;
	CHECK_EQ_INT(g16mic_status_read_pid(path, &pid), -1, "only a whole pid= key counts");

	f = fopen(path, "w");
	if (f) {
		fputs("pid=12abc\n", f);
		fclose(f);
	}
	CHECK_EQ_INT(g16mic_status_read_pid(path, &pid), -1, "trailing junk is rejected");

	f = fopen(path, "w");
	if (f) {
		fputs("pid=0\n", f);
		fclose(f);
	}
	CHECK_EQ_INT(g16mic_status_read_pid(path, &pid), -1, "pid 0 is rejected");

	unlink(path);
	CHECK_EQ_INT(g16mic_status_read_pid(path, &pid), -1, "missing file");
	CHECK(rmdir(base) == 0, "temp dir left clean");
}

static void test_pid_alive(void)
{
	CHECK_EQ_INT(g16mic_pid_alive((long)getpid()), 1, "this process is alive");
	CHECK_EQ_INT(g16mic_pid_alive(0), 0, "pid 0 is never alive");
	CHECK_EQ_INT(g16mic_pid_alive(-1), 0, "negative pid is never alive");

	pid_t child = fork();
	if (child == 0)
		_exit(0);
	CHECK(child > 0, "fork");
	if (child > 0) {
		int wst;
		CHECK(waitpid(child, &wst, 0) == child, "reap");
		CHECK_EQ_INT(g16mic_pid_alive((long)child), 0, "a reaped child is gone");
	}
}

static void test_state_names(void)
{
	CHECK(strcmp(g16mic_src_state_name(G16MIC_SRC_WAITING), "waiting") == 0);
	CHECK(strcmp(g16mic_src_state_name(G16MIC_SRC_CONNECTED), "connected") == 0);
	CHECK(strcmp(g16mic_src_state_name(G16MIC_SRC_REFUSED), "refused") == 0);
}

int main(void)
{
	test_format();
	test_truncation();
	test_worst_case_size();
	test_write_atomic();
	test_status_dir();
	test_read_pid();
	test_pid_alive();
	test_state_names();
	G16T_RETURN();
}
