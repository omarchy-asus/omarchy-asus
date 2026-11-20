/* SPDX-License-Identifier: MIT */
/* test_signals.h: deterministic synthetic test signals for the g16-mic DSP
 * tests. Everything is generated from a seed; no recorded audio is used.
 *
 *   g16s_noise          white noise, uniform in [-amp, amp)
 *   g16s_voiced         continuous voiced sound: a harmonic series with f0
 *                       drifting between f0_lo and f0_hi, harmonics up to
 *                       4 kHz at -6 dB/octave, a slow amplitude wobble that
 *                       never drops more than 6 dB, and a little coherent
 *                       breath noise; peak 0.5
 *   g16s_speech_like    g16s_voiced times a 4 Hz syllable envelope with short
 *                       silent gaps (about 60 ms in every 250 ms); peak 0.5
 *   g16s_bandnoise      white noise band-limited to lo..hi Hz; RMS 0.1
 *   g16s_impulse        a single sample
 *   g16s_sine           a sine
 *   g16s_frac_delay     delays a signal by a fractional number of samples
 *                       with a 129-tap Kaiser (beta 8) windowed sinc, which
 *                       is independent of the engine's 33-tap filter
 *   g16s_render_plane   a far-field plane wave arriving from (az, el) at a
 *                       mic array, written interleaved; _add accumulates
 *   g16s_make_cal       a verified calibration for a test geometry
 *
 * Coordinates follow g16mic.h. The plane-wave renderer gives mic i the source
 * delayed by G16S_DBIG - ((r_i - centroid) . u) * rate / c samples, so a mic
 * nearer the source hears it earlier.
 */
#ifndef G16MIC_TEST_SIGNALS_H
#define G16MIC_TEST_SIGNALS_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define G16S_DBIG 64          /* plane-wave renderer's bulk delay, samples */
#define G16S_LONG_HALF 64     /* 129-tap filter: taps -64..64 */

/* Test geometries (metres). */
static const float G16S_GEOM_A[2][3] = { { -0.05f, 0.0f, 0.0f }, { 0.05f, 0.0f, 0.0f } };
static const float G16S_GEOM_B[4][3] = {
	{ -0.15f, 0.0f, 0.0f }, { -0.05f, 0.0f, 0.0f }, { 0.05f, 0.0f, 0.0f }, { 0.15f, 0.0f, 0.0f },
};
static const float G16S_GEOM_C[4][3] = {
	{ -0.12f, 0.0f, 0.0f }, { 0.12f, 0.0f, 0.0f }, { 0.0f, -0.04f, 0.0f }, { 0.0f, 0.04f, 0.0f },
};

static inline uint32_t g16s_seed(uint32_t s)
{
	/* splitmix-style scramble so small seeds give unrelated streams */
	s += 0x9e3779b9u;
	s ^= s >> 16;
	s *= 0x85ebca6bu;
	s ^= s >> 13;
	s *= 0xc2b2ae35u;
	s ^= s >> 16;
	return s ? s : 1u;
}

static inline float g16s_urand(uint32_t *st)
{
	uint32_t x = *st;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*st = x;
	return (float)(x >> 8) * (1.0f / 8388608.0f) - 1.0f;
}

static inline void g16s_noise(float *buf, size_t n, uint32_t seed, float amp)
{
	uint32_t st = g16s_seed(seed);

	for (size_t i = 0; i < n; i++)
		buf[i] = amp * g16s_urand(&st);
}

static inline void g16s_scale_peak(float *buf, size_t n, float peak)
{
	float m = 0.0f;

	for (size_t i = 0; i < n; i++)
		if (fabsf(buf[i]) > m)
			m = fabsf(buf[i]);
	if (m > 0.0f)
		for (size_t i = 0; i < n; i++)
			buf[i] *= peak / m;
}

static inline void g16s_scale_rms(float *buf, size_t n, float rms)
{
	double acc = 0.0;

	for (size_t i = 0; i < n; i++)
		acc += (double)buf[i] * buf[i];
	if (acc <= 0.0)
		return;
	float g = (float)(rms / sqrt(acc / (double)n));
	for (size_t i = 0; i < n; i++)
		buf[i] *= g;
}

static inline void g16s_voiced(float *buf, size_t n, int rate, uint32_t seed, float f0_lo, float f0_hi)
{
	enum { KMAX = 48 };
	double hph[KMAX + 1];
	uint32_t st = g16s_seed(seed * 2654435761u + 17u);
	double ph0 = M_PI * (double)g16s_urand(&st);
	double am0 = M_PI * (double)g16s_urand(&st);
	double phase = 0.0;
	double mid = 0.5 * (f0_lo + f0_hi), half = 0.5 * (f0_hi - f0_lo);

	for (int k = 1; k <= KMAX; k++)
		hph[k] = M_PI * (double)g16s_urand(&st);
	for (size_t i = 0; i < n; i++) {
		double t = (double)i / rate;
		double f0 = mid + half * sin(2.0 * M_PI * 0.7 * t + ph0);
		double s = 0.0;

		phase += 2.0 * M_PI * f0 / rate;
		if (phase > 2.0 * M_PI * 1e6)
			phase = fmod(phase, 2.0 * M_PI);
		for (int k = 1; k <= KMAX; k++) {
			double fk = k * f0;
			if (fk >= 4000.0)
				break;
			double w = (4000.0 - fk) / 300.0;  /* soft edge at 4 kHz */
			if (w > 1.0)
				w = 1.0;
			s += w * sin(k * phase + hph[k]) / k;
		}
		s *= 0.75 + 0.25 * sin(2.0 * M_PI * 3.0 * t + am0);
		s += 0.03 * g16s_urand(&st);  /* breath noise, part of the source */
		buf[i] = (float)s;
	}
	g16s_scale_peak(buf, n, 0.5f);
}

static inline void g16s_speech_like(float *buf, size_t n, int rate, uint32_t seed, float f0_lo, float f0_hi)
{
	const double period = 0.25, voiced = 0.19, edge = 0.02;
	uint32_t st = g16s_seed(seed + 99u);
	double off = period * 0.5 * (1.0 + (double)g16s_urand(&st));

	g16s_voiced(buf, n, rate, seed, f0_lo, f0_hi);
	for (size_t i = 0; i < n; i++) {
		double t = fmod((double)i / rate + off, period);
		double e;
		if (t >= voiced)
			e = 0.0;
		else if (t < edge)
			e = 0.5 - 0.5 * cos(M_PI * t / edge);
		else if (t > voiced - edge)
			e = 0.5 - 0.5 * cos(M_PI * (voiced - t) / edge);
		else
			e = 1.0;
		buf[i] = (float)(buf[i] * e);
	}
}

/* One RBJ biquad section, run in place. hp: 1 high-pass, 0 low-pass. */
static inline void g16s_biquad(float *buf, size_t n, int rate, double hz, int hp)
{
	double w0 = 2.0 * M_PI * hz / rate, cs = cos(w0), al = sin(w0) / (2.0 * 0.70710678118654752);
	double a0 = 1.0 + al, b0, b1, b2, a1 = -2.0 * cs / a0, a2 = (1.0 - al) / a0;
	double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

	if (hp) {
		b0 = (1.0 + cs) / 2.0 / a0;
		b1 = -(1.0 + cs) / a0;
	} else {
		b0 = (1.0 - cs) / 2.0 / a0;
		b1 = (1.0 - cs) / a0;
	}
	b2 = b0;
	for (size_t i = 0; i < n; i++) {
		double x = buf[i];
		double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
		x2 = x1;
		x1 = x;
		y2 = y1;
		y1 = y;
		buf[i] = (float)y;
	}
}

static inline void g16s_bandnoise(float *buf, size_t n, int rate, uint32_t seed, float lo, float hi)
{
	g16s_noise(buf, n, seed, 1.0f);
	if (lo > 0.0f) {
		g16s_biquad(buf, n, rate, lo, 1);
		g16s_biquad(buf, n, rate, lo, 1);
	}
	if (hi > 0.0f && hi < 0.5f * rate) {
		g16s_biquad(buf, n, rate, hi, 0);
		g16s_biquad(buf, n, rate, hi, 0);
	}
	g16s_scale_rms(buf, n, 0.1f);
}

static inline void g16s_impulse(float *buf, size_t n, size_t at, float amp)
{
	memset(buf, 0, n * sizeof *buf);
	if (at < n)
		buf[at] = amp;
}

static inline void g16s_sine(float *buf, size_t n, int rate, float hz, float amp)
{
	for (size_t i = 0; i < n; i++)
		buf[i] = amp * (float)sin(2.0 * M_PI * hz * (double)i / rate);
}

static inline double g16s_bessel_i0(double x)
{
	double sum = 1.0, term = 1.0, q = x * x / 4.0;

	for (int k = 1; k < 60; k++) {
		term *= q / ((double)k * k);
		sum += term;
		if (term < sum * 1e-16)
			break;
	}
	return sum;
}

/* out[t] = src[t - d] (fractional d >= 0 or < 0), zero outside src. */
static inline void g16s_frac_delay_add(const float *src, size_t n, double d, float *out, size_t stride)
{
	double h[2 * G16S_LONG_HALF + 1], sum = 0.0;
	double di = floor(d), f = d - di;
	const double beta = 8.0, i0b = g16s_bessel_i0(beta);
	long D = (long)di;

	for (int m = -G16S_LONG_HALF; m <= G16S_LONG_HALF; m++) {
		double x = (double)m - f;
		double s = fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
		double r = x / (G16S_LONG_HALF + 1.0);
		double w = g16s_bessel_i0(beta * sqrt(fmax(0.0, 1.0 - r * r))) / i0b;
		h[m + G16S_LONG_HALF] = s * w;
		sum += h[m + G16S_LONG_HALF];
	}
	for (int m = 0; m <= 2 * G16S_LONG_HALF; m++)
		h[m] /= sum;
	for (size_t t = 0; t < n; t++) {
		double acc = 0.0;
		for (int m = -G16S_LONG_HALF; m <= G16S_LONG_HALF; m++) {
			long idx = (long)t - D - m;
			if (idx >= 0 && (size_t)idx < n)
				acc += h[m + G16S_LONG_HALF] * src[idx];
		}
		out[t * stride] += (float)acc;
	}
}

static inline void g16s_frac_delay(const float *src, size_t n, double d, float *out)
{
	memset(out, 0, n * sizeof *out);
	g16s_frac_delay_add(src, n, d, out, 1);
}

/* Per-mic arrival delay of a plane wave, samples (G16S_DBIG - proj*rate/c). */
static inline double g16s_arrival_delay(const float pos[][3], int mics, int i, float az, float el, int rate)
{
	double c[3] = { 0, 0, 0 };
	double a = az * M_PI / 180.0, e = el * M_PI / 180.0;
	double u[3] = { sin(a) * cos(e), cos(a) * cos(e), sin(e) };

	for (int k = 0; k < mics; k++)
		for (int d = 0; d < 3; d++)
			c[d] += pos[k][d] / mics;
	double proj = 0.0;
	for (int d = 0; d < 3; d++)
		proj += (pos[i][d] - c[d]) * u[d];
	return G16S_DBIG - proj * rate / G16MIC_SPEED_OF_SOUND;
}

static inline void g16s_render_plane_add(const float *src, size_t n, const float pos[][3], int mics, float az, float el,
					 int rate, float *out_interleaved, int stream_channels)
{
	for (int i = 0; i < mics && i < stream_channels; i++)
		g16s_frac_delay_add(src, n, g16s_arrival_delay(pos, mics, i, az, el, rate),
				    out_interleaved + i, (size_t)stream_channels);
}

static inline void g16s_render_plane(const float *src, size_t n, const float pos[][3], int mics, float az, float el,
				     int rate, float *out_interleaved, int stream_channels)
{
	memset(out_interleaved, 0, n * (size_t)stream_channels * sizeof(float));
	g16s_render_plane_add(src, n, pos, mics, az, el, rate, out_interleaved, stream_channels);
}

/* Independent band noise on every channel (a diffuse field), RMS `rms`. */
static inline void g16s_add_diffuse(float *out_interleaved, size_t n, int channels, int rate, uint32_t seed, float rms)
{
	float *tmp = malloc(n * sizeof *tmp);

	if (!tmp)
		abort();
	for (int c = 0; c < channels; c++) {
		g16s_bandnoise(tmp, n, rate, seed + 7919u * (uint32_t)c, 100.0f, 8000.0f);
		for (size_t i = 0; i < n; i++)
			out_interleaved[i * channels + c] += tmp[i] * (rms / 0.1f);
	}
	free(tmp);
}

static inline void g16s_make_cal(g16mic_calib *cal, const float pos[][3], int n, float hpf_hz, int dc_block)
{
	g16mic_calib_identity(cal, n);
	for (int i = 0; i < n; i++)
		for (int d = 0; d < 3; d++)
			cal->pos[i][d] = pos[i][d];
	cal->have_pos = 1;
	cal->verified = 1;
	cal->hpf_hz = hpf_hz;
	cal->dc_block = dc_block;
	snprintf(cal->measured, sizeof cal->measured, "%s", "2026-01-01");
	snprintf(cal->kernel, sizeof cal->kernel, "%s", "7.2");
	snprintf(cal->layout, sizeof cal->layout, "test/%dch", n);
}

static inline void g16s_deinterleave(const float *in, size_t frames, int channels, int ch, float *out)
{
	for (size_t i = 0; i < frames; i++)
		out[i] = in[i * channels + ch];
}

static inline double g16s_energy(const float *x, size_t n)
{
	double acc = 0.0;

	for (size_t i = 0; i < n; i++)
		acc += (double)x[i] * x[i];
	return acc;
}

static inline void *g16s_xcalloc(size_t n, size_t sz)
{
	void *p = calloc(n ? n : 1, sz);

	if (!p) {
		fprintf(stderr, "out of memory\n");
		abort();
	}
	return p;
}

#endif /* G16MIC_TEST_SIGNALS_H */
