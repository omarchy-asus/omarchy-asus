/* SPDX-License-Identifier: MIT */
/* dsp.c: modes, parameters and the small DSP building blocks of libg16mic.
 *
 *   g16mic_mode_*            mode names and parsing
 *   g16mic_params_default    the defaults documented in g16mic.h
 *   g16mic_steering_delays   far-field alignment delays from the geometry
 *   g16mic_fracdelay_taps    33-tap windowed-sinc fractional delay
 *
 * Internal helpers used by engine.c (declared there with the g16mic__ prefix):
 *   g16mic__biquad_hpf       2nd-order Butterworth high-pass coefficients
 *   g16mic__fd_run           one fractional-delay FIR over a block (RT-safe)
 */
#include <math.h>
#include <stddef.h>
#include <string.h>

#include "g16mic.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

void g16mic__biquad_hpf(float hz, int rate, float coef[5]);
void g16mic__fd_run(const float *x, int dint, const float *taps, size_t frames, float *out, int accumulate);

static const char *const mode_names[] = { "raw", "omni", "beam", "track" };

const char *g16mic_mode_name(g16mic_mode m)
{
	if ((int)m < (int)G16MIC_MODE_RAW || (int)m > (int)G16MIC_MODE_TRACK)
		return "unknown";
	return mode_names[m];
}

int g16mic_mode_parse(const char *s, g16mic_mode *out)
{
	if (!s || !out)
		return -1;
	for (int i = 0; i <= (int)G16MIC_MODE_TRACK; i++) {
		if (strcmp(s, mode_names[i]) == 0) {
			*out = (g16mic_mode)i;
			return 0;
		}
	}
	return -1;
}

int g16mic_mode_is_spatial(g16mic_mode m)
{
	return m == G16MIC_MODE_BEAM || m == G16MIC_MODE_TRACK;
}

void g16mic_params_default(g16mic_params *p)
{
	if (!p)
		return;
	memset(p, 0, sizeof *p);
	p->mode = G16MIC_MODE_OMNI;
	p->steer_az_deg = 0.0f;
	p->steer_el_deg = 0.0f;
	p->xfade_ms = 20.0f;
	p->limiter_ceiling = 0.891f;  /* -1 dBFS */
	p->limiter_release_ms = 100.0f;
	p->track_conf_enter = 2.0f;
	/* Measured in test_track: two equal talkers at -50/+50 deg give a median
	 * peak ratio of 1.44 (2-mic) and 1.45 (4-mic), diffuse noise 0.37-0.60,
	 * a single talker 2.28-6.59. 1.6 sits above the ambiguous cases with
	 * margin and keeps the 2.0 enter threshold for hysteresis. */
	p->track_conf_exit = 1.6f;
	p->track_hysteresis_deg = 10.0f;
	p->track_max_slew_deg_s = 90.0f;
	p->track_hold_ms = 2000.0f;
	p->track_unsure_ms = 200.0f;
	p->vad_threshold_db = 9.0f;
}

void g16mic_steering_delays(const float pos[][3], int n, float az_deg, float el_deg, int rate, float *delay_out)
{
	double cx = 0.0, cy = 0.0, cz = 0.0;

	if (!pos || !delay_out || n <= 0)
		return;
	for (int i = 0; i < n; i++) {
		cx += pos[i][0];
		cy += pos[i][1];
		cz += pos[i][2];
	}
	cx /= n;
	cy /= n;
	cz /= n;

	double az = (double)az_deg * M_PI / 180.0;
	double el = (double)el_deg * M_PI / 180.0;
	double ux = sin(az) * cos(el), uy = cos(az) * cos(el), uz = sin(el);
	double k = (double)rate / (double)G16MIC_SPEED_OF_SOUND;

	for (int i = 0; i < n; i++) {
		double proj = (pos[i][0] - cx) * ux + (pos[i][1] - cy) * uy + (pos[i][2] - cz) * uz;
		delay_out[i] = (float)(proj * k);
	}
}

/* Windowed sinc (Blackman, half-width G16MIC_FD_CENTER + 1) centred on
 * G16MIC_FD_CENTER + frac, normalised to unity gain at DC. frac == 0 gives an
 * exact unit impulse at the centre tap, so integer delays are bit-exact. */
void g16mic_fracdelay_taps(float frac, float taps[G16MIC_FD_TAPS])
{
	double h[G16MIC_FD_TAPS];
	double f, sum = 0.0;
	const double half = (double)G16MIC_FD_CENTER + 1.0;

	if (!taps)
		return;
	if (!isfinite(frac))
		frac = 0.0f;
	f = (double)frac - floor((double)frac);
	if (!(f > 0.0 && f < 1.0)) {
		memset(taps, 0, sizeof(float) * G16MIC_FD_TAPS);
		taps[G16MIC_FD_CENTER] = 1.0f;
		return;
	}
	for (int k = 0; k < G16MIC_FD_TAPS; k++) {
		double t = (double)k - (double)G16MIC_FD_CENTER - f;  /* never 0: f is in (0,1) */
		double s = sin(M_PI * t) / (M_PI * t);
		double w = 0.42 + 0.5 * cos(M_PI * t / half) + 0.08 * cos(2.0 * M_PI * t / half);
		h[k] = s * w;
		sum += h[k];
	}
	for (int k = 0; k < G16MIC_FD_TAPS; k++)
		taps[k] = (float)(h[k] / sum);
}

/* RBJ high-pass, Q = 1/sqrt(2) (Butterworth). coef = b0, b1, b2, a1, a2 (a0 = 1). */
void g16mic__biquad_hpf(float hz, int rate, float coef[5])
{
	double w0 = 2.0 * M_PI * (double)hz / (double)rate;
	double cs = cos(w0), sn = sin(w0);
	double alpha = sn / (2.0 * 0.70710678118654752);
	double a0 = 1.0 + alpha;

	coef[0] = (float)((1.0 + cs) / 2.0 / a0);
	coef[1] = (float)(-(1.0 + cs) / a0);
	coef[2] = coef[0];
	coef[3] = (float)(-2.0 * cs / a0);
	coef[4] = (float)((1.0 - alpha) / a0);
}

/* out[n] (+)= sum_k taps[k] * x[n - dint - k], n = 0..frames-1. x points at
 * the block's first sample inside a history buffer that holds at least
 * dint + G16MIC_FD_TAPS - 1 earlier samples. RT-safe. */
void g16mic__fd_run(const float *x, int dint, const float *taps, size_t frames, float *out, int accumulate)
{
	for (size_t n = 0; n < frames; n++) {
		const float *p = x + (ptrdiff_t)n - dint;
		float s = 0.0f;
		for (int k = 0; k < G16MIC_FD_TAPS; k++)
			s += taps[k] * p[-k];
		out[n] = accumulate ? out[n] + s : s;
	}
}
