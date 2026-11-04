/* SPDX-License-Identifier: MIT */
/* test_status.c: the status file `g16-mic status` reads (status.c). No
 * PipeWire needed: formatting, the atomic write into a private temp dir, the
 * status dir lookup, pid parsing and the liveness check. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
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
	CHECK(*p == 0, "no lines after wrong_links: \"%s\"", p);

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
	test_write_atomic();
	test_status_dir();
	test_read_pid();
	test_pid_alive();
	test_state_names();
	G16T_RETURN();
}
