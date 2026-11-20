/* SPDX-License-Identifier: MIT */
/* test_track.c: the direction tracker on its own: GCC-PHAT delay estimates,
 * direction of arrival on three geometries, confidence for one talker, two
 * talkers and diffuse noise, hysteresis, bounded slew, holding through pauses
 * and falling back when unsure. Synthetic signals only.
 *
 * Every scene starts with 200 ms of the -70 dBFS diffuse bed alone, so the
 * voice-activity detector has a noise floor to measure, as in a real room.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"
#include "test_util.h"
#include "test_signals.h"

#define RATE G16MIC_RATE
#define BLK G16MIC_BLOCK
#define BED_RMS 3.1623e-4f  /* -70 dBFS */
#define LEAD (RATE / 5)     /* 200 ms */

typedef struct {
	size_t nblocks;
	g16mic_track_out *out;
} track_log;

static float wrapd(float a)
{
	return (float)remainder((double)a, 360.0);
}

/* Runs the tracker over an interleaved scene; one output per block. */
static track_log run_tracker(const float pos[][3], int n, const float *scene, size_t frames, const g16mic_params *pp)
{
	g16mic_params p;
	track_log lg;
	float *chan[G16MIC_MAX_CH];
	const float *ptr[G16MIC_MAX_CH];

	if (pp)
		p = *pp;
	else
		g16mic_params_default(&p);
	g16mic_tracker *t = g16mic_tracker_create(pos, n, RATE, &p);
	CHECK(t != NULL, "tracker_create");
	if (!t)
		exit(1);
	lg.nblocks = frames / BLK;
	lg.out = g16s_xcalloc(lg.nblocks, sizeof *lg.out);
	for (int i = 0; i < n; i++) {
		chan[i] = g16s_xcalloc(frames, sizeof(float));
		g16s_deinterleave(scene, frames, n, i, chan[i]);
	}
	for (size_t b = 0; b < lg.nblocks; b++) {
		for (int i = 0; i < n; i++)
			ptr[i] = chan[i] + b * BLK;
		g16mic_tracker_update(t, ptr, &lg.out[b]);
	}
	for (int i = 0; i < n; i++)
		free(chan[i]);
	g16mic_tracker_destroy(t);
	return lg;
}

static int cmpf(const void *a, const void *b)
{
	float x = *(const float *)a, y = *(const float *)b;
	return (x > y) - (x < y);
}

static float median(float *v, size_t n)
{
	if (n == 0)
		return NAN;
	qsort(v, n, sizeof *v, cmpf);
	return v[n / 2];
}

/* Scene: bed everywhere plus src (placed from `at` on) rendered from az. */
static float *scene_one(const float pos[][3], int n, const float *src, size_t frames, float az, uint32_t seed)
{
	float *sc = g16s_xcalloc(frames * (size_t)n, sizeof(float));

	g16s_render_plane(src, frames, pos, n, az, 0.0f, RATE, sc, n);
	g16s_add_diffuse(sc, frames, n, RATE, seed, BED_RMS);
	return sc;
}

static float *talker(size_t frames, uint32_t seed, float lo, float hi, size_t start, size_t stop, int continuous)
{
	float *s = g16s_xcalloc(frames, sizeof(float));

	if (continuous)
		g16s_voiced(s, frames, RATE, seed, lo, hi);
	else
		g16s_speech_like(s, frames, RATE, seed, lo, hi);
	for (size_t i = 0; i < frames; i++)
		if (i < start || i >= stop)
			s[i] = 0.0f;
	return s;
}

static void test_gcc_phat_tdoa(void)
{
	static const double delays[] = { 1.3, -2.7 };
	const size_t frames = RATE;
	g16mic_params p;
	float *src = g16s_xcalloc(frames, sizeof(float)), *b = g16s_xcalloc(frames, sizeof(float));

	printf("test_gcc_phat_tdoa\n");
	g16mic_params_default(&p);
	g16mic_tracker *t = g16mic_tracker_create(G16S_GEOM_A, 2, RATE, &p);
	CHECK(t != NULL, "tracker");
	if (!t)
		exit(1);
	g16s_speech_like(src, frames, RATE, 3, 100.0f, 220.0f);
	/* the loudest 512-frame window, so it is voiced */
	size_t best = 0;
	double be = -1.0;
	for (size_t o = 1024; o + 2 * BLK + 1024 < frames; o += 64) {
		double e = g16s_energy(src + o, 2 * BLK);
		if (e > be) {
			be = e;
			best = o;
		}
	}
	for (size_t k = 0; k < 2; k++) {
		float pr = 0.0f;
		g16s_frac_delay(src, frames, delays[k], b);
		float d = g16mic_gcc_phat_tdoa(t, src + best, b + best, &pr);
		printf("  delay %+.2f: estimated %+.3f, peak ratio %.2f\n", delays[k], d, pr);
		CHECK_NEAR(d, delays[k], 0.25, "GCC-PHAT TDOA for a %g-sample delay", delays[k]);
		CHECK(pr > 1.0f, "a clear peak (ratio %g)", pr);
	}
	g16mic_tracker_destroy(t);
	free(src);
	free(b);
}

/* DOA from the confident voiced blocks after the first 500 ms. */
static void doa_case(const char *name, const float pos[][3], int n, float az, float tol, float *conf_med)
{
	const size_t frames = (size_t)(2.5 * RATE);
	float *s = talker(frames, 7, 100.0f, 220.0f, LEAD, frames, 0);
	float *sc = scene_one(pos, n, s, frames, az, 101);
	track_log lg = run_tracker(pos, n, sc, frames, NULL);
	float *doas = g16s_xcalloc(lg.nblocks, sizeof(float)), *confs = g16s_xcalloc(lg.nblocks, sizeof(float));
	size_t nd = 0, nc = 0;
	g16mic_params p;

	g16mic_params_default(&p);
	for (size_t b = (size_t)(0.5 * RATE) / BLK; b < lg.nblocks; b++) {
		if (!lg.out[b].vad)
			continue;
		confs[nc++] = lg.out[b].confidence;
		if (lg.out[b].confidence >= p.track_conf_enter)
			doas[nd++] = lg.out[b].doa_az_deg;
	}
	float m = median(doas, nd), c = median(confs, nc);
	printf("  %s, source %+g deg: DOA %+.2f deg (%zu blocks), confidence %.2f, steer %+.2f\n", name, az, m, nd, c,
	       lg.out[lg.nblocks - 1].steer_az_deg);
	CHECK(nd > lg.nblocks / 4, "%s: enough confident blocks (%zu)", name, nd);
	CHECK(fabsf(wrapd(m - az)) <= tol, "%s: DOA %g within %g deg of %g", name, m, tol, az);
	CHECK(lg.out[lg.nblocks - 1].locked, "%s: locked by the end", name);
	CHECK(fabsf(wrapd(lg.out[lg.nblocks - 1].steer_az_deg - az)) <= tol, "%s: steer near the talker", name);
	if (conf_med)
		*conf_med = c;
	free(doas);
	free(confs);
	free(lg.out);
	free(sc);
	free(s);
}

static void test_doa(void)
{
	static const float azs[] = { -40.0f, 0.0f, 35.0f };
	g16mic_params p;
	float c;

	printf("test_doa\n");
	g16mic_params_default(&p);
	for (int k = 0; k < 3; k++) {
		doa_case("array A", G16S_GEOM_A, 2, azs[k], 3.0f, &c);
		CHECK(c >= p.track_conf_enter, "one talker: confidence %g >= enter", c);
		doa_case("array B", G16S_GEOM_B, 4, azs[k], 3.0f, &c);
		CHECK(c >= p.track_conf_enter, "one talker: confidence %g >= enter", c);
		doa_case("planar C", G16S_GEOM_C, 4, azs[k], 5.0f, &c);
		CHECK(c >= p.track_conf_enter, "one talker: confidence %g >= enter", c);
	}
	/* The planar array tells front from back. */
	doa_case("planar C", G16S_GEOM_C, 4, 150.0f, 5.0f, NULL);
}

static float median_conf(const track_log *lg, size_t from)
{
	float *v = g16s_xcalloc(lg->nblocks, sizeof(float));
	size_t n = 0;

	for (size_t b = from; b < lg->nblocks; b++)
		v[n++] = lg->out[b].confidence;
	float m = median(v, n);
	free(v);
	return m;
}

static void test_confidence_low(void)
{
	const size_t frames = 2 * RATE;
	g16mic_params p;

	printf("test_confidence_low\n");
	g16mic_params_default(&p);
	for (int g = 0; g < 2; g++) {
		const float (*pos)[3] = g ? G16S_GEOM_B : G16S_GEOM_A;
		int n = g ? 4 : 2;
		/* two equal talkers, both voicing all the time */
		float *a = talker(frames, 31, 110.0f, 170.0f, LEAD, frames, 1);
		float *b = talker(frames, 32, 130.0f, 200.0f, LEAD, frames, 1);
		float *sc = scene_one(pos, n, a, frames, -50.0f, 201);
		g16s_render_plane_add(b, frames, pos, n, 50.0f, 0.0f, RATE, sc, n);
		track_log lg = run_tracker(pos, n, sc, frames, NULL);
		float m = median_conf(&lg, (size_t)(0.4 * RATE) / BLK);
		printf("  array %c, two talkers at -50/+50 deg: confidence %.2f\n", g ? 'B' : 'A', m);
		CHECK(m < p.track_conf_exit, "two equal talkers: confidence %g < exit", m);
		free(lg.out);
		free(sc);
		free(a);
		free(b);

		/* diffuse independent noise, loud enough to count as activity */
		sc = g16s_xcalloc(frames * (size_t)n, sizeof(float));
		g16s_add_diffuse(sc, frames, n, RATE, 301, BED_RMS);
		float *loud = g16s_xcalloc(frames * (size_t)n, sizeof(float));
		g16s_add_diffuse(loud, frames, n, RATE, 401, 0.05f);
		for (size_t i = (size_t)LEAD * n; i < frames * (size_t)n; i++)
			sc[i] += loud[i];
		lg = run_tracker(pos, n, sc, frames, NULL);
		m = median_conf(&lg, (size_t)(0.4 * RATE) / BLK);
		printf("  array %c, diffuse noise: confidence %.2f\n", g ? 'B' : 'A', m);
		CHECK(m < p.track_conf_exit, "diffuse noise: confidence %g < exit", m);
		free(lg.out);
		free(sc);
		free(loud);
	}
}

static void test_hysteresis(void)
{
	const size_t frames = 4 * RATE, seg = (size_t)(0.3 * RATE);
	float *s = talker(frames, 41, 100.0f, 220.0f, LEAD, frames, 0);
	float *s0 = g16s_xcalloc(frames, sizeof(float)), *s6 = g16s_xcalloc(frames, sizeof(float));

	printf("test_hysteresis\n");
	for (size_t i = 0; i < frames; i++)
		((i / seg) % 2 ? s6 : s0)[i] = s[i];
	float *sc = scene_one(G16S_GEOM_B, 4, s0, frames, 0.0f, 501);
	g16s_render_plane_add(s6, frames, G16S_GEOM_B, 4, 6.0f, 0.0f, RATE, sc, 4);
	track_log lg = run_tracker(G16S_GEOM_B, 4, sc, frames, NULL);
	size_t first = lg.nblocks;
	for (size_t b = 0; b < lg.nblocks; b++)
		if (lg.out[b].locked) {
			first = b;
			break;
		}
	CHECK(first < lg.nblocks, "locks onto the talker");
	if (first < lg.nblocks) {
		float s0v = lg.out[first].steer_az_deg;
		int moved = 0, lost = 0;
		for (size_t b = first; b < lg.nblocks; b++) {
			if (lg.out[b].steer_az_deg != s0v)
				moved++;
			if (!lg.out[b].locked || lg.out[b].fallback)
				lost++;
		}
		printf("  locked at %+.2f deg; blocks moved %d, blocks unlocked %d\n", s0v, moved, lost);
		CHECK(fabsf(s0v - 3.0f) <= 6.0f, "target between the two positions (%g)", s0v);
		CHECK_EQ_INT(moved, 0, "a talker moving 6 deg back and forth leaves the target unchanged");
		CHECK_EQ_INT(lost, 0, "stays locked");
	}
	free(lg.out);
	free(sc);
	free(s);
	free(s0);
	free(s6);
}

static void test_bounded_slew(void)
{
	const size_t frames = (size_t)(3.5 * RATE), jump = (size_t)(1.5 * RATE) / BLK * BLK;
	g16mic_params p;
	/* Continuous voicing here: steering is held during pauses by design, so
	 * the time to reach the new direction is measured on a talker who keeps
	 * talking. */
	float *s = talker(frames, 51, 100.0f, 220.0f, LEAD, frames, 1);
	float *a = g16s_xcalloc(frames, sizeof(float)), *b = g16s_xcalloc(frames, sizeof(float));

	printf("test_bounded_slew\n");
	g16mic_params_default(&p);
	for (size_t i = 0; i < frames; i++)
		(i < jump ? a : b)[i] = s[i];
	float *sc = scene_one(G16S_GEOM_B, 4, a, frames, 0.0f, 601);
	g16s_render_plane_add(b, frames, G16S_GEOM_B, 4, 60.0f, 0.0f, RATE, sc, 4);
	track_log lg = run_tracker(G16S_GEOM_B, 4, sc, frames, NULL);
	const double bound = p.track_max_slew_deg_s * BLK / RATE + 1e-3;
	double maxstep = 0.0;
	size_t jb = jump / BLK, reach = lg.nblocks;
	CHECK(lg.out[jb - 1].locked, "locked before the jump");
	CHECK(fabsf(lg.out[jb - 1].steer_az_deg) <= 3.0f, "steer near 0 before the jump (%g)", lg.out[jb - 1].steer_az_deg);
	for (size_t k = 1; k < lg.nblocks; k++) {
		if (lg.out[k].locked && lg.out[k - 1].locked && !lg.out[k].fallback && !lg.out[k - 1].fallback) {
			double d = fabs(wrapd(lg.out[k].steer_az_deg - lg.out[k - 1].steer_az_deg));
			if (d > maxstep)
				maxstep = d;
		}
		if (k >= jb && reach == lg.nblocks && lg.out[k].locked && fabsf(lg.out[k].steer_az_deg - 60.0f) <= 3.0f)
			reach = k;
	}
	double t = (double)(reach - jb) * BLK / RATE;
	printf("  largest step %.4f deg/block (bound %.4f); reached 60 deg after %.3f s\n", maxstep, bound, t);
	CHECK(maxstep <= bound, "steer changes by at most %g deg per block (%g)", bound, maxstep);
	CHECK(reach < lg.nblocks && t <= 1.0, "reaches 60 deg within 1.0 s (%g s)", t);
	free(lg.out);
	free(sc);
	free(s);
	free(a);
	free(b);
}

static void test_pause_held(void)
{
	const size_t frames = (size_t)(3.5 * RATE);
	const size_t p0 = (size_t)(1.7 * RATE), p1 = (size_t)(2.5 * RATE);
	float *s = talker(frames, 61, 100.0f, 220.0f, LEAD, frames, 0);

	printf("test_pause_held\n");
	for (size_t i = p0; i < p1; i++)
		s[i] = 0.0f;  /* 800 ms of the bed alone */
	float *sc = scene_one(G16S_GEOM_B, 4, s, frames, 30.0f, 701);
	track_log lg = run_tracker(G16S_GEOM_B, 4, sc, frames, NULL);
	size_t b0 = p0 / BLK, b1 = p1 / BLK + (size_t)(0.2 * RATE) / BLK;
	CHECK(lg.out[b0 - 1].locked, "locked before the pause");
	float held = lg.out[b0 - 1].steer_az_deg;
	CHECK(fabsf(held - 30.0f) <= 3.0f, "steer near the talker before the pause (%g)", held);
	float worst = 0.0f;
	int fb = 0;
	for (size_t b = b0; b < b1 && b < lg.nblocks; b++) {
		float d = fabsf(lg.out[b].steer_az_deg - held);
		if (d > worst)
			worst = d;
	}
	for (size_t b = 0; b < lg.nblocks; b++)
		fb |= lg.out[b].fallback;
	printf("  steer before the pause %+.2f deg, largest change through it %.3f deg\n", held, worst);
	CHECK(worst <= 1.0f, "steer held within 1 deg through an 800 ms pause (%g)", worst);
	CHECK_EQ_INT(fb, 0, "no fallback across the pause");
	CHECK(lg.out[lg.nblocks - 1].locked, "still locked after the talker resumes");
	free(lg.out);
	free(sc);
	free(s);
}

static void test_unsure_fallback(void)
{
	const size_t frames = (size_t)(2.6 * RATE), onset = 320 * BLK;
	g16mic_params p;
	float *s = talker(frames, 71, 100.0f, 220.0f, LEAD, onset, 0);

	printf("test_unsure_fallback\n");
	g16mic_params_default(&p);
	float *sc = scene_one(G16S_GEOM_B, 4, s, frames, 30.0f, 801);
	float *loud = g16s_xcalloc(frames * 4, sizeof(float));
	g16s_add_diffuse(loud, frames, 4, RATE, 901, 0.05f);
	for (size_t i = onset * 4; i < frames * 4; i++)
		sc[i] += loud[i];
	track_log lg = run_tracker(G16S_GEOM_B, 4, sc, frames, NULL);
	size_t ob = onset / BLK, fb = lg.nblocks;
	int early = 0;
	for (size_t b = 0; b < lg.nblocks; b++) {
		if (lg.out[b].fallback && b < ob)
			early = 1;
		if (lg.out[b].fallback && b >= ob && fb == lg.nblocks)
			fb = b;
	}
	size_t limit = (size_t)ceil(p.track_unsure_ms * 1e-3 * RATE / BLK) + 2;
	CHECK(lg.out[ob - 1].locked, "locked onto the talker before the noise");
	CHECK_EQ_INT(early, 0, "no fallback while the talker is clear");
	printf("  fallback %zu blocks after diffuse noise starts (limit %zu)\n", fb - ob, limit);
	CHECK(fb < lg.nblocks && fb - ob <= limit, "low confidence falls back within track_unsure_ms + 2 blocks");
	free(lg.out);
	free(sc);
	free(loud);
	free(s);
}

static void test_create_rejects(void)
{
	g16mic_params p;
	const float one[1][3] = { { 0, 0, 0 } };

	printf("test_create_rejects\n");
	g16mic_params_default(&p);
	CHECK(g16mic_tracker_create(one, 1, RATE, &p) == NULL, "one mic: no tracker");
	CHECK(g16mic_tracker_create(NULL, 2, RATE, &p) == NULL, "no positions: no tracker");
}

int main(void)
{
	test_create_rejects();
	test_gcc_phat_tdoa();
	test_doa();
	test_confidence_low();
	test_hysteresis();
	test_bounded_slew();
	test_pause_held();
	test_unsure_fallback();
	G16T_RETURN();
}
