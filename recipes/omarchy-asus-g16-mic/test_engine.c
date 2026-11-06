/* SPDX-License-Identifier: MIT */
/* test_engine.c: the processing engine end to end: any callback size gives
 * the same output, fixed latency, bit-exact raw passthrough (NaN included),
 * spatial modes refused without a verified calibration, aligned crossfades,
 * the tail flush, and word retention in tracking mode (quiet onsets and
 * endings, never silence, a louder interferer, pauses). Synthetic signals only.
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

static g16mic_engine *make_engine(const float pos[][3], int n, g16mic_mode mode, float az, int with_cal, float hpf, int dc)
{
	g16mic_calib cal;
	g16mic_params p;

	g16mic_params_default(&p);
	p.mode = mode;
	p.steer_az_deg = az;
	if (!with_cal)
		return g16mic_engine_create(n, RATE, NULL, G16MIC_CAL_MISSING, &p);
	g16s_make_cal(&cal, pos, n, hpf, dc);
	return g16mic_engine_create(n, RATE, &cal, G16MIC_CAL_OK, &p);
}

/* Processes everything, then flushes the tail (output is frames + latency long). */
static void run_all(g16mic_engine *e, const float *in, size_t frames, int C, float *raw, float *mono, size_t chunk)
{
	size_t done = 0, L = g16mic_engine_latency(e);

	while (done < frames) {
		size_t n = frames - done < chunk ? frames - done : chunk;
		g16mic_engine_process(e, in + done * C, n, raw + done * C, mono + done);
		done += n;
	}
	size_t got, total = 0;
	while ((got = g16mic_engine_flush(e, raw + (frames + total) * C, mono + frames + total, 333)) > 0)
		total += got;
	CHECK_EQ_INT(total, L, "flush writes exactly the latency's worth of frames");
}

static void test_callback_sizes(void)
{
	static const size_t fixed[] = { 1, 7, 256, 13, 4095, 0, 511, 1, 2, 3, 5, 8191, 8193, 16385, 0, 255, 257, 4097 };
	static const g16mic_mode modes[] = { G16MIC_MODE_RAW, G16MIC_MODE_OMNI, G16MIC_MODE_BEAM, G16MIC_MODE_TRACK };
	const size_t frames = 3 * RATE;
	const int C = 4;
	float *src = g16s_xcalloc(frames, sizeof(float)), *in = g16s_xcalloc(frames * C, sizeof(float));
	float *r1 = g16s_xcalloc(frames * C, sizeof(float)), *r2 = g16s_xcalloc(frames * C, sizeof(float));
	float *m1 = g16s_xcalloc(frames, sizeof(float)), *m2 = g16s_xcalloc(frames, sizeof(float));

	printf("test_callback_sizes\n");
	g16s_speech_like(src, frames, RATE, 81, 100.0f, 220.0f);
	g16s_render_plane(src, frames, G16S_GEOM_B, 4, 20.0f, 0.0f, RATE, in, C);
	g16s_add_diffuse(in, frames, C, RATE, 82, BED_RMS);
	for (int k = 0; k < 4; k++) {
		g16mic_engine *a = make_engine(G16S_GEOM_B, 4, modes[k], 20.0f, 1, 80.0f, 1);
		g16mic_engine *b = make_engine(G16S_GEOM_B, 4, modes[k], 20.0f, 1, 80.0f, 1);
		g16mic_stats sa, sb;
		uint32_t rs = 777u + (uint32_t)k;
		size_t done = 0, fi = 0;

		CHECK(a && b, "engines for %s", g16mic_mode_name(modes[k]));
		if (!a || !b)
			exit(1);
		g16mic_engine_process(a, in, frames, r1, m1);
		while (done < frames) {
			size_t n;
			if (fi < sizeof fixed / sizeof fixed[0])
				n = fixed[fi++];
			else
				n = (size_t)((g16t_rand_uniform(&rs) + 1.0f) * 2500.0f);
			if (n > frames - done)
				n = frames - done;
			g16mic_engine_process(b, in + done * C, n, r2 + done * C, m2 + done);
			done += n;
		}
		g16mic_engine_get_stats(a, &sa);
		g16mic_engine_get_stats(b, &sb);
		CHECK(memcmp(m1, m2, frames * sizeof(float)) == 0, "%s: mono identical for one call and mixed chunk sizes",
		      g16mic_mode_name(modes[k]));
		CHECK(memcmp(r1, r2, frames * C * sizeof(float)) == 0, "%s: raw identical for one call and mixed chunk sizes",
		      g16mic_mode_name(modes[k]));
		CHECK_EQ_INT(sa.frames_out, sa.frames_in, "%s: frames_out == frames_in (one call)", g16mic_mode_name(modes[k]));
		CHECK_EQ_INT(sb.frames_out, sb.frames_in, "%s: frames_out == frames_in (chunks)", g16mic_mode_name(modes[k]));
		CHECK_EQ_INT(sb.frames_in, frames, "%s: every frame counted", g16mic_mode_name(modes[k]));
		CHECK(g16mic_engine_latency(a) == g16mic_engine_latency(b), "latency fixed");
		g16mic_engine_destroy(a);
		g16mic_engine_destroy(b);
	}
	/* The latency is the same in every mode. */
	size_t lat[4];
	for (int k = 0; k < 4; k++) {
		g16mic_engine *e = make_engine(G16S_GEOM_B, 4, modes[k], 0.0f, 1, 80.0f, 1);
		lat[k] = e ? g16mic_engine_latency(e) : 0;
		g16mic_engine_destroy(e);
	}
	CHECK(lat[0] == lat[1] && lat[1] == lat[2] && lat[2] == lat[3], "one latency for every mode");
	free(src);
	free(in);
	free(r1);
	free(r2);
	free(m1);
	free(m2);
}

static void test_impulse_delay(void)
{
	const size_t frames = 8000, n0 = 3001;
	const int C = 4;
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *mono = g16s_xcalloc(frames, sizeof(float));

	printf("test_impulse_delay\n");
	for (int c = 0; c < C; c++)
		in[n0 * C + c] = 0.5f;
	g16mic_engine *e = make_engine(G16S_GEOM_B, 4, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	size_t L = g16mic_engine_latency(e);
	printf("  latency %zu frames\n", L);
	CHECK(L >= BLK + G16MIC_FD_CENTER, "latency covers the block and the filter");
	g16mic_engine_process(e, in, frames, raw, mono);
	int bad = 0;
	for (size_t n = 0; n < frames; n++)
		for (int c = 0; c < C; c++) {
			float want = (n == n0 + L) ? 0.5f : 0.0f;
			if (memcmp(&raw[n * C + c], &want, sizeof want) != 0)
				bad++;
		}
	CHECK_EQ_INT(bad, 0, "raw: impulse at n0 + latency, bit-exact, nothing else");
	size_t pk = 0;
	for (size_t n = 0; n < frames; n++)
		if (fabsf(mono[n]) > fabsf(mono[pk]))
			pk = n;
	CHECK_EQ_INT(pk, n0 + L, "omni: the impulse peaks at n0 + latency");
	g16mic_engine_destroy(e);

	e = make_engine(G16S_GEOM_B, 4, G16MIC_MODE_RAW, 0.0f, 1, 80.0f, 1);
	g16mic_engine_process(e, in, frames, raw, mono);
	CHECK(mono[n0 + L] == 0.5f, "raw mode: mono impulse at n0 + latency");
	g16mic_engine_destroy(e);
	free(in);
	free(raw);
	free(mono);
}

static void test_raw_bitexact_nan(void)
{
	const size_t frames = 6000;
	const int C = 2;
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *mono = g16s_xcalloc(frames, sizeof(float));
	g16mic_stats st;

	printf("test_raw_bitexact_nan\n");
	g16s_noise(in, frames * C, 91, 0.3f);
	in[1000 * C + 1] = NAN;
	in[1500 * C + 0] = NAN;
	in[1700 * C + 0] = 1e-42f;  /* a denormal, passed through untouched */
	g16mic_engine *e = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_RAW, 0.0f, 1, 80.0f, 1);
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	size_t L = g16mic_engine_latency(e);
	g16mic_engine_process(e, in, frames, raw, mono);
	CHECK(memcmp(raw + L * C, in, (frames - L) * C * sizeof(float)) == 0, "raw mode: raw_out bit-exact, NaN included");
	int bad = 0;
	for (size_t n = L; n < frames; n++)
		if (memcmp(&mono[n], &in[(n - L) * C], sizeof(float)) != 0)
			bad++;
	CHECK_EQ_INT(bad, 0, "raw mode: mono is channel 0, bit-exact, NaN included");
	g16mic_engine_destroy(e);

	e = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
	g16mic_engine_process(e, in, frames, raw, mono);
	g16mic_engine_get_stats(e, &st);
	CHECK(memcmp(raw + L * C, in, (frames - L) * C * sizeof(float)) == 0, "omni mode: raw_out still bit-exact");
	int nonfinite = 0;
	for (size_t n = 0; n < frames; n++)
		if (!isfinite(mono[n]))
			nonfinite++;
	CHECK_EQ_INT(nonfinite, 0, "omni output is finite");
	CHECK_EQ_INT(st.nonfinite_samples, 2, "omni counts the non-finite input samples");
	CHECK(g16t_rms(mono + 2000, 3000) > 0.05, "omni output is not silenced around the bad samples");
	g16mic_engine_destroy(e);
	free(in);
	free(raw);
	free(mono);
}

static void test_unverified(void)
{
	const size_t frames = RATE / 2;
	const int C = 2;
	g16mic_calib cal;
	g16mic_params p;
	g16mic_stats st;
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *mono = g16s_xcalloc(frames, sizeof(float));

	printf("test_unverified\n");
	g16s_make_cal(&cal, G16S_GEOM_A, 2, 80.0f, 1);
	cal.verified = 0;
	g16mic_params_default(&p);
	p.mode = G16MIC_MODE_BEAM;
	CHECK(g16mic_engine_create(C, RATE, &cal, G16MIC_CAL_UNVERIFIED, &p) == NULL, "beam refused at create");
	p.mode = G16MIC_MODE_TRACK;
	CHECK(g16mic_engine_create(C, RATE, &cal, G16MIC_CAL_UNVERIFIED, &p) == NULL, "track refused at create");
	CHECK(g16mic_engine_create(C, RATE, NULL, G16MIC_CAL_MISSING, &p) == NULL, "track refused without a file");
	p.mode = G16MIC_MODE_OMNI;
	CHECK(g16mic_engine_create(C, 44100, &cal, G16MIC_CAL_UNVERIFIED, &p) == NULL, "44.1 kHz refused");
	CHECK(g16mic_engine_create(0, RATE, &cal, G16MIC_CAL_UNVERIFIED, &p) == NULL, "0 channels refused");
	CHECK(g16mic_engine_create(9, RATE, &cal, G16MIC_CAL_UNVERIFIED, &p) == NULL, "9 channels refused");
	g16mic_engine *e = g16mic_engine_create(C, RATE, &cal, G16MIC_CAL_UNVERIFIED, &p);
	CHECK(e != NULL, "omni works with an unverified file");
	if (!e)
		exit(1);
	CHECK_EQ_INT(g16mic_engine_request_mode(e, G16MIC_MODE_TRACK), -1, "track request refused");
	g16mic_engine_get_stats(e, &st);
	CHECK_EQ_INT(st.refused_switches, 1, "refused_switches counted");
	CHECK_EQ_INT(st.spatial_available, 0, "spatial unavailable");
	CHECK_EQ_INT(st.spatial_reason, G16MIC_CAL_UNVERIFIED, "reason: unverified");
	CHECK_EQ_INT(st.omni_calibrated, 0, "omni uses identity for an unverified file");
	CHECK_EQ_INT(st.mode_active, G16MIC_MODE_OMNI, "mode unchanged");
	CHECK_EQ_INT(g16mic_engine_request_mode(e, G16MIC_MODE_BEAM), -1, "beam request refused");
	g16mic_engine_get_stats(e, &st);
	CHECK_EQ_INT(st.refused_switches, 2, "second refusal counted");

	g16s_noise(in, frames * C, 92, 0.2f);
	g16mic_engine_process(e, in, frames, raw, mono);
	CHECK(g16t_rms(mono + RATE / 10, frames - RATE / 10) > 0.05, "omni produces output");
	CHECK_EQ_INT(g16mic_engine_request_mode(e, G16MIC_MODE_RAW), 0, "raw request accepted");
	g16mic_engine_process(e, in, frames, raw, mono);
	g16mic_engine_get_stats(e, &st);
	CHECK_EQ_INT(st.mode_active, G16MIC_MODE_RAW, "raw active");
	size_t L = g16mic_engine_latency(e);
	/* after the crossfade the mono output is channel 0 of the input, delayed by L (the input repeats) */
	int bad = 0;
	for (size_t n = RATE / 10; n < frames; n++) {
		size_t src = (n + frames - L) % frames;
		if (memcmp(&mono[n], &in[src * C], sizeof(float)) != 0)
			bad++;
	}
	CHECK_EQ_INT(bad, 0, "raw mode works with an unverified file");
	g16mic_engine_destroy(e);
	free(in);
	free(raw);
	free(mono);
}

static void test_crossfade_alignment(void)
{
	const size_t frames = 3 * RATE;
	const int C = 2;
	g16mic_calib cal;
	g16mic_params p;
	g16mic_stats st;
	float *src = g16s_xcalloc(frames, sizeof(float)), *in = g16s_xcalloc(frames * C, sizeof(float));
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *mono = g16s_xcalloc(frames, sizeof(float));

	printf("test_crossfade_alignment\n");
	g16s_speech_like(src, frames, RATE, 93, 100.0f, 220.0f);
	for (size_t n = 0; n < frames; n++)
		in[n * C] = in[n * C + 1] = src[n];  /* identical channels: omni == raw channel 0 */
	g16mic_calib_identity(&cal, C);
	cal.verified = 1;
	cal.hpf_hz = 0.0f;
	cal.dc_block = 0;
	g16mic_params_default(&p);
	p.mode = G16MIC_MODE_RAW;
	g16mic_engine *e = g16mic_engine_create(C, RATE, &cal, G16MIC_CAL_ZERO_APERTURE, &p);
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	size_t L = g16mic_engine_latency(e);
	for (size_t done = 0; done < frames; done += 480) {
		if (done == RATE)
			CHECK_EQ_INT(g16mic_engine_request_mode(e, G16MIC_MODE_OMNI), 0, "omni accepted");
		if (done == 2 * RATE)
			CHECK_EQ_INT(g16mic_engine_request_mode(e, G16MIC_MODE_RAW), 0, "raw accepted");
		g16mic_engine_process(e, in + done * C, 480, raw + done * C, mono + done);
	}
	double worst = 0.0;
	for (size_t n = 0; n < frames; n++) {
		double want = n >= L ? src[n - L] : 0.0;
		double d = fabs(mono[n] - want);
		if (d > worst)
			worst = d;
	}
	g16mic_engine_get_stats(e, &st);
	printf("  raw -> omni -> raw: largest deviation from the delayed input %.2g, %llu switches\n", worst,
	       (unsigned long long)st.mode_switches);
	CHECK(worst <= 1e-4, "no phase jump and no dropped sample across both crossfades (%g)", worst);
	CHECK_EQ_INT(st.mode_switches, 2, "two switches");
	g16mic_engine_destroy(e);

	/* omni -> beam on a broadside source: both share one group delay, so the
	 * crossfade is seamless against an omni-only run. */
	{
		const int C4 = 4;
		float *in4 = g16s_xcalloc(frames * C4, sizeof(float)), *raw4 = g16s_xcalloc(frames * C4, sizeof(float));
		float *mo = g16s_xcalloc(frames, sizeof(float)), *mx = g16s_xcalloc(frames, sizeof(float));
		g16s_render_plane(src, frames, G16S_GEOM_B, 4, 0.0f, 0.0f, RATE, in4, C4);
		g16mic_engine *eo = make_engine(G16S_GEOM_B, 4, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
		g16mic_engine *ex = make_engine(G16S_GEOM_B, 4, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
		CHECK(eo && ex, "engines");
		if (!eo || !ex)
			exit(1);
		for (size_t done = 0; done < frames; done += 480) {
			if (done == RATE)
				CHECK_EQ_INT(g16mic_engine_request_mode(ex, G16MIC_MODE_BEAM), 0, "beam accepted");
			g16mic_engine_process(eo, in4 + done * C4, 480, raw4 + done * C4, mo + done);
			g16mic_engine_process(ex, in4 + done * C4, 480, raw4 + done * C4, mx + done);
		}
		double w2 = 0.0;
		for (size_t n = 0; n < frames; n++)
			if (fabs(mo[n] - mx[n]) > w2)
				w2 = fabs(mo[n] - mx[n]);
		CHECK(w2 <= 1e-4, "omni -> beam crossfade is aligned (%g)", w2);
		g16mic_engine_destroy(eo);
		g16mic_engine_destroy(ex);
		free(in4);
		free(raw4);
		free(mo);
		free(mx);
	}
	free(src);
	free(in);
	free(raw);
	free(mono);
}

static void test_tail_flush(void)
{
	const size_t frames = RATE, burst = (size_t)(0.03 * RATE);
	const int C = 2;
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	float *b = g16s_xcalloc(burst, sizeof(float));

	printf("test_tail_flush\n");
	g16s_sine(b, burst, RATE, 1000.0f, 0.3f);
	for (size_t n = 0; n < burst; n++)
		in[(frames - burst + n) * C] = in[(frames - burst + n) * C + 1] = b[n];
	g16mic_engine *e = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_OMNI, 0.0f, 0, 0.0f, 0);
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	size_t L = g16mic_engine_latency(e);
	float *raw = g16s_xcalloc((frames + L) * C, sizeof(float)), *mono = g16s_xcalloc(frames + L, sizeof(float));
	run_all(e, in, frames, C, raw, mono, 1000);
	CHECK_EQ_INT(g16mic_engine_flush(e, raw, mono, 100), 0, "flush returns 0 once drained");
	double eb = g16s_energy(b, burst);
	double eo = g16s_energy(mono + frames - burst, burst + L);
	printf("  burst energy kept %.4f\n", eo / eb);
	CHECK(eo >= 0.99 * eb, "a burst in the last 30 ms survives the stop (%.4f)", eo / eb);
	CHECK(memcmp(&raw[(frames - 1 + L) * C], &in[(frames - 1) * C], C * sizeof(float)) == 0,
	      "the last input frame reaches raw_out");
	g16mic_engine_destroy(e);
	free(in);
	free(b);
	free(raw);
	free(mono);
}

/* Scene for the tracking retention tests: array A, -70 dBFS bed. */
static float *scene_a(const float *target, float taz, const float *interf, float iaz, size_t frames)
{
	float *sc = g16s_xcalloc(frames * 2, sizeof(float));

	if (target)
		g16s_render_plane_add(target, frames, G16S_GEOM_A, 2, taz, 0.0f, RATE, sc, 2);
	if (interf)
		g16s_render_plane_add(interf, frames, G16S_GEOM_A, 2, iaz, 0.0f, RATE, sc, 2);
	g16s_add_diffuse(sc, frames, 2, RATE, 1001, BED_RMS);
	return sc;
}

static void test_quiet_onset_and_never_silent(void)
{
	const size_t frames = 3 * RATE, t0 = RATE;
	float *s = g16s_xcalloc(frames, sizeof(float));

	printf("test_quiet_onset_and_never_silent\n");
	g16s_voiced(s, frames, RATE, 111, 100.0f, 200.0f);
	for (size_t n = 0; n < t0; n++)
		s[n] = 0.0f;
	g16s_scale_rms(s + t0, frames - t0, 5.623e-3f);  /* -45 dBFS, to the last sample */
	float *sc = scene_a(s, -30.0f, NULL, 0.0f, frames);
	g16mic_engine *et = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_TRACK, 0.0f, 1, 80.0f, 1);
	g16mic_engine *eo = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
	CHECK(et && eo, "engines");
	if (!et || !eo)
		exit(1);
	size_t L = g16mic_engine_latency(et);
	CHECK_EQ_INT(L, g16mic_engine_latency(eo), "track and omni share one latency");
	float *rt = g16s_xcalloc((frames + L) * 2, sizeof(float)), *mt = g16s_xcalloc(frames + L, sizeof(float));
	float *ro = g16s_xcalloc((frames + L) * 2, sizeof(float)), *mo = g16s_xcalloc(frames + L, sizeof(float));
	run_all(et, sc, frames, 2, rt, mt, 480);
	run_all(eo, sc, frames, 2, ro, mo, 480);

	size_t on = t0 + L, w20 = RATE / 50, w50 = RATE / 20;
	double r_on = 10.0 * log10(g16s_energy(mt + on, w20) / g16s_energy(mo + on, w20));
	double r_end = 10.0 * log10(g16s_energy(mt + frames + L - w50, w50) / g16s_energy(mo + frames + L - w50, w50));
	printf("  first 20 ms %+.2f dB, last 50 ms %+.2f dB of the omni energy\n", r_on, r_end);
	CHECK(r_on >= -1.0, "quiet onset kept (%g dB)", r_on);
	CHECK(r_end >= -1.0, "ending kept through the flush (%g dB)", r_end);

	double worst = 100.0;
	for (size_t a = on; a + w20 <= frames + L; a += w20) {
		double r = 10.0 * log10((g16s_energy(mt + a, w20) + 1e-30) / (g16s_energy(mo + a, w20) + 1e-30));
		if (r < worst)
			worst = r;
	}
	printf("  worst 20 ms window while talking %+.2f dB\n", worst);
	CHECK(worst > -40.0, "never more than 40 dB below omni while the talker is active (%g dB)", worst);
	g16mic_engine_destroy(et);
	g16mic_engine_destroy(eo);
	free(rt);
	free(mt);
	free(ro);
	free(mo);
	free(sc);
	free(s);
}

static void test_crossed_loudness_track(void)
{
	const size_t frames = 4 * RATE, i0 = (size_t)(1.5 * RATE), i1 = (size_t)(2.5 * RATE), t0 = RATE / 5;
	float *t = g16s_xcalloc(frames, sizeof(float)), *in = g16s_xcalloc(frames, sizeof(float));

	printf("test_crossed_loudness_track\n");
	g16s_voiced(t, frames, RATE, 121, 100.0f, 180.0f);
	for (size_t n = 0; n < t0; n++)
		t[n] = 0.0f;
	g16s_scale_rms(t + t0, frames - t0, 0.0316f);  /* -30 dBFS */
	/* The interferer is coherent speech-band noise from one direction: the
	 * tracker sees a strong, confident source, and because it is independent
	 * of the target the per-window projection gain stays an unbiased
	 * estimate of how much of the target is kept. */
	g16s_bandnoise(in, frames, RATE, 122, 200.0f, 4000.0f);
	g16s_scale_rms(in, frames, 0.0631f);  /* +6 dB */
	for (size_t n = 0; n < frames; n++)
		if (n < i0 || n >= i1)
			in[n] = 0.0f;
	float *mix = scene_a(t, -30.0f, in, 40.0f, frames);
	float *tonly = scene_a(t, -30.0f, NULL, 0.0f, frames);
	g16mic_engine *et = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_TRACK, 0.0f, 1, 80.0f, 1);
	g16mic_engine *eo = make_engine(G16S_GEOM_A, 2, G16MIC_MODE_OMNI, 0.0f, 1, 80.0f, 1);
	CHECK(et && eo, "engines");
	if (!et || !eo)
		exit(1);
	size_t L = g16mic_engine_latency(et);
	float *rt = g16s_xcalloc((frames + L) * 2, sizeof(float)), *mt = g16s_xcalloc(frames + L, sizeof(float));
	float *ro = g16s_xcalloc((frames + L) * 2, sizeof(float)), *ref = g16s_xcalloc(frames + L, sizeof(float));
	run_all(et, mix, frames, 2, rt, mt, 480);
	run_all(eo, tonly, frames, 2, ro, ref, 480);

	/* Physical note: with a 10 cm two-mic array, even a beam steered fully
	 * onto the interferer keeps most of a talker 70 deg away below 1 kHz,
	 * so -6 dB holds with margin; the check stays strict for every window. */
	double worst = 100.0;
	for (size_t a = t0 + L + RATE / 10; a + RATE / 10 <= frames + L; a += RATE / 10) {
		double num = 0.0, den = 0.0;
		for (size_t n = a; n < a + RATE / 10; n++) {
			num += (double)mt[n] * ref[n];
			den += (double)ref[n] * ref[n];
		}
		double g = den > 0.0 ? num / den : 0.0;
		double db = g16t_db(g > 0.0 ? g : 0.0);
		if (db < worst)
			worst = db;
	}
	g16mic_stats st;
	g16mic_engine_get_stats(et, &st);
	printf("  worst 100 ms target gain %+.2f dB; fallbacks %llu\n", worst, (unsigned long long)st.fallbacks);
	CHECK(worst >= -6.0, "target kept at >= -6 dB in every window with a louder interferer (%g dB)", worst);
	g16mic_engine_destroy(et);
	g16mic_engine_destroy(eo);
	free(rt);
	free(mt);
	free(ro);
	free(ref);
	free(mix);
	free(tonly);
	free(t);
	free(in);
}

static void test_pause_fallbacks(void)
{
	const size_t frames = (size_t)(3.5 * RATE), p0 = (size_t)(1.7 * RATE), p1 = (size_t)(2.5 * RATE);
	const int C = 4;
	float *s = g16s_xcalloc(frames, sizeof(float));

	printf("test_pause_fallbacks\n");
	g16s_speech_like(s, frames, RATE, 131, 100.0f, 220.0f);
	for (size_t n = 0; n < frames; n++)
		if (n < RATE / 5 || (n >= p0 && n < p1))
			s[n] = 0.0f;
	float *in = g16s_xcalloc(frames * C, sizeof(float));
	g16s_render_plane(s, frames, G16S_GEOM_B, 4, 30.0f, 0.0f, RATE, in, C);
	g16s_add_diffuse(in, frames, C, RATE, 132, BED_RMS);
	g16mic_engine *e = make_engine(G16S_GEOM_B, 4, G16MIC_MODE_TRACK, 0.0f, 1, 80.0f, 1);
	CHECK(e != NULL, "engine");
	if (!e)
		exit(1);
	float *raw = g16s_xcalloc(frames * C, sizeof(float)), *mono = g16s_xcalloc(frames, sizeof(float));
	g16mic_stats st;
	uint64_t fb_before = 0, fb_after = 0;
	int tracking_before = 0;
	for (size_t done = 0; done < frames; done += 480) {
		if (done == p0 / 480 * 480) {
			g16mic_engine_get_stats(e, &st);
			fb_before = st.fallbacks;
			tracking_before = st.mode_active == G16MIC_MODE_TRACK;
		}
		g16mic_engine_process(e, in + done * C, 480 < frames - done ? 480 : frames - done, raw + done * C, mono + done);
		if (done == (p1 + RATE / 4) / 480 * 480) {
			g16mic_engine_get_stats(e, &st);
			fb_after = st.fallbacks;
		}
	}
	g16mic_engine_get_stats(e, &st);
	printf("  fallbacks before the pause %llu, after %llu; steer %+.1f deg\n", (unsigned long long)fb_before,
	       (unsigned long long)fb_after, st.steer_az_deg);
	CHECK(tracking_before, "steering toward the talker before the pause");
	CHECK_EQ_INT(fb_after, fb_before, "an 800 ms pause causes no fallback");
	CHECK_EQ_INT(st.degraded, 0, "not degraded after the talker resumes");
	CHECK_EQ_INT(st.mode_requested, G16MIC_MODE_TRACK, "track requested");
	g16mic_engine_destroy(e);
	free(s);
	free(in);
	free(raw);
	free(mono);
}

static void test_mode_names(void)
{
	g16mic_mode m;

	printf("test_mode_names\n");
	for (int k = 0; k <= (int)G16MIC_MODE_TRACK; k++) {
		CHECK_EQ_INT(g16mic_mode_parse(g16mic_mode_name((g16mic_mode)k), &m), 0, "parse %d", k);
		CHECK_EQ_INT(m, k, "round trip %d", k);
	}
	CHECK_EQ_INT(g16mic_mode_parse("loud", &m), -1, "unknown mode");
	CHECK(!g16mic_mode_is_spatial(G16MIC_MODE_RAW) && !g16mic_mode_is_spatial(G16MIC_MODE_OMNI), "raw/omni not spatial");
	CHECK(g16mic_mode_is_spatial(G16MIC_MODE_BEAM) && g16mic_mode_is_spatial(G16MIC_MODE_TRACK), "beam/track spatial");
}

int main(void)
{
	test_mode_names();
	test_callback_sizes();
	test_impulse_delay();
	test_raw_bitexact_nan();
	test_unverified();
	test_crossfade_alignment();
	test_tail_flush();
	test_quiet_onset_and_never_silent();
	test_crossed_loudness_track();
	test_pause_fallbacks();
	G16T_RETURN();
}
