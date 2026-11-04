/* SPDX-License-Identifier: MIT */
/* test_calib: calibration file parsing and the spatial-mode gate (calib.c).
 *
 * The spatial modes (fixed beam, tracking) may run only on a file that parses,
 * is finite, matches the captured stream's channel count, layout and kernel,
 * has a real aperture without duplicate mics, is marked verified and is not
 * stale. Everything else is refused with its own reason.
 */
#include <stdlib.h>
#include <time.h>

#include "g16mic.h"
#include "test_util.h"

#define LAYOUT2 "alsa_input.test-array/2ch"
#define LAYOUT3 "alsa_input.test-array/3ch"
#define KREL "7.2.8-9-omarchy"

static time_t now_s;

static void date_days_ago(int days, char out[11])
{
	time_t t = now_s - (time_t)days * 86400;
	struct tm tm;

	gmtime_r(&t, &tm);
	strftime(out, 11, "%Y-%m-%d", &tm);
}

/* One calibration file; NULL fields take the good default, "" leaves the
 * line out. */
struct spec {
	const char *channels, *map, *gain, *polarity, *delay;
	const char *verified, *measured, *kernel, *layout, *mics, *extra;
};

static char ten_days_ago[11];

static const char *build(char *buf, size_t len, const struct spec *s)
{
	char line[16][600];
	int n = 0;

#define LINE(key, val, dflt)                                                    \
	do {                                                                        \
		const char *v_ = (val) ? (val) : (dflt);                                \
		if (*v_)                                                                \
			snprintf(line[n++], sizeof line[0], "%s=%s\n", key, v_);            \
	} while (0)

	snprintf(line[n++], sizeof line[0], "# test file\nformat=1\n");
	LINE("channels", s->channels, "2");
	LINE("map", s->map, "0,1");
	LINE("gain_db", s->gain, "0,0.5");
	LINE("polarity", s->polarity, "1,-1");
	LINE("delay", s->delay, "0,1.25");
	LINE("verified", s->verified, "true");
	LINE("measured", s->measured, ten_days_ago);
	LINE("kernel", s->kernel, "7.2");
	LINE("layout", s->layout, LAYOUT2);
	snprintf(line[n++], sizeof line[0], "max_age_days=365\nhpf_hz=80\ndc_block=1\n");
	snprintf(line[n++], sizeof line[0], "%s",
		 s->mics ? s->mics : "mic.0 = -0.05, 0, 0\nmic.1 = 0.05, 0, 0\n");
	if (s->extra)
		snprintf(line[n++], sizeof line[0], "%s", s->extra);
#undef LINE
	buf[0] = '\0';
	for (int i = 0; i < n; i++)
		strncat(buf, line[i], len - strlen(buf) - 1);
	return buf;
}

static g16mic_cal_status parse_spec(const struct spec *s, g16mic_calib *c, char *err, size_t errlen)
{
	char text[8192];

	return g16mic_calib_parse(build(text, sizeof text, s), c, err, errlen);
}

static g16mic_cal_context ctx2(void)
{
	g16mic_cal_context ctx = { 2, LAYOUT2, KREL, now_s };
	return ctx;
}

/* Parses (must be OK) and returns the spatial check. */
static g16mic_cal_status spatial(const struct spec *s, const g16mic_cal_context *ctx, const char *what)
{
	g16mic_calib c;
	char err[256] = "";
	g16mic_cal_status st = parse_spec(s, &c, err, sizeof err);

	CHECK_EQ_INT(st, G16MIC_CAL_OK, "%s: parse failed: %s", what, err);
	if (st != G16MIC_CAL_OK)
		return st;
	st = g16mic_calib_check_spatial(&c, ctx, err, sizeof err);
	if (st != G16MIC_CAL_OK)
		CHECK(err[0] != '\0', "%s: a refusal explains itself", what);
	return st;
}

static void expect_parse(const struct spec *s, g16mic_cal_status want, const char *what, const char *in_err)
{
	g16mic_calib c;
	char err[256] = "";
	g16mic_cal_status st = parse_spec(s, &c, err, sizeof err);

	CHECK(st == want, "%s: got %s want %s (%s)", what, g16mic_cal_status_name(st),
	      g16mic_cal_status_name(want), err);
	if (want != G16MIC_CAL_OK) {
		CHECK(err[0] != '\0', "%s: error text set", what);
		CHECK_EQ_INT(c.channels, 0, "%s: failed parse leaves a zeroed struct", what);
		CHECK(!g16mic_calib_omni_usable(&c, 2), "%s: failed parse is not omni-usable", what);
	}
	if (in_err)
		CHECK(strstr(err, in_err) != NULL, "%s: error '%s' names '%s'", what, err, in_err);
}

static void expect_spatial(const struct spec *s, const g16mic_cal_context *ctx, g16mic_cal_status want, const char *what)
{
	g16mic_cal_status st = spatial(s, ctx, what);

	CHECK(st == want, "%s: got %s want %s", what, g16mic_cal_status_name(st),
	      g16mic_cal_status_name(want));
}

static void test_identity(void)
{
	g16mic_calib c;

	g16mic_calib_identity(&c, 4);
	CHECK_EQ_INT(c.channels, 4, "channels");
	for (int i = 0; i < 4; i++) {
		CHECK_EQ_INT(c.map[i], i, "map[%d]", i);
		CHECK_NEAR(c.gain_db[i], 0.0, 0.0, "gain[%d]", i);
		CHECK_EQ_INT(c.polarity[i], 1, "polarity[%d]", i);
		CHECK_NEAR(c.delay_samples[i], 0.0, 0.0, "delay[%d]", i);
	}
	CHECK_EQ_INT(c.have_pos, 0, "no positions");
	CHECK_NEAR(c.hpf_hz, 80.0, 0.0, "hpf");
	CHECK_EQ_INT(c.dc_block, 1, "dc block");
	CHECK_EQ_INT(c.verified, 0, "identity is never verified");
	CHECK_EQ_INT(c.max_age_days, 365, "max age");
	CHECK_EQ_INT(c.rate, 48000, "rate");
	CHECK(!g16mic_calib_omni_usable(&c, 4), "identity is not a calibration");
}

static void test_example(void)
{
	const char *path = getenv("G16MIC_EXAMPLE_CALIB");
	g16mic_calib c;
	char err[256] = "";

	CHECK(path != NULL, "G16MIC_EXAMPLE_CALIB is set by meson");
	if (!path)
		return;
	g16mic_cal_status st = g16mic_calib_load(path, &c, err, sizeof err);
	CHECK(st == G16MIC_CAL_OK, "example parses: %s (%s)", g16mic_cal_status_name(st), err);
	CHECK_EQ_INT(c.verified, 0, "example is unverified");
	CHECK_EQ_INT(c.channels, 2, "example has 2 channels");
	CHECK_EQ_INT(c.have_pos, 1, "example has illustrative positions");

	g16mic_cal_context ctx = { 2, "alsa_input.pci-0000_65_00.6.analog-stereo/2ch", KREL, now_s };
	st = g16mic_calib_check_spatial(&c, &ctx, err, sizeof err);
	CHECK(st == G16MIC_CAL_UNVERIFIED, "example spatial: got %s want unverified",
	      g16mic_cal_status_name(st));
	CHECK(!g16mic_calib_omni_usable(&c, 2), "omni does not use an unverified file");
}

static void test_good(void)
{
	struct spec s = { 0 };
	g16mic_cal_context ctx = ctx2();
	g16mic_calib c;
	char err[256] = "";

	CHECK_EQ_INT(parse_spec(&s, &c, err, sizeof err), G16MIC_CAL_OK, "good file parses: %s", err);
	CHECK_EQ_INT(c.channels, 2, "channels");
	CHECK_EQ_INT(c.verified, 1, "verified");
	CHECK_EQ_INT(c.have_pos, 1, "positions");
	CHECK_NEAR(c.pos[0][0], -0.05, 1e-6, "mic.0 x");
	CHECK_NEAR(c.pos[1][0], 0.05, 1e-6, "mic.1 x");
	CHECK_NEAR(c.gain_db[1], 0.5, 1e-6, "gain list");
	CHECK_EQ_INT(c.polarity[1], -1, "polarity list");
	CHECK_NEAR(c.delay_samples[1], 1.25, 1e-6, "delay list");
	CHECK(strcmp(c.layout, LAYOUT2) == 0, "layout");
	CHECK(strcmp(c.kernel, "7.2") == 0, "kernel");
	CHECK(strcmp(c.measured, ten_days_ago) == 0, "measured");
	CHECK_EQ_INT(g16mic_calib_check_spatial(&c, &ctx, err, sizeof err), G16MIC_CAL_OK,
		     "verified good file allows spatial modes: %s", err);
	CHECK(g16mic_calib_omni_usable(&c, 2), "omni uses a verified file");
	CHECK(!g16mic_calib_omni_usable(&c, 3), "omni refuses a channel-count mismatch");
	CHECK(!g16mic_calib_omni_usable(NULL, 2), "NULL is not usable");

	ctx.now = 0;  /* means time(NULL) */
	CHECK_EQ_INT(g16mic_calib_check_spatial(&c, &ctx, err, sizeof err), G16MIC_CAL_OK,
		     "now == 0 uses the clock: %s", err);
}

static void test_nonfinite(void)
{
	struct spec s;

	s = (struct spec){ .gain = "nan,0" };
	expect_parse(&s, G16MIC_CAL_NONFINITE, "nan gain", "gain_db");
	s = (struct spec){ .delay = "inf,0" };
	expect_parse(&s, G16MIC_CAL_NONFINITE, "inf delay", "delay");
	s = (struct spec){ .mics = "mic.0=1e999,0,0\nmic.1=0.05,0,0\n" };
	expect_parse(&s, G16MIC_CAL_NONFINITE, "1e999 position", "mic.0");
	s = (struct spec){ .gain = "-infinity,0" };
	expect_parse(&s, G16MIC_CAL_NONFINITE, "-infinity gain", NULL);
	s = (struct spec){ .extra = "hpf_hz_x=1\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "unknown key near a real one", "hpf_hz_x");

	/* check_spatial re-checks floats even if a caller built the struct by hand. */
	g16mic_calib c;
	g16mic_cal_context ctx = ctx2();
	struct spec good = { 0 };
	char err[256];
	CHECK_EQ_INT(parse_spec(&good, &c, err, sizeof err), G16MIC_CAL_OK, "good parses");
	c.pos[1][2] = NAN;
	CHECK_EQ_INT(g16mic_calib_check_spatial(&c, &ctx, err, sizeof err), G16MIC_CAL_NONFINITE,
		     "hand-made NaN position");
	CHECK_EQ_INT(parse_spec(&good, &c, err, sizeof err), G16MIC_CAL_OK, "good parses");
	c.gain_db[0] = INFINITY;
	CHECK_EQ_INT(g16mic_calib_check_spatial(&c, &ctx, err, sizeof err), G16MIC_CAL_NONFINITE,
		     "hand-made inf gain");
	CHECK(!g16mic_calib_omni_usable(&c, 2), "omni refuses a non-finite gain");
}

static void test_geometry(void)
{
	struct spec s;
	g16mic_cal_context ctx = ctx2();

	s = (struct spec){ .mics = "mic.0=0.01,0.02,0\nmic.1=0.01,0.02,0\n" };
	expect_spatial(&s, &ctx, G16MIC_CAL_DUP_POSITION, "all mics at the same point");

	s = (struct spec){ .mics = "mic.0=0,0,0\nmic.1=0.002,0,0\n" };
	expect_spatial(&s, &ctx, G16MIC_CAL_ZERO_APERTURE, "mics 2 mm apart");

	s = (struct spec){ .mics = "" };
	expect_spatial(&s, &ctx, G16MIC_CAL_ZERO_APERTURE, "no positions at all");

	g16mic_cal_context ctx3 = { 3, LAYOUT3, KREL, now_s };
	s = (struct spec){ .channels = "3", .map = "0,1,2", .gain = "0,0,0", .polarity = "1,1,1",
			   .delay = "0,0,0", .layout = LAYOUT3,
			   .mics = "mic.0=-0.05,0,0\nmic.1=0.05,0,0\nmic.2=-0.05,0,0\n" };
	expect_spatial(&s, &ctx3, G16MIC_CAL_DUP_POSITION, "3 mics, two at one point");

	s.mics = "mic.0=-0.05,0,0\nmic.1=0.05,0,0\nmic.2=0,0.03,0\n";
	expect_spatial(&s, &ctx3, G16MIC_CAL_OK, "3 distinct mics");

	s = (struct spec){ .mics = "mic.0=1.5,0,0\nmic.1=0,0,0\n" };
	expect_parse(&s, G16MIC_CAL_RANGE, "position beyond 1 m", "mic.0");
	s = (struct spec){ .mics = "mic.0=0,0\nmic.1=0.05,0,0\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "position with two coordinates", "mic.0");
	s = (struct spec){ .mics = "mic.0=0,0,0\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "partial mic positions", "mic");
	s = (struct spec){ .mics = "mic.0=0,0,0\nmic.1=0.05,0,0\nmic.2=0.1,0,0\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "position for a mic beyond channels", "mic.2");
}

static void test_channels(void)
{
	struct spec s = { 0 };
	g16mic_cal_context ctx = ctx2();

	ctx.stream_channels = 4;
	expect_spatial(&s, &ctx, G16MIC_CAL_CHANNELS, "channel count differs from the stream");

	ctx = ctx2();
	s = (struct spec){ .map = "0,3" };
	expect_spatial(&s, &ctx, G16MIC_CAL_CHANNELS, "map entry beyond the stream");

	s = (struct spec){ .map = "0" };
	expect_parse(&s, G16MIC_CAL_CHANNELS, "map shorter than channels", "map");
	s = (struct spec){ .gain = "0,0,0" };
	expect_parse(&s, G16MIC_CAL_CHANNELS, "gain list longer than channels", "gain_db");
	s = (struct spec){ .map = "1,1" };
	expect_parse(&s, G16MIC_CAL_PARSE, "duplicate map entry", "map");
	s = (struct spec){ .map = "0,9" };
	expect_parse(&s, G16MIC_CAL_RANGE, "map entry above 7", "map");
	s = (struct spec){ .channels = "9" };
	expect_parse(&s, G16MIC_CAL_RANGE, "channels above 8", "channels");
	s = (struct spec){ .channels = "two" };
	expect_parse(&s, G16MIC_CAL_PARSE, "channels not a number", "channels");
}

static void test_verified_and_age(void)
{
	struct spec s;
	g16mic_cal_context ctx = ctx2();
	char old[11], future[11];

	s = (struct spec){ .verified = "false" };
	expect_spatial(&s, &ctx, G16MIC_CAL_UNVERIFIED, "verified=false");
	s = (struct spec){ .verified = "" };
	expect_spatial(&s, &ctx, G16MIC_CAL_UNVERIFIED, "verified missing");
	s = (struct spec){ .verified = "yes" };
	expect_parse(&s, G16MIC_CAL_PARSE, "verified=yes", "verified");

	date_days_ago(400, old);
	s = (struct spec){ .measured = old };
	expect_spatial(&s, &ctx, G16MIC_CAL_STALE, "measured 400 days ago");

	date_days_ago(-5, future);
	s = (struct spec){ .measured = future };
	expect_spatial(&s, &ctx, G16MIC_CAL_STALE, "measured in the future");

	s = (struct spec){ .measured = "" };
	expect_spatial(&s, &ctx, G16MIC_CAL_STALE, "measured missing");

	s = (struct spec){ .measured = "2026-13-45" };
	expect_spatial(&s, &ctx, G16MIC_CAL_STALE, "measured not a date");

	s = (struct spec){ .measured = "2026-10-01T12" };
	expect_parse(&s, G16MIC_CAL_PARSE, "measured too long", "measured");
}

static void test_kernel_layout(void)
{
	struct spec s;
	g16mic_cal_context ctx = ctx2();

	s = (struct spec){ .kernel = "6.19" };
	expect_spatial(&s, &ctx, G16MIC_CAL_KERNEL, "kernel mismatch");
	s = (struct spec){ .kernel = "" };
	expect_spatial(&s, &ctx, G16MIC_CAL_KERNEL, "kernel missing");
	s = (struct spec){ .kernel = "7.2.8" };
	expect_spatial(&s, &ctx, G16MIC_CAL_OK, "longer kernel prefix");
	ctx.kernel_release = "7.20.1-1";
	s = (struct spec){ .kernel = "7.2" };
	expect_spatial(&s, &ctx, G16MIC_CAL_KERNEL, "7.2 does not match 7.20");

	ctx = ctx2();
	s = (struct spec){ .layout = "alsa_input.other/2ch" };
	expect_spatial(&s, &ctx, G16MIC_CAL_LAYOUT, "layout mismatch");
	s = (struct spec){ .layout = "" };
	expect_spatial(&s, &ctx, G16MIC_CAL_LAYOUT, "layout missing");
}

static void test_syntax(void)
{
	struct spec s;
	g16mic_calib c;
	char err[256];

	s = (struct spec){ .extra = "colour=blue\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "unknown key", "colour");
	s = (struct spec){ .extra = "channels=2\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "duplicate key", "channels");
	s = (struct spec){ .extra = "just some words\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "line without =", "line");
	s = (struct spec){ .extra = "rate=44100\n" };
	expect_parse(&s, G16MIC_CAL_RANGE, "rate other than 48000", "rate");
	s = (struct spec){ .gain = "50,0" };
	expect_parse(&s, G16MIC_CAL_RANGE, "gain above 40 dB", "gain_db");
	s = (struct spec){ .delay = "0,40" };
	expect_parse(&s, G16MIC_CAL_RANGE, "delay above 32 samples", "delay");
	s = (struct spec){ .polarity = "1,0" };
	expect_parse(&s, G16MIC_CAL_RANGE, "polarity 0", "polarity");
	s = (struct spec){ .gain = "0,1.5dB" };
	expect_parse(&s, G16MIC_CAL_PARSE, "trailing junk in a number", "gain_db");
	s = (struct spec){ .gain = "0," };
	expect_parse(&s, G16MIC_CAL_PARSE, "empty list item", "gain_db");
	s = (struct spec){ .extra = "rate=48000\nmax_age_days=0\n" };
	expect_parse(&s, G16MIC_CAL_PARSE, "max_age_days twice", "max_age_days");

	CHECK_EQ_INT(g16mic_calib_parse("channels=2\n", &c, err, sizeof err), G16MIC_CAL_PARSE,
		     "format is required");
	CHECK_EQ_INT(g16mic_calib_parse("format=2\nchannels=2\n", &c, err, sizeof err),
		     G16MIC_CAL_PARSE, "unknown format");
	CHECK_EQ_INT(g16mic_calib_parse("format=1\n", &c, err, sizeof err), G16MIC_CAL_PARSE,
		     "channels is required");
	CHECK_EQ_INT(g16mic_calib_parse("format=1\r\nchannels=1\r\n", &c, err, sizeof err),
		     G16MIC_CAL_OK, "CRLF line endings: %s", err);
	CHECK_EQ_INT(g16mic_calib_parse(NULL, &c, err, sizeof err), G16MIC_CAL_PARSE, "NULL text");

	char longline[700];
	memset(longline, 0, sizeof longline);
	strcpy(longline, "format=1\nchannels=2\nlayout=");
	size_t at = strlen(longline);
	memset(longline + at, 'x', 600);
	longline[at + 600] = '\n';
	CHECK_EQ_INT(g16mic_calib_parse(longline, &c, err, sizeof err), G16MIC_CAL_PARSE,
		     "line over 512 bytes");

	/* A tiny err buffer is still NUL-terminated; NULL err is allowed. */
	char tiny[4];
	CHECK_EQ_INT(g16mic_calib_parse("format=1\ncolour=1\n", &c, tiny, sizeof tiny),
		     G16MIC_CAL_PARSE, "unknown key, small err");
	CHECK(strlen(tiny) < sizeof tiny, "err truncated safely");
	CHECK_EQ_INT(g16mic_calib_parse("format=1\ncolour=1\n", &c, NULL, 0), G16MIC_CAL_PARSE,
		     "unknown key, no err buffer");
}

static void test_load(void)
{
	g16mic_calib c;
	char err[256] = "";

	CHECK_EQ_INT(g16mic_calib_load("/nonexistent/g16-mic/calibration.conf", &c, err, sizeof err),
		     G16MIC_CAL_MISSING, "missing path");
	CHECK(err[0] != '\0', "missing path explained");
	CHECK(!g16mic_calib_omni_usable(&c, 2), "missing file is not omni-usable");
}

static void test_names(void)
{
	static const char *const want[] = { "ok", "missing", "parse", "nonfinite", "range",
		"channels", "zero-aperture", "duplicate-position", "unverified", "stale", "kernel",
		"layout" };

	for (int i = 0; i <= G16MIC_CAL_LAYOUT; i++)
		CHECK(strcmp(g16mic_cal_status_name((g16mic_cal_status)i), want[i]) == 0,
		      "status name %d", i);
	CHECK(g16mic_cal_status_name((g16mic_cal_status)99) != NULL, "out-of-range name");
}

int main(void)
{
	now_s = time(NULL);
	date_days_ago(10, ten_days_ago);

	test_identity();
	test_example();
	test_good();
	test_nonfinite();
	test_geometry();
	test_channels();
	test_verified_and_age();
	test_kernel_layout();
	test_syntax();
	test_load();
	test_names();
	G16T_RETURN();
}
