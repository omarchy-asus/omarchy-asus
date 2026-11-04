/* SPDX-License-Identifier: MIT */
/* test_beam.c: steering delays, the fractional-delay filter and the fixed
 * delay-and-sum beam (unity on target, off-target rejection, chunk
 * continuity, output headroom, a louder interferer). Synthetic signals only.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"
#include "test_util.h"
#include "test_signals.h"

#define RATE G16MIC_RATE

static g16mic_engine *make_beam(const float pos[][3], int n, float az, float ceiling)
{
	g16mic_calib cal;
	g16mic_params p;

	g16s_make_cal(&cal, pos, n, 0.0f, 0);  /* no high-pass: compare against the source itself */
	g16mic_params_default(&p);
	p.mode = G16MIC_MODE_BEAM;
	p.steer_az_deg = az;
	p.limiter_ceiling = ceiling;
	return g16mic_engine_create(n, RATE, &cal, G16MIC_CAL_OK, &p);
}

/* Beam output for a source rendered from src_az, steered to beam_az. */
static float *beam_run(const float pos[][3], int n, const float *src, size_t frames, float src_az, float beam_az,
		       float ceiling, size_t *latency, g16mic_stats *st)
{
	float *in = g16s_xcalloc(frames * (size_t)n, sizeof(float));
	float *raw = g16s_xcalloc(frames * (size_t)n, sizeof(float));
	float *mono = g16s_xcalloc(frames, sizeof(float));
	g16mic_engine *e = make_beam(pos, n, beam_az, ceiling);

	CHECK(e != NULL, "beam engine");
	if (!e)
		exit(1);
	g16s_render_plane(src, frames, pos, n, src_az, 0.0f, RATE, in, n);
	g16mic_engine_process(e, in, frames, raw, mono);
	if (latency)
		*latency = g16mic_engine_latency(e);
	if (st)
		g16mic_engine_get_stats(e, st);
	g16mic_engine_destroy(e);
	free(in);
	free(raw);
	return mono;
}

static void test_steering_sign(void)
{
	float d[4];

	printf("test_steering_sign\n");
	g16mic_steering_delays(G16S_GEOM_A, 2, 90.0f, 0.0f, RATE, d);
	CHECK(d[1] > d[0], "source at +90 deg: the +x mic gets the larger delay (%g vs %g)", d[1], d[0]);
	CHECK_NEAR(d[1], 0.05 * RATE / G16MIC_SPEED_OF_SOUND, 1e-3, "+x mic delay at +90 deg");
	CHECK_NEAR(d[0], -0.05 * RATE / G16MIC_SPEED_OF_SOUND, 1e-3, "-x mic delay at +90 deg");
	g16mic_steering_delays(G16S_GEOM_A, 2, -90.0f, 0.0f, RATE, d);
	CHECK(d[0] > d[1], "source at -90 deg: the -x mic gets the larger delay");
	g16mic_steering_delays(G16S_GEOM_B, 4, 0.0f, 0.0f, RATE, d);
	for (int i = 0; i < 4; i++)
		CHECK_NEAR(d[i], 0.0, 1e-4, "broadside source: mic %d delay", i);
	/* Planar array: a source toward the user (+y) delays the +y mic most. */
	g16mic_steering_delays(G16S_GEOM_C, 4, 0.0f, 0.0f, RATE, d);
	CHECK(d[3] > d[2], "planar array, source at 0 deg: +y mic later than -y mic");
	CHECK_NEAR(d[0], d[1], 1e-4, "planar array, source at 0 deg: x mics equal");
}

static void test_fracdelay_taps(void)
{
	static const float fracs[] = { 0.0f, 0.25f, 0.5f, 0.75f, 0.999f };
	float t[G16MIC_FD_TAPS];

	printf("test_fracdelay_taps\n");
	for (size_t f = 0; f < sizeof fracs / sizeof fracs[0]; f++) {
		double sum = 0.0, cen = 0.0;
		g16mic_fracdelay_taps(fracs[f], t);
		for (int k = 0; k < G16MIC_FD_TAPS; k++) {
			CHECK(isfinite(t[k]), "tap %d finite", k);
			sum += t[k];
			cen += k * (double)t[k];
		}
		CHECK_NEAR(sum, 1.0, 1e-5, "frac %g: taps sum to 1", fracs[f]);
		CHECK_NEAR(cen / sum, G16MIC_FD_CENTER + fracs[f], 0.02, "frac %g: centroid", fracs[f]);
	}
	g16mic_fracdelay_taps(0.0f, t);
	for (int k = 0; k < G16MIC_FD_TAPS; k++)
		CHECK(t[k] == (k == G16MIC_FD_CENTER ? 1.0f : 0.0f), "frac 0 is an exact unit impulse (tap %d)", k);
	/* Group delay at a speech frequency: a 1 kHz sine through frac 0.5 lags
	 * the same sine through frac 0 by half a sample. */
	{
		enum { N = 4096 };
		static float x[N], y0[N], y5[N];
		float t5[G16MIC_FD_TAPS];
		g16s_sine(x, N, RATE, 1000.0f, 0.5f);
		g16mic_fracdelay_taps(0.0f, t);
		g16mic_fracdelay_taps(0.5f, t5);
		for (int n = G16MIC_FD_TAPS; n < N; n++) {
			double a = 0, b = 0;
			for (int k = 0; k < G16MIC_FD_TAPS; k++) {
				a += t[k] * x[n - k];
				b += t5[k] * x[n - k];
			}
			y0[n] = (float)a;
			y5[n] = (float)b;
		}
		/* y5[n] should equal x at n - 16.5: compare with the exact sine. */
		double err = 0.0;
		for (int n = 200; n < N; n++) {
			double ref = 0.5 * sin(2.0 * M_PI * 1000.0 * (n - 16.5) / RATE);
			double e = fabs(y5[n] - ref);
			if (e > err)
				err = e;
		}
		CHECK(err < 2e-3, "frac 0.5 at 1 kHz: max error %g", err);
		CHECK_NEAR(y0[300], x[300 - G16MIC_FD_CENTER], 0.0, "frac 0 is a pure integer delay");
	}
}

static void test_beam_unity(void)
{
	static const float freqs[] = { 300.0f, 1000.0f, 3000.0f };
	const size_t frames = RATE + RATE / 2;
	float *src = g16s_xcalloc(frames, sizeof(float));
	size_t L;

	printf("test_beam_unity\n");
	for (size_t f = 0; f < 3; f++) {
		g16s_sine(src, frames, RATE, freqs[f], 0.3f);
		float *mono = beam_run(G16S_GEOM_B, 4, src, frames, 30.0f, 30.0f, 0.891f, &L, NULL);
		size_t a = L + G16S_DBIG + 4800;
		double db = g16t_db(g16t_rms(mono + a, frames - a) / g16t_rms(src + 4800, frames - a));
		printf("  %g Hz on target: %+.3f dB\n", freqs[f], db);
		CHECK_NEAR(db, 0.0, 0.3, "sine %g Hz from 30 deg, beam at 30 deg", freqs[f]);
		free(mono);
	}
	/* Broadband: the output is the source itself, delayed by DBIG + L. */
	g16s_speech_like(src, frames, RATE, 11, 100.0f, 220.0f);
	float *mono = beam_run(G16S_GEOM_B, 4, src, frames, 30.0f, 30.0f, 0.891f, &L, NULL);
	size_t off = L + G16S_DBIG, a = off + 4800;
	double db = g16t_db(g16t_rms(mono + a, frames - a) / g16t_rms(src + a - off, frames - a));
	double num = 0, den = 0;
	for (size_t n = a; n < frames; n++) {
		double r = src[n - off];
		num += (mono[n] - r) * (mono[n] - r);
		den += r * r;
	}
	printf("  speech-like on target: %+.3f dB, residual %.1f dB\n", db, 10.0 * log10(num / den));
	CHECK_NEAR(db, 0.0, 0.5, "speech-like from 30 deg, beam at 30 deg");
	CHECK(num / den < 0.01, "on-target output is the delayed source (residual %g)", num / den);
	free(mono);
	free(src);
}

static void test_beam_off_target(void)
{
	const size_t frames = RATE;
	float *src = g16s_xcalloc(frames, sizeof(float));
	size_t L;

	printf("test_beam_off_target\n");
	g16s_sine(src, frames, RATE, 3000.0f, 0.3f);
	float *on = beam_run(G16S_GEOM_B, 4, src, frames, 30.0f, 30.0f, 0.891f, &L, NULL);
	float *off = beam_run(G16S_GEOM_B, 4, src, frames, -60.0f, 30.0f, 0.891f, &L, NULL);
	size_t a = L + G16S_DBIG + 2400;
	double att = g16t_db(g16t_rms(on + a, frames - a) / g16t_rms(off + a, frames - a));
	printf("  3 kHz from -60 deg, beam at 30 deg: %.1f dB below on-target\n", att);
	CHECK(att >= 6.0, "off-target attenuation %.2f dB >= 6 dB", att);
	free(on);
	free(off);
	free(src);
}

static void test_chunk_continuity(void)
{
	const size_t frames = RATE + RATE / 2;
	const int C = 4;
	float *src = g16s_xcalloc(frames, sizeof(float));
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	float *raw1 = g16s_xcalloc(frames * C, sizeof(float)), *raw2 = g16s_xcalloc(frames * C, sizeof(float));
	float *m1 = g16s_xcalloc(frames, sizeof(float)), *m2 = g16s_xcalloc(frames, sizeof(float));
	uint32_t rs = 12345;

	printf("test_chunk_continuity\n");
	g16s_speech_like(src, frames, RATE, 5, 120.0f, 200.0f);
	g16s_render_plane(src, frames, G16S_GEOM_B, 4, 20.0f, 0.0f, RATE, in, C);
	g16mic_engine *e1 = make_beam(G16S_GEOM_B, 4, 20.0f, 0.891f);
	g16mic_engine *e2 = make_beam(G16S_GEOM_B, 4, 20.0f, 0.891f);
	CHECK(e1 && e2, "engines");
	if (!e1 || !e2)
		exit(1);
	g16mic_engine_process(e1, in, frames, raw1, m1);
	for (size_t done = 0; done < frames;) {
		size_t n = (size_t)((g16t_rand_uniform(&rs) + 1.0f) * 1500.0f);
		if (n > frames - done)
			n = frames - done;
		g16mic_engine_process(e2, in + done * C, n, raw2 + done * C, m2 + done);
		done += n;
	}
	CHECK(memcmp(m1, m2, frames * sizeof(float)) == 0, "beam output identical for one call and random chunks");
	CHECK(memcmp(raw1, raw2, frames * C * sizeof(float)) == 0, "raw output identical for one call and random chunks");
	g16mic_engine_destroy(e1);
	g16mic_engine_destroy(e2);
	free(src);
	free(in);
	free(raw1);
	free(raw2);
	free(m1);
	free(m2);
}

static void test_headroom(void)
{
	const size_t frames = RATE;
	float *src = g16s_xcalloc(frames, sizeof(float));
	g16mic_stats st;
	size_t L;

	printf("test_headroom\n");
	g16s_sine(src, frames, RATE, 1000.0f, 0.99f);
	float *hot = beam_run(G16S_GEOM_B, 4, src, frames, 0.0f, 0.0f, 0.891f, &L, &st);
	float peak = 0.0f;
	for (size_t n = 0; n < frames; n++)
		if (fabsf(hot[n]) > peak)
			peak = fabsf(hot[n]);
	printf("  0.99 peak input: output peak %.4f, limited blocks %llu\n", peak, (unsigned long long)st.limiter_blocks);
	CHECK(peak <= 0.891f, "output never exceeds the ceiling (%g)", peak);
	CHECK(peak > 0.85f, "the limiter only takes the excess off (%g)", peak);
	CHECK(st.limiter_blocks > 0, "limiter_blocks counted");
	free(hot);

	/* -20 dBFS: gain exactly 1, bit-identical to an engine whose ceiling is far away. */
	g16s_sine(src, frames, RATE, 1000.0f, 0.1f);
	float *quiet = beam_run(G16S_GEOM_B, 4, src, frames, 0.0f, 0.0f, 0.891f, &L, &st);
	float *ref = beam_run(G16S_GEOM_B, 4, src, frames, 0.0f, 0.0f, 1000.0f, &L, NULL);
	CHECK(memcmp(quiet, ref, frames * sizeof(float)) == 0, "-20 dBFS passes with gain exactly 1");
	CHECK_EQ_INT(st.limiter_blocks, 0, "no limited blocks at -20 dBFS");
	free(quiet);
	free(ref);
	free(src);
}

static void test_crossed_loudness_beam(void)
{
	const size_t frames = 2 * RATE;
	const int C = 4;
	float *t = g16s_xcalloc(frames, sizeof(float)), *i = g16s_xcalloc(frames, sizeof(float));
	float *mix = g16s_xcalloc(frames * C, sizeof(float));
	size_t L;

	printf("test_crossed_loudness_beam\n");
	g16s_speech_like(t, frames, RATE, 21, 100.0f, 160.0f);
	g16s_speech_like(i, frames, RATE, 22, 170.0f, 260.0f);
	for (size_t n = 0; n < frames; n++) {
		t[n] *= 0.2f;   /* target peak 0.1 */
		i[n] *= 0.4f;   /* interferer +6 dB */
	}
	float *ot = beam_run(G16S_GEOM_B, 4, t, frames, 0.0f, 0.0f, 0.891f, &L, NULL);
	float *oi = beam_run(G16S_GEOM_B, 4, i, frames, 60.0f, 0.0f, 0.891f, &L, NULL);

	g16s_render_plane(t, frames, G16S_GEOM_B, 4, 0.0f, 0.0f, RATE, mix, C);
	g16s_render_plane_add(i, frames, G16S_GEOM_B, 4, 60.0f, 0.0f, RATE, mix, C);
	g16mic_engine *e = make_beam(G16S_GEOM_B, 4, 0.0f, 0.891f);
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *om = g16s_xcalloc(frames, sizeof(float));
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	g16mic_engine_process(e, mix, frames, raw, om);
	g16mic_engine_destroy(e);

	double maxdev = 0.0;
	for (size_t n = 0; n < frames; n++) {
		double d = fabs(om[n] - (ot[n] + oi[n]));
		if (d > maxdev)
			maxdev = d;
	}
	CHECK(maxdev < 1e-4, "the fixed beam is linear below the ceiling (max dev %g)", maxdev);

	size_t off = L + G16S_DBIG, a = off + 2400;
	double kept = g16t_db(g16t_rms(ot + a, frames - a) / g16t_rms(t + a - off, frames - a));
	double irej = g16t_db(g16t_rms(oi + a, frames - a) / g16t_rms(i + a - off, frames - a));
	printf("  target retained %+.2f dB, interferer %+.2f dB\n", kept, irej);
	CHECK_NEAR(kept, 0.0, 1.0, "target at 0 deg retained with a louder interferer at 60 deg");
	free(ot);
	free(oi);
	free(raw);
	free(om);
	free(mix);
	free(t);
	free(i);
}

int main(void)
{
	test_steering_sign();
	test_fracdelay_taps();
	test_beam_unity();
	test_beam_off_target();
	test_chunk_continuity();
	test_headroom();
	test_crossed_loudness_beam();
	G16T_RETURN();
}
