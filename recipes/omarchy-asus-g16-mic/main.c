/* SPDX-License-Identifier: MIT */
/* main.c: the g16-mic command line.
 *
 *   g16-mic run --source NODE_NAME [--calib FILE] [--mode raw|omni|beam|track]
 *               [--steer-az DEG] [--seconds N]
 *   g16-mic status
 *   g16-mic set-mode MODE
 *   g16-mic check-calib FILE [--source NODE] [--channels N]
 *   g16-mic --version | -h | --help
 *
 * Exit codes: 0 ok; 1 check-calib found the spatial modes unavailable, or the
 * daemon failed; 2 a refused source, an unavailable mode or a calibration
 * that does not parse; 3 not running (status, set-mode) or already running
 * (run); 64 usage errors.
 *
 * Nothing here starts on its own: the daemon runs only when a user runs
 * `g16-mic run`, and it never changes the default source.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#include "g16mic.h"
#include "g16mic_host.h"

#define G16MIC_VERSION "0.1.0"
#define EXIT_USAGE 64

static void usage(FILE *f)
{
	fputs("usage:\n"
	      "  g16-mic run --source NODE_NAME [--calib FILE] [--mode raw|omni|beam|track]\n"
	      "              [--steer-az DEG] [--seconds N]\n"
	      "  g16-mic status\n"
	      "  g16-mic set-mode raw|omni|beam|track\n"
	      "  g16-mic check-calib FILE [--source NODE_NAME] [--channels N]\n"
	      "  g16-mic --version\n"
	      "\n"
	      "run captures exactly the PipeWire source named by --source (its node.name)\n"
	      "and offers two virtual sources, g16_mic_processed (mono) and g16_mic_raw\n"
	      "(every channel, untouched). It never changes the default source.\n"
	      "The calibration defaults to $XDG_CONFIG_HOME/g16-mic/calibration.conf;\n"
	      "beam and track need a verified calibration for this exact source.\n",
	      f);
}

static int usage_error(const char *fmt, const char *arg)
{
	fputs("g16-mic: ", stderr);
	fprintf(stderr, fmt, arg ? arg : "");
	fputs("\n", stderr);
	usage(stderr);
	return EXIT_USAGE;
}

static int parse_float(const char *s, float lo, float hi, float *out)
{
	char *end;

	if (!s || !*s)
		return -1;
	errno = 0;
	double v = strtod(s, &end);
	if (errno || *end != 0 || !isfinite(v) || v < lo || v > hi)
		return -1;
	*out = (float)v;
	return 0;
}

static int parse_int(const char *s, int lo, int hi, int *out)
{
	char *end;

	if (!s || !*s)
		return -1;
	errno = 0;
	long v = strtol(s, &end, 10);
	if (errno || *end != 0 || v < lo || v > hi)
		return -1;
	*out = (int)v;
	return 0;
}

static const char *kernel_release(void)
{
	static struct utsname u;

	if (uname(&u) != 0)
		return "";
	return u.release;
}

static int default_calib_path(char *buf, size_t len)
{
	const char *xdg = getenv("XDG_CONFIG_HOME");
	const char *home = getenv("HOME");
	int n;

	if (xdg && xdg[0] == '/')
		n = snprintf(buf, len, "%s/g16-mic/calibration.conf", xdg);
	else if (home && home[0] == '/')
		n = snprintf(buf, len, "%s/.config/g16-mic/calibration.conf", home);
	else
		return -1;
	return (n < 0 || (size_t)n >= len) ? -1 : 0;
}

/* A refusal the matcher makes from the name alone (a monitor, our own
 * outputs, an empty name). With no nodes listed, a name it would accept comes
 * back ABSENT. */
static int source_name_refused(const char *name, g16mic_match_result *why)
{
	*why = g16mic_match_source(name, NULL, 0, NULL);
	return *why != G16MIC_MATCH_ABSENT;
}

/* Loads the calibration and checks the spatial modes against `channels`
 * (0: the file's own count) and the layout "<source>/<N>ch" (source NULL: the
 * file's own layout). */
static g16mic_cal_status check_calibration(const char *path, const char *source, int channels,
					   g16mic_calib *c, g16mic_cal_status *load, char *err, size_t errlen)
{
	char layout[192];

	err[0] = 0;
	if (!path) {
		g16mic_calib_identity(c, 0);
		snprintf(err, errlen, "no calibration file (set XDG_CONFIG_HOME or HOME, or pass --calib)");
		*load = G16MIC_CAL_MISSING;
		return G16MIC_CAL_MISSING;
	}
	*load = g16mic_calib_load(path, c, err, errlen);
	if (*load != G16MIC_CAL_OK)
		return *load;
	if (channels <= 0)
		channels = c->channels;
	if (source)
		snprintf(layout, sizeof layout, "%s/%dch", source, channels);
	else
		snprintf(layout, sizeof layout, "%s", c->layout);
	g16mic_cal_context ctx = {
		.stream_channels = channels,
		.layout = layout,
		.kernel_release = kernel_release(),
		.now = 0,
	};
	return g16mic_calib_check_spatial(c, &ctx, err, errlen);
}

static int cmd_run(int argc, char **argv)
{
	const char *source = NULL, *calib = NULL, *mode_s = NULL;
	float steer = 0.0f, seconds = 0.0f;
	char calib_buf[PATH_MAX];
	g16mic_mode mode = G16MIC_MODE_OMNI;

	for (int i = 0; i < argc; i++) {
		const char *a = argv[i];
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;

		if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
			usage(stdout);
			return 0;
		}
		if (!v)
			return usage_error("%s needs a value", a);
		if (strcmp(a, "--source") == 0)
			source = v;
		else if (strcmp(a, "--calib") == 0)
			calib = v;
		else if (strcmp(a, "--mode") == 0)
			mode_s = v;
		else if (strcmp(a, "--steer-az") == 0) {
			if (parse_float(v, -180.0f, 180.0f, &steer) != 0)
				return usage_error("--steer-az takes degrees from -180 to 180, not '%s'", v);
		} else if (strcmp(a, "--seconds") == 0) {
			if (parse_float(v, 0.0f, 1e7f, &seconds) != 0)
				return usage_error("--seconds takes a number of seconds, not '%s'", v);
		} else
			return usage_error("unknown option '%s'", a);
		i++;
	}
	if (!source)
		return usage_error("run needs --source NODE_NAME%s", NULL);
	if (mode_s && g16mic_mode_parse(mode_s, &mode) != 0)
		return usage_error("unknown mode '%s' (raw, omni, beam or track)", mode_s);

	g16mic_match_result why;
	if (source_name_refused(source, &why)) {
		fprintf(stderr, "g16-mic: refusing source '%s': %s (name a microphone's node.name, not a monitor or a g16-mic output)\n",
			source, g16mic_match_result_name(why));
		return 2;
	}

	if (!calib && default_calib_path(calib_buf, sizeof calib_buf) == 0)
		calib = calib_buf;

	if (g16mic_mode_is_spatial(mode)) {
		g16mic_calib c;
		g16mic_cal_status load;
		char err[256];
		g16mic_cal_status st = check_calibration(calib, source, 0, &c, &load, err, sizeof err);
		if (st != G16MIC_CAL_OK) {
			fprintf(stderr, "g16-mic: mode %s: UNAVAILABLE (%s: %s)\n",
				g16mic_mode_name(mode), g16mic_cal_status_name(st),
				err[0] ? err : (calib ? calib : "no calibration"));
			return 2;
		}
	}

	g16mic_host_config cfg = {
		.source_name = source,
		.calib_path = calib,
		.mode = mode,
		.steer_az_deg = steer,
		.run_seconds = seconds,
		.status_dir = NULL,
	};
	return g16mic_host_run(&cfg);
}

static int status_paths(char *dir, size_t dlen, char *status, size_t slen)
{
	if (g16mic_status_dir(dir, dlen) != 0) {
		fputs("g16-mic: XDG_RUNTIME_DIR is not set; no status to read\n", stderr);
		return -1;
	}
	if (snprintf(status, slen, "%s/status", dir) >= (int)slen)
		return -1;
	return 0;
}

/* 0 and *pid if a live daemon owns the status file; prints why not and
 * returns 3 otherwise. */
static int running_pid(const char *status, long *pid)
{
	if (access(status, F_OK) != 0) {
		fputs("g16-mic: not running\n", stderr);
		return 3;
	}
	if (g16mic_status_read_pid(status, pid) != 0) {
		fputs("g16-mic: not running (unreadable status file)\n", stderr);
		return 3;
	}
	if (!g16mic_pid_alive(*pid)) {
		fprintf(stderr, "g16-mic: not running (stale status from pid %ld)\n", *pid);
		return 3;
	}
	return 0;
}

static int cmd_status(int argc, char **argv)
{
	char dir[PATH_MAX], status[PATH_MAX + 16], text[8192];
	long pid;

	if (argc > 0 && (strcmp(argv[0], "-h") == 0 || strcmp(argv[0], "--help") == 0)) {
		usage(stdout);
		return 0;
	}
	if (argc > 0)
		return usage_error("status takes no arguments (got '%s')", argv[0]);
	if (status_paths(dir, sizeof dir, status, sizeof status) != 0)
		return 3;
	int rc = running_pid(status, &pid);
	if (rc != 0)
		return rc;
	FILE *f = fopen(status, "re");
	if (!f) {
		fputs("g16-mic: not running\n", stderr);
		return 3;
	}
	size_t n = fread(text, 1, sizeof text - 1, f);
	fclose(f);
	text[n] = 0;
	fputs(text, stdout);
	return 0;
}

static int cmd_set_mode(int argc, char **argv)
{
	char dir[PATH_MAX], status[PATH_MAX + 16], req[PATH_MAX + 16], tmp[PATH_MAX + 24];
	g16mic_mode mode;
	long pid;

	if (argc == 1 && (strcmp(argv[0], "-h") == 0 || strcmp(argv[0], "--help") == 0)) {
		usage(stdout);
		return 0;
	}
	if (argc != 1)
		return usage_error("set-mode takes one mode (raw, omni, beam or track)%s", NULL);
	if (g16mic_mode_parse(argv[0], &mode) != 0)
		return usage_error("unknown mode '%s' (raw, omni, beam or track)", argv[0]);
	if (status_paths(dir, sizeof dir, status, sizeof status) != 0)
		return 3;
	int rc = running_pid(status, &pid);
	if (rc != 0)
		return rc;

	snprintf(req, sizeof req, "%s/mode-request", dir);
	snprintf(tmp, sizeof tmp, "%s/mode-request.tmp", dir);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (fd < 0) {
		fprintf(stderr, "g16-mic: cannot write %s: %s\n", tmp, strerror(errno));
		return 1;
	}
	char word[16];
	int len = snprintf(word, sizeof word, "%s\n", g16mic_mode_name(mode));
	ssize_t w = write(fd, word, (size_t)len);
	if (close(fd) != 0 || w != len || rename(tmp, req) != 0) {
		fprintf(stderr, "g16-mic: cannot write %s: %s\n", req, strerror(errno));
		unlink(tmp);
		return 1;
	}
	if (kill((pid_t)pid, SIGUSR1) != 0) {
		fprintf(stderr, "g16-mic: cannot signal pid %ld: %s\n", pid, strerror(errno));
		return 3;
	}
	printf("g16-mic: asked pid %ld for mode %s; `g16-mic status` shows whether it was taken (refused_switches counts refusals)\n",
	       pid, g16mic_mode_name(mode));
	return 0;
}

static int cmd_check_calib(int argc, char **argv)
{
	const char *file = NULL, *source = NULL;
	int channels = 0;

	for (int i = 0; i < argc; i++) {
		const char *a = argv[i];

		if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
			usage(stdout);
			return 0;
		}
		if (strcmp(a, "--source") == 0 || strcmp(a, "--channels") == 0) {
			if (i + 1 >= argc)
				return usage_error("%s needs a value", a);
			const char *v = argv[++i];
			if (strcmp(a, "--source") == 0)
				source = v;
			else if (parse_int(v, 1, G16MIC_MAX_CH, &channels) != 0)
				return usage_error("--channels takes 1 to 8, not '%s'", v);
			continue;
		}
		if (a[0] == '-')
			return usage_error("unknown option '%s'", a);
		if (file)
			return usage_error("check-calib takes one file (also got '%s')", a);
		file = a;
	}
	if (!file)
		return usage_error("check-calib needs a FILE%s", NULL);

	g16mic_calib c;
	g16mic_cal_status load;
	char err[256];
	g16mic_cal_status st = check_calibration(file, source, channels, &c, &load, err, sizeof err);
	if (load != G16MIC_CAL_OK) {
		fprintf(stderr, "g16-mic: %s: %s: %s\n", file, g16mic_cal_status_name(load), err[0] ? err : "cannot load");
		return 2;
	}
	int n = channels > 0 ? channels : c.channels;

	puts("raw: available");
	if (g16mic_calib_omni_usable(&c, n))
		puts("omni: calibrated");
	else if (!c.verified)
		puts("omni: uncalibrated (unverified)");
	else
		printf("omni: uncalibrated (channels: the map does not fit %d channels)\n", n);
	for (int m = 0; m < 2; m++) {
		const char *name = m == 0 ? "beam" : "track";
		if (st == G16MIC_CAL_OK)
			printf("%s: available\n", name);
		else
			printf("%s: UNAVAILABLE (%s: %s)\n", name, g16mic_cal_status_name(st), err[0] ? err : "-");
	}
	return st == G16MIC_CAL_OK ? 0 : 1;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage(stderr);
		return EXIT_USAGE;
	}
	const char *cmd = argv[1];
	if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "help") == 0) {
		usage(stdout);
		return 0;
	}
	if (strcmp(cmd, "--version") == 0) {
		puts("g16-mic " G16MIC_VERSION);
		return 0;
	}
	if (strcmp(cmd, "run") == 0)
		return cmd_run(argc - 2, argv + 2);
	if (strcmp(cmd, "status") == 0)
		return cmd_status(argc - 2, argv + 2);
	if (strcmp(cmd, "set-mode") == 0)
		return cmd_set_mode(argc - 2, argv + 2);
	if (strcmp(cmd, "check-calib") == 0)
		return cmd_check_calib(argc - 2, argv + 2);
	return usage_error("unknown command '%s'", cmd);
}
