/* SPDX-License-Identifier: MIT */
/* status.c: the g16-mic status file. Pure functions plus plain file I/O, so
 * the CLI and the tests use them without PipeWire. The daemon calls them
 * only from its worker thread, never from a real-time callback. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "g16mic.h"
#include "g16mic_host.h"

#define STATUS_MAX 4096

const char *g16mic_src_state_name(g16mic_src_state s)
{
	switch (s) {
	case G16MIC_SRC_WAITING: return "waiting";
	case G16MIC_SRC_CONNECTED: return "connected";
	case G16MIC_SRC_REFUSED: return "refused";
	}
	return "unknown";
}

__attribute__((format(printf, 4, 5)))
static int put(char *buf, size_t len, size_t *off, const char *fmt, ...)
{
	va_list ap;
	int n;

	if (*off >= len)
		return -1;
	va_start(ap, fmt);
	n = vsnprintf(buf + *off, len - *off, fmt, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= len - *off) {
		*off = len;
		return -1;
	}
	*off += (size_t)n;
	return 0;
}

static const char *or_none(const char *s)
{
	return (s && *s) ? s : "none";
}

/* A non-finite float in the status would read as "nan"; write 0 instead. */
static double finite_or_zero(float x)
{
	return isfinite(x) ? (double)x : 0.0;
}

int g16mic_status_format(const g16mic_status *s, char *buf, size_t len)
{
	size_t off = 0;
	int bad = 0;

	if (!s || !buf || len == 0)
		return -1;
	buf[0] = 0;

	const g16mic_stats *e = &s->eng;
	bad |= put(buf, len, &off, "pid=%ld\n", s->pid);
	bad |= put(buf, len, &off, "source=%s\n", or_none(s->source_name));
	bad |= put(buf, len, &off, "source_state=%s\n", g16mic_src_state_name(s->source_state));
	bad |= put(buf, len, &off, "refuse_reason=%s\n", or_none(s->refuse_reason));
	bad |= put(buf, len, &off, "mode_requested=%s\n", g16mic_mode_name(e->mode_requested));
	bad |= put(buf, len, &off, "mode_active=%s\n", g16mic_mode_name(e->mode_active));
	bad |= put(buf, len, &off, "spatial=%s\n", e->spatial_available ? "available" : "UNAVAILABLE");
	bad |= put(buf, len, &off, "spatial_reason=%s\n", g16mic_cal_status_name(e->spatial_reason));
	bad |= put(buf, len, &off, "omni=%s\n", e->omni_calibrated ? "calibrated" : "uncalibrated");
	bad |= put(buf, len, &off, "degraded=%d\n", e->degraded ? 1 : 0);
	bad |= put(buf, len, &off, "confidence=%.3f\n", finite_or_zero(e->confidence));
	bad |= put(buf, len, &off, "doa_az_deg=%.1f\n", finite_or_zero(e->doa_az_deg));
	bad |= put(buf, len, &off, "steer_az_deg=%.1f\n", finite_or_zero(e->steer_az_deg));
	bad |= put(buf, len, &off, "vad=%d\n", e->vad_active ? 1 : 0);
	bad |= put(buf, len, &off, "frames_in=%llu\n", (unsigned long long)e->frames_in);
	bad |= put(buf, len, &off, "frames_out=%llu\n", (unsigned long long)e->frames_out);
	bad |= put(buf, len, &off, "blocks=%llu\n", (unsigned long long)e->blocks);
	bad |= put(buf, len, &off, "fallbacks=%llu\n", (unsigned long long)e->fallbacks);
	bad |= put(buf, len, &off, "mode_switches=%llu\n", (unsigned long long)e->mode_switches);
	bad |= put(buf, len, &off, "refused_switches=%llu\n", (unsigned long long)e->refused_switches);
	bad |= put(buf, len, &off, "nonfinite_samples=%llu\n", (unsigned long long)e->nonfinite_samples);
	bad |= put(buf, len, &off, "limiter_blocks=%llu\n", (unsigned long long)e->limiter_blocks);
	bad |= put(buf, len, &off, "telemetry_dropped=%llu\n", (unsigned long long)s->telemetry_dropped);
	bad |= put(buf, len, &off, "ring_overflow=%llu\n", (unsigned long long)s->ring_overflow);
	bad |= put(buf, len, &off, "ring_underflow=%llu\n", (unsigned long long)s->ring_underflow);
	bad |= put(buf, len, &off, "reconnects=%llu\n", (unsigned long long)s->reconnects);
	bad |= put(buf, len, &off, "wrong_links=%llu\n", (unsigned long long)s->wrong_links);
	if (bad)
		return -1;
	return off > INT_MAX ? -1 : (int)off;
}

/* mkdir -p; every directory this creates gets mode 0700. Existing
 * directories are left as they are. */
static int mkdir_p(const char *dir)
{
	char path[PATH_MAX];
	size_t n = strlen(dir);
	struct stat st;

	if (n == 0 || n >= sizeof path)
		return -1;
	memcpy(path, dir, n + 1);
	while (n > 1 && path[n - 1] == '/')
		path[--n] = 0;
	for (char *p = path + 1; ; p++) {
		if (*p != '/' && *p != 0)
			continue;
		char c = *p;
		*p = 0;
		if (mkdir(path, 0700) != 0) {
			if (errno != EEXIST)
				return -1;
			if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode))
				return -1;
		}
		*p = c;
		if (c == 0)
			break;
	}
	return 0;
}

int g16mic_status_write_atomic(const char *dir, const g16mic_status *s)
{
	char text[STATUS_MAX], tmp[PATH_MAX], final[PATH_MAX];
	int n, fd;

	if (!dir || !*dir || !s)
		return -1;
	n = g16mic_status_format(s, text, sizeof text);
	if (n < 0)
		return -1;
	if (snprintf(tmp, sizeof tmp, "%s/status.tmp", dir) >= (int)sizeof tmp ||
	    snprintf(final, sizeof final, "%s/status", dir) >= (int)sizeof final)
		return -1;
	if (mkdir_p(dir) != 0)
		return -1;

	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0)
		return -1;
	size_t done = 0;
	while (done < (size_t)n) {
		ssize_t w = write(fd, text + done, (size_t)n - done);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			close(fd);
			unlink(tmp);
			return -1;
		}
		done += (size_t)w;
	}
	if (close(fd) != 0 || rename(tmp, final) != 0) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

int g16mic_status_dir(char *buf, size_t len)
{
	const char *rt = getenv("XDG_RUNTIME_DIR");
	int n;

	if (!buf || len == 0 || !rt || rt[0] != '/')
		return -1;
	n = snprintf(buf, len, "%s/g16-mic", rt);
	if (n < 0 || (size_t)n >= len) {
		buf[0] = 0;
		return -1;
	}
	return 0;
}

int g16mic_status_read_pid(const char *path, long *pid)
{
	char text[STATUS_MAX];
	size_t n;
	FILE *f;

	if (!path || !pid)
		return -1;
	f = fopen(path, "re");
	if (!f)
		return -1;
	n = fread(text, 1, sizeof text - 1, f);
	fclose(f);
	text[n] = 0;

	for (char *line = text; line && *line; ) {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = 0;
		if (strncmp(line, "pid=", 4) == 0) {
			char *end;
			errno = 0;
			long v = strtol(line + 4, &end, 10);
			if (errno || end == line + 4 || *end != 0 || v <= 0)
				return -1;
			*pid = v;
			return 0;
		}
		line = nl ? nl + 1 : NULL;
	}
	return -1;
}

int g16mic_pid_alive(long pid)
{
	if (pid <= 0 || pid > INT_MAX)
		return 0;
	return kill((pid_t)pid, 0) == 0 || errno == EPERM;
}
