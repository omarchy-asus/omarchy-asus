/* SPDX-License-Identifier: MIT */
/* calib.c: calibration and geometry files, and the gate in front of the
 * spatial modes.
 *
 * File format (see calibration.example.conf for every key):
 *   key=value, one per line, at most 512 bytes a line; '#' starts a comment
 *   only at the start of a line; blank lines are ignored; whitespace around
 *   keys, values and list items is trimmed. Unknown and repeated keys are
 *   errors. Lists are comma separated with exactly `channels` items.
 *
 * Nothing here is real-time: it runs once when the daemon starts or reloads.
 */
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"

#define CAL_LINE_MAX 512
#define CAL_FILE_MAX (64 * 1024)
#define DUP_DIST_M 0.001
#define MIN_APERTURE_M 0.005

enum {
	K_FORMAT, K_CHANNELS, K_RATE, K_LAYOUT, K_KERNEL, K_MEASURED, K_MAXAGE,
	K_VERIFIED, K_MAP, K_GAIN, K_POLARITY, K_DELAY, K_HPF, K_DCBLOCK,
	K_MIC0, K_COUNT = K_MIC0 + G16MIC_MAX_CH
};

static const char *const key_names[K_MIC0] = {
	"format", "channels", "rate", "layout", "kernel", "measured", "max_age_days",
	"verified", "map", "gain_db", "polarity", "delay", "hpf_hz", "dc_block",
};

static const char *const status_names[] = {
	"ok", "missing", "parse", "nonfinite", "range", "channels", "zero-aperture",
	"duplicate-position", "unverified", "stale", "kernel", "layout",
};

const char *g16mic_cal_status_name(g16mic_cal_status s)
{
	if ((int)s < 0 || (size_t)s >= sizeof status_names / sizeof status_names[0])
		return "unknown";
	return status_names[s];
}

__attribute__((format(printf, 3, 4)))
static void seterr(char *err, size_t errlen, const char *fmt, ...)
{
	va_list ap;

	if (!err || errlen == 0)
		return;
	va_start(ap, fmt);
	vsnprintf(err, errlen, fmt, ap);
	va_end(ap);
}

void g16mic_calib_identity(g16mic_calib *c, int channels)
{
	if (!c)
		return;
	memset(c, 0, sizeof *c);
	if (channels < 0)
		channels = 0;
	if (channels > G16MIC_MAX_CH)
		channels = G16MIC_MAX_CH;
	c->channels = channels;
	for (int i = 0; i < G16MIC_MAX_CH; i++) {
		c->map[i] = i;
		c->gain_db[i] = 0.0f;
		c->polarity[i] = 1;
		c->delay_samples[i] = 0.0f;
	}
	c->have_pos = 0;
	c->hpf_hz = 80.0f;
	c->dc_block = 1;
	c->verified = 0;
	c->max_age_days = 365;
	c->rate = G16MIC_RATE;
}

static char *trim(char *s)
{
	while (isspace((unsigned char)*s))
		s++;
	char *e = s + strlen(s);
	while (e > s && isspace((unsigned char)e[-1]))
		*--e = '\0';
	return s;
}

static int key_index(const char *k)
{
	for (int i = 0; i < K_MIC0; i++)
		if (strcmp(k, key_names[i]) == 0)
			return i;
	if (strncmp(k, "mic.", 4) == 0 && k[4] >= '0' && k[4] < '0' + G16MIC_MAX_CH && k[5] == '\0')
		return K_MIC0 + (k[4] - '0');
	return -1;
}

static g16mic_cal_status parse_int(const char *tok, long lo, long hi, long *out)
{
	char *end;

	if (!*tok)
		return G16MIC_CAL_PARSE;
	errno = 0;
	long v = strtol(tok, &end, 10);
	if (end == tok || *end != '\0')
		return G16MIC_CAL_PARSE;
	if (errno == ERANGE || v < lo || v > hi)
		return G16MIC_CAL_RANGE;
	*out = v;
	return G16MIC_CAL_OK;
}

static g16mic_cal_status parse_float(const char *tok, float lo, float hi, float *out)
{
	char *end;

	if (!*tok)
		return G16MIC_CAL_PARSE;
	float v = strtof(tok, &end);
	if (end == tok || *end != '\0')
		return G16MIC_CAL_PARSE;
	if (!isfinite(v))
		return G16MIC_CAL_NONFINITE;
	if (v < lo || v > hi)
		return G16MIC_CAL_RANGE;
	*out = v;
	return G16MIC_CAL_OK;
}

/* Splits val in place at commas; stores up to max trimmed tokens and returns
 * how many there were. */
static int split_list(char *val, char **toks, int max)
{
	int count = 0;
	char *p = val;

	for (;;) {
		char *comma = strchr(p, ',');
		if (comma)
			*comma = '\0';
		if (count < max)
			toks[count] = trim(p);
		count++;
		if (!comma)
			break;
		p = comma + 1;
	}
	return count;
}

static g16mic_cal_status copy_string(char *dst, size_t dstlen, const char *v)
{
	size_t n = strlen(v);

	if (n >= dstlen)
		return G16MIC_CAL_PARSE;
	memcpy(dst, v, n + 1);
	return G16MIC_CAL_OK;
}

g16mic_cal_status g16mic_calib_parse(const char *text, g16mic_calib *out, char *err, size_t errlen)
{
	char vals[K_COUNT][CAL_LINE_MAX + 1];
	int seen[K_COUNT] = { 0 };
	g16mic_calib c;
	g16mic_cal_status st;
	long lv;
	char *toks[G16MIC_MAX_CH];
	int n;

	seterr(err, errlen, "%s", "");
	if (!out)
		return G16MIC_CAL_PARSE;
	memset(out, 0, sizeof *out);

#define FAIL(code, ...)                                                       \
	do {                                                                      \
		seterr(err, errlen, __VA_ARGS__);                                     \
		memset(out, 0, sizeof *out);                                          \
		return (code);                                                        \
	} while (0)

	if (!text)
		FAIL(G16MIC_CAL_PARSE, "no text");

	/* Pass 1: lines into the key table. */
	const char *p = text;
	int lineno = 0;
	while (*p) {
		const char *nl = strchr(p, '\n');
		size_t len = nl ? (size_t)(nl - p) : strlen(p);
		char line[CAL_LINE_MAX + 1];

		lineno++;
		if (len > CAL_LINE_MAX)
			FAIL(G16MIC_CAL_PARSE, "line %d: longer than %d bytes", lineno, CAL_LINE_MAX);
		memcpy(line, p, len);
		line[len] = '\0';
		p = nl ? nl + 1 : p + len;

		char *s = trim(line);
		if (*s == '\0' || *s == '#')
			continue;
		char *eq = strchr(s, '=');
		if (!eq)
			FAIL(G16MIC_CAL_PARSE, "line %d: expected key=value", lineno);
		*eq = '\0';
		char *k = trim(s);
		char *v = trim(eq + 1);
		int ki = key_index(k);
		if (ki < 0)
			FAIL(G16MIC_CAL_PARSE, "line %d: unknown key '%.64s'", lineno, k);
		if (seen[ki])
			FAIL(G16MIC_CAL_PARSE, "line %d: duplicate key '%.64s' (first on line %d)",
			     lineno, k, seen[ki]);
		seen[ki] = lineno;
		memcpy(vals[ki], v, strlen(v) + 1);
	}

	/* Pass 2: values. */
	if (!seen[K_FORMAT])
		FAIL(G16MIC_CAL_PARSE, "missing required key 'format'");
	if (strcmp(vals[K_FORMAT], "1") != 0)
		FAIL(G16MIC_CAL_PARSE, "format: only format=1 is supported");

	if (!seen[K_CHANNELS])
		FAIL(G16MIC_CAL_PARSE, "missing required key 'channels'");
	st = parse_int(vals[K_CHANNELS], 1, G16MIC_MAX_CH, &lv);
	if (st)
		FAIL(st, "channels: want an integer 1..%d", G16MIC_MAX_CH);
	g16mic_calib_identity(&c, (int)lv);

	if (seen[K_RATE]) {
		st = parse_int(vals[K_RATE], G16MIC_RATE, G16MIC_RATE, &lv);
		if (st)
			FAIL(st, "rate: only %d is supported", G16MIC_RATE);
		c.rate = (int)lv;
	}
	if (seen[K_LAYOUT] && copy_string(c.layout, sizeof c.layout, vals[K_LAYOUT]))
		FAIL(G16MIC_CAL_PARSE, "layout: longer than %zu bytes", sizeof c.layout - 1);
	if (seen[K_KERNEL] && copy_string(c.kernel, sizeof c.kernel, vals[K_KERNEL]))
		FAIL(G16MIC_CAL_PARSE, "kernel: longer than %zu bytes", sizeof c.kernel - 1);
	if (seen[K_MEASURED] && copy_string(c.measured, sizeof c.measured, vals[K_MEASURED]))
		FAIL(G16MIC_CAL_PARSE, "measured: want YYYY-MM-DD");
	if (seen[K_MAXAGE]) {
		st = parse_int(vals[K_MAXAGE], 1, 3650, &lv);
		if (st)
			FAIL(st, "max_age_days: want an integer 1..3650");
		c.max_age_days = (int)lv;
	}
	if (seen[K_VERIFIED]) {
		if (strcmp(vals[K_VERIFIED], "true") == 0)
			c.verified = 1;
		else if (strcmp(vals[K_VERIFIED], "false") == 0)
			c.verified = 0;
		else
			FAIL(G16MIC_CAL_PARSE, "verified: want true or false");
	}

	if (seen[K_MAP]) {
		n = split_list(vals[K_MAP], toks, G16MIC_MAX_CH);
		if (n != c.channels)
			FAIL(G16MIC_CAL_CHANNELS, "map: %d items for %d channels", n, c.channels);
		for (int i = 0; i < n; i++) {
			st = parse_int(toks[i], 0, G16MIC_MAX_CH - 1, &lv);
			if (st)
				FAIL(st, "map: item %d: want an integer 0..%d", i, G16MIC_MAX_CH - 1);
			for (int j = 0; j < i; j++)
				if (c.map[j] == (int)lv)
					FAIL(G16MIC_CAL_PARSE, "map: channel %ld used twice", lv);
			c.map[i] = (int)lv;
		}
	}
	if (seen[K_GAIN]) {
		n = split_list(vals[K_GAIN], toks, G16MIC_MAX_CH);
		if (n != c.channels)
			FAIL(G16MIC_CAL_CHANNELS, "gain_db: %d items for %d channels", n, c.channels);
		for (int i = 0; i < n; i++) {
			st = parse_float(toks[i], -40.0f, 40.0f, &c.gain_db[i]);
			if (st)
				FAIL(st, "gain_db: item %d: want a finite number -40..40", i);
		}
	}
	if (seen[K_POLARITY]) {
		n = split_list(vals[K_POLARITY], toks, G16MIC_MAX_CH);
		if (n != c.channels)
			FAIL(G16MIC_CAL_CHANNELS, "polarity: %d items for %d channels", n, c.channels);
		for (int i = 0; i < n; i++) {
			st = parse_int(toks[i], -1, 1, &lv);
			if (st == G16MIC_CAL_OK && lv == 0)
				st = G16MIC_CAL_RANGE;
			if (st)
				FAIL(st, "polarity: item %d: want 1 or -1", i);
			c.polarity[i] = (int)lv;
		}
	}
	if (seen[K_DELAY]) {
		n = split_list(vals[K_DELAY], toks, G16MIC_MAX_CH);
		if (n != c.channels)
			FAIL(G16MIC_CAL_CHANNELS, "delay: %d items for %d channels", n, c.channels);
		for (int i = 0; i < n; i++) {
			st = parse_float(toks[i], 0.0f, 32.0f, &c.delay_samples[i]);
			if (st)
				FAIL(st, "delay: item %d: want a finite number of samples 0..32", i);
		}
	}
	if (seen[K_HPF]) {
		st = parse_float(vals[K_HPF], 0.0f, 500.0f, &c.hpf_hz);
		if (st)
			FAIL(st, "hpf_hz: want a finite number 0..500 (0 is off)");
	}
	if (seen[K_DCBLOCK]) {
		st = parse_int(vals[K_DCBLOCK], 0, 1, &lv);
		if (st)
			FAIL(st, "dc_block: want 0 or 1");
		c.dc_block = (int)lv;
	}

	int present = 0;
	for (int i = 0; i < G16MIC_MAX_CH; i++) {
		if (!seen[K_MIC0 + i])
			continue;
		if (i >= c.channels)
			FAIL(G16MIC_CAL_PARSE, "mic.%d: only %d channels", i, c.channels);
		present++;
	}
	if (present > 0 && present < c.channels)
		FAIL(G16MIC_CAL_PARSE, "mic positions: %d of %d given; give every mic.N or none",
		     present, c.channels);
	if (present == c.channels) {
		for (int i = 0; i < c.channels; i++) {
			char *xyz[3];
			n = split_list(vals[K_MIC0 + i], xyz, 3);
			if (n != 3)
				FAIL(G16MIC_CAL_PARSE, "mic.%d: want x,y,z in metres", i);
			for (int a = 0; a < 3; a++) {
				st = parse_float(xyz[a], -1.0f, 1.0f, &c.pos[i][a]);
				if (st)
					FAIL(st, "mic.%d: coordinate %d: want a finite number of metres, |v| <= 1", i, a);
			}
		}
		c.have_pos = 1;
	}
#undef FAIL

	*out = c;
	return G16MIC_CAL_OK;
}

g16mic_cal_status g16mic_calib_load(const char *path, g16mic_calib *out, char *err, size_t errlen)
{
	FILE *f;
	char *buf;
	size_t n;

	seterr(err, errlen, "%s", "");
	if (out)
		memset(out, 0, sizeof *out);
	if (!path || !*path) {
		seterr(err, errlen, "no calibration path");
		return G16MIC_CAL_MISSING;
	}
	f = fopen(path, "re");
	if (!f) {
		seterr(err, errlen, "%s: %s", path, strerror(errno));
		return G16MIC_CAL_MISSING;
	}
	buf = malloc(CAL_FILE_MAX + 2);
	if (!buf) {
		fclose(f);
		seterr(err, errlen, "out of memory");
		return G16MIC_CAL_PARSE;
	}
	n = fread(buf, 1, CAL_FILE_MAX + 1, f);
	int bad = ferror(f);
	fclose(f);
	if (bad) {
		free(buf);
		seterr(err, errlen, "%s: read error", path);
		return G16MIC_CAL_MISSING;
	}
	if (n > CAL_FILE_MAX) {
		free(buf);
		seterr(err, errlen, "%s: larger than %d bytes", path, CAL_FILE_MAX);
		return G16MIC_CAL_PARSE;
	}
	if (memchr(buf, '\0', n)) {
		free(buf);
		seterr(err, errlen, "%s: contains a NUL byte", path);
		return G16MIC_CAL_PARSE;
	}
	buf[n] = '\0';
	g16mic_cal_status st = g16mic_calib_parse(buf, out, err, errlen);
	free(buf);
	return st;
}

/* "YYYY-MM-DD" (a real calendar date) to midnight UTC. */
static int parse_date(const char *s, time_t *out)
{
	if (strlen(s) != 10)
		return -1;
	for (int i = 0; i < 10; i++) {
		if (i == 4 || i == 7) {
			if (s[i] != '-')
				return -1;
		} else if (!isdigit((unsigned char)s[i])) {
			return -1;
		}
	}
	int y = (s[0] - '0') * 1000 + (s[1] - '0') * 100 + (s[2] - '0') * 10 + (s[3] - '0');
	int m = (s[5] - '0') * 10 + (s[6] - '0');
	int d = (s[8] - '0') * 10 + (s[9] - '0');
	if (y < 1970 || m < 1 || m > 12 || d < 1 || d > 31)
		return -1;
	struct tm tm;
	memset(&tm, 0, sizeof tm);
	tm.tm_year = y - 1900;
	tm.tm_mon = m - 1;
	tm.tm_mday = d;
	time_t t = timegm(&tm);
	if (t == (time_t)-1)
		return -1;
	struct tm back;
	if (!gmtime_r(&t, &back) || back.tm_year != y - 1900 || back.tm_mon != m - 1 || back.tm_mday != d)
		return -1;  /* 2026-02-30 and friends */
	*out = t;
	return 0;
}

g16mic_cal_status g16mic_calib_check_spatial(const g16mic_calib *c, const g16mic_cal_context *ctx, char *err, size_t errlen)
{
	seterr(err, errlen, "%s", "");
	if (!c) {
		seterr(err, errlen, "no calibration");
		return G16MIC_CAL_MISSING;
	}

	/* 1. Every float finite, even in a struct built by hand. */
	int nf = (c->channels >= 1 && c->channels <= G16MIC_MAX_CH) ? c->channels : G16MIC_MAX_CH;
	if (!isfinite(c->hpf_hz)) {
		seterr(err, errlen, "hpf_hz is not finite");
		return G16MIC_CAL_NONFINITE;
	}
	for (int i = 0; i < nf; i++) {
		if (!isfinite(c->gain_db[i]) || !isfinite(c->delay_samples[i]) ||
		    !isfinite(c->pos[i][0]) || !isfinite(c->pos[i][1]) || !isfinite(c->pos[i][2])) {
			seterr(err, errlen, "mic %d: gain, delay or position is not finite", i);
			return G16MIC_CAL_NONFINITE;
		}
	}

	/* 2. The file describes the stream being captured. */
	if (!ctx) {
		seterr(err, errlen, "no stream to check against");
		return G16MIC_CAL_CHANNELS;
	}
	if (c->channels < 1 || c->channels > G16MIC_MAX_CH || c->channels != ctx->stream_channels) {
		seterr(err, errlen, "calibration has %d channels, the stream has %d",
		       c->channels, ctx->stream_channels);
		return G16MIC_CAL_CHANNELS;
	}
	for (int i = 0; i < c->channels; i++) {
		if (c->map[i] < 0 || c->map[i] >= ctx->stream_channels) {
			seterr(err, errlen, "map: mic %d reads channel %d, the stream has %d",
			       i, c->map[i], ctx->stream_channels);
			return G16MIC_CAL_CHANNELS;
		}
	}

	/* 3. A real array: positions, distinct mics, an aperture. */
	if (!c->have_pos) {
		seterr(err, errlen, "no mic positions");
		return G16MIC_CAL_ZERO_APERTURE;
	}
	double maxd = 0.0;
	for (int i = 0; i < c->channels; i++) {
		for (int j = i + 1; j < c->channels; j++) {
			double dx = (double)c->pos[i][0] - c->pos[j][0];
			double dy = (double)c->pos[i][1] - c->pos[j][1];
			double dz = (double)c->pos[i][2] - c->pos[j][2];
			double d = sqrt(dx * dx + dy * dy + dz * dz);
			if (d < DUP_DIST_M) {
				seterr(err, errlen, "mic.%d and mic.%d are %.4f m apart (< 1 mm)", i, j, d);
				return G16MIC_CAL_DUP_POSITION;
			}
			if (d > maxd)
				maxd = d;
		}
	}
	if (maxd < MIN_APERTURE_M) {
		seterr(err, errlen, "aperture %.4f m is below 5 mm", maxd);
		return G16MIC_CAL_ZERO_APERTURE;
	}

	/* 4. Measured on this hardware, recently, on this kernel and layout. */
	if (!c->verified) {
		seterr(err, errlen, "calibration is not verified (verified=false)");
		return G16MIC_CAL_UNVERIFIED;
	}
	time_t now = ctx->now ? ctx->now : time(NULL);
	time_t when;
	if (!c->measured[0] || parse_date(c->measured, &when) != 0) {
		seterr(err, errlen, "measured date missing or not YYYY-MM-DD");
		return G16MIC_CAL_STALE;
	}
	if (when > now + 86400) {
		seterr(err, errlen, "measured date %s is in the future", c->measured);
		return G16MIC_CAL_STALE;
	}
	if (c->max_age_days <= 0 || (double)(now - when) > (double)c->max_age_days * 86400.0) {
		seterr(err, errlen, "measured %s is older than %d days", c->measured, c->max_age_days);
		return G16MIC_CAL_STALE;
	}

	/* kernel= is a release prefix that ends at a component boundary:
	 * "7.2" matches "7.2.8-9-omarchy" but not "7.20.1". */
	size_t kl = strlen(c->kernel);
	const char *kr = ctx->kernel_release;
	if (kl == 0 || !kr || strncmp(kr, c->kernel, kl) != 0 || isdigit((unsigned char)kr[kl])) {
		seterr(err, errlen, "calibration kernel '%s' does not match '%s'", c->kernel,
		       kr ? kr : "(unknown)");
		return G16MIC_CAL_KERNEL;
	}
	if (!c->layout[0] || !ctx->layout || strcmp(c->layout, ctx->layout) != 0) {
		seterr(err, errlen, "calibration layout '%s' does not match '%s'", c->layout,
		       ctx->layout ? ctx->layout : "(unknown)");
		return G16MIC_CAL_LAYOUT;
	}
	return G16MIC_CAL_OK;
}

int g16mic_calib_omni_usable(const g16mic_calib *c, int stream_channels)
{
	if (!c || !c->verified)
		return 0;
	if (c->channels < 1 || c->channels > G16MIC_MAX_CH || c->channels != stream_channels)
		return 0;
	for (int i = 0; i < c->channels; i++) {
		if (c->map[i] < 0 || c->map[i] >= stream_channels)
			return 0;
		if (c->polarity[i] != 1 && c->polarity[i] != -1)
			return 0;
		if (!isfinite(c->gain_db[i]) || c->gain_db[i] < -40.0f || c->gain_db[i] > 40.0f)
			return 0;
		if (!isfinite(c->delay_samples[i]) || c->delay_samples[i] < 0.0f ||
		    c->delay_samples[i] > 32.0f)
			return 0;
	}
	return 1;
}
