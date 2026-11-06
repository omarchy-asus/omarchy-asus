/* SPDX-License-Identifier: MIT */
/* track.c: the talker-direction tracker behind the `track` mode.
 *
 * Per block (G16MIC_BLOCK frames of every mic, already gain/delay aligned):
 *
 *  1. Energy VAD. Block energy against a noise floor that falls at once to a
 *     quieter block and rises 3 dB/s; active when it is vad_threshold_db
 *     above the floor and above -65 dBFS.
 *  2. GCC-PHAT for every mic pair over the last 2 * G16MIC_BLOCK frames
 *     (Hann window, 1024-point FFT, zero padded). The phase transform keeps
 *     only the phase of the cross-spectrum; bins outside 100 Hz..8 kHz are
 *     left out (with a taper above 6 kHz), and the whitened cross-spectrum is
 *     smoothed over about two blocks. Each pair's correlation is normalised
 *     so that a perfectly coherent pair peaks at 1. The lag search is limited
 *     to the pair's distance plus 2 samples.
 *  3. SRP-PHAT direction search on a 1 degree azimuth grid at elevation 0:
 *     the score of a direction is the mean, over pairs, of the correlation at
 *     the lag that direction predicts (Catmull-Rom interpolation). A planar
 *     array searches the full circle. A linear array (or two mics) cannot
 *     tell a direction from its mirror image across the array axis, so it
 *     searches the half plane on the user's side of the axis only.
 *  4. Confidence: the winning score over the best score more than 20 degrees
 *     away plus a coherence floor of 0.1 (capped at 10). The floor keeps the
 *     ratio low for incoherent sound (diffuse noise, many talkers), whose
 *     peaks are all small.
 *  5. State machine: a block is a candidate when active and confidence >=
 *     track_conf_enter. Three consecutive consistent candidates (within
 *     track_hysteresis_deg of each other) lock, or move the target; while
 *     locked a new target is taken only when it is more than the hysteresis
 *     away from the current one. The steering direction moves toward the
 *     target by at most track_max_slew_deg_s. In pauses (not active) target
 *     and steering hold. It falls back (the engine then uses the calibrated
 *     omni signal) when active blocks stay below track_conf_exit for
 *     track_unsure_ms, or no candidate came for track_hold_ms, and relocks
 *     after three consistent candidates.
 *
 * All buffers and FFTW plans are made in g16mic_tracker_create (planning is
 * not thread safe, so it is serialised); g16mic_tracker_update only runs the
 * precomputed plans on preallocated arrays.
 */
#include <fftw3.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define TR_WIN (2 * G16MIC_BLOCK)
#define TR_FFT 1024
#define TR_BINS (TR_FFT / 2 + 1)
#define TR_MAXPAIRS (G16MIC_MAX_CH * (G16MIC_MAX_CH - 1) / 2)
#define TR_LAG_CAP 400
#define TR_SMOOTH 0.5f
#define TR_COH_FLOOR 0.1f
#define TR_EXCL_DEG 20.0f
#define TR_CONF_CAP 10.0f
#define TR_RUN 3
#define TR_VAD_ABS_DB (-65.0f)
#define TR_FLOOR_INIT_DB (-60.0f)
#define TR_FLOOR_RISE_DB_S 3.0f
#define TR_F_LO 100.0
#define TR_F_FLAT 6000.0
#define TR_F_HI 8000.0

static pthread_mutex_t plan_lock = PTHREAD_MUTEX_INITIALIZER;

struct g16mic_tracker {
	int n, rate, npairs, naz, full_circle;
	g16mic_params p;
	float pos[G16MIC_MAX_CH][3];
	int pi[TR_MAXPAIRS], pj[TR_MAXPAIRS], maxlag[TR_MAXPAIRS], lagmax_all;
	float *hist[G16MIC_MAX_CH];
	float *win, *weight, *fin, *corr;
	fftwf_complex *spec[G16MIC_MAX_CH], *cross, *smooth[TR_MAXPAIRS];
	float *gcc[TR_MAXPAIRS];
	float *az, *lagtab, *score;
	float wnorm;
	fftwf_plan r2c, c2r;

	/* state */
	int have_floor;
	float floor_db;
	int locked, fallback, vad;
	float target, steer, doa, conf;
	int run_n;
	float run_ref, run_acc;
	int unsure, since_conf;
	int unsure_lim, hold_lim;
	float max_step, rise_db;
};

static float wrap180(float a)
{
	return (float)remainder((double)a, 360.0);
}

static float angdiff(float a, float b)
{
	return wrap180(a - b);
}

void g16mic_tracker_destroy(g16mic_tracker *t)
{
	if (!t)
		return;
	pthread_mutex_lock(&plan_lock);
	if (t->r2c)
		fftwf_destroy_plan(t->r2c);
	if (t->c2r)
		fftwf_destroy_plan(t->c2r);
	pthread_mutex_unlock(&plan_lock);
	for (int i = 0; i < G16MIC_MAX_CH; i++) {
		fftwf_free(t->hist[i]);
		fftwf_free(t->spec[i]);
	}
	for (int k = 0; k < TR_MAXPAIRS; k++) {
		fftwf_free(t->smooth[k]);
		fftwf_free(t->gcc[k]);
	}
	fftwf_free(t->win);
	fftwf_free(t->weight);
	fftwf_free(t->fin);
	fftwf_free(t->corr);
	fftwf_free(t->cross);
	fftwf_free(t->az);
	fftwf_free(t->lagtab);
	fftwf_free(t->score);
	free(t);
}

static void *zalloc(size_t bytes)
{
	void *p = fftwf_malloc(bytes ? bytes : 1);

	if (p)
		memset(p, 0, bytes ? bytes : 1);
	return p;
}

/* 1 when every mic lies on one line (within 0.1 mm); *axis gets its direction. */
static int collinear(const float pos[][3], int n, double axis[3])
{
	int a = 0, b = 1;
	double best = -1.0;

	for (int i = 0; i < n; i++)
		for (int j = i + 1; j < n; j++) {
			double d = 0.0;
			for (int k = 0; k < 3; k++)
				d += ((double)pos[j][k] - pos[i][k]) * ((double)pos[j][k] - pos[i][k]);
			if (d > best) {
				best = d;
				a = i;
				b = j;
			}
		}
	double len = sqrt(best);
	for (int k = 0; k < 3; k++)
		axis[k] = ((double)pos[b][k] - pos[a][k]) / len;
	for (int i = 0; i < n; i++) {
		double w[3], c[3];
		for (int k = 0; k < 3; k++)
			w[k] = (double)pos[i][k] - pos[a][k];
		c[0] = w[1] * axis[2] - w[2] * axis[1];
		c[1] = w[2] * axis[0] - w[0] * axis[2];
		c[2] = w[0] * axis[1] - w[1] * axis[0];
		if (sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]) > 1e-4)
			return 0;
	}
	return 1;
}

g16mic_tracker *g16mic_tracker_create(const float pos[][3], int n, int rate, const g16mic_params *p)
{
	g16mic_tracker *t;

	if (!pos || n < 2 || n > G16MIC_MAX_CH || rate <= 0)
		return NULL;
	for (int i = 0; i < n; i++)
		for (int k = 0; k < 3; k++)
			if (!isfinite(pos[i][k]))
				return NULL;
	t = calloc(1, sizeof *t);
	if (!t)
		return NULL;
	t->n = n;
	t->rate = rate;
	if (p)
		t->p = *p;
	else
		g16mic_params_default(&t->p);
	for (int i = 0; i < n; i++)
		for (int k = 0; k < 3; k++)
			t->pos[i][k] = pos[i][k];

	/* pairs */
	const double kfac = (double)rate / G16MIC_SPEED_OF_SOUND;
	for (int i = 0; i < n; i++)
		for (int j = i + 1; j < n; j++) {
			double d = 0.0;
			for (int k = 0; k < 3; k++)
				d += ((double)pos[j][k] - pos[i][k]) * ((double)pos[j][k] - pos[i][k]);
			d = sqrt(d);
			if (d < 1e-4)
				goto fail;  /* two mics in one place */
			int ml = (int)ceil(d * kfac) + 2;
			if (ml > TR_LAG_CAP)
				ml = TR_LAG_CAP;
			int q = t->npairs++;
			t->pi[q] = i;
			t->pj[q] = j;
			t->maxlag[q] = ml;
			if (ml > t->lagmax_all)
				t->lagmax_all = ml;
		}

	/* search grid */
	double axis[3];
	t->full_circle = !collinear(pos, n, axis);
	double start;
	if (t->full_circle) {
		t->naz = 360;
		start = -179.0;
	} else {
		double axis_az = atan2(axis[0], axis[1]) * 180.0 / M_PI;
		double b = axis_az - 90.0;  /* a broadside direction */
		while (b > 90.0)
			b -= 180.0;
		while (b <= -90.0)
			b += 180.0;
		t->naz = 181;
		start = b - 90.0;
	}

	t->win = zalloc(sizeof(float) * TR_WIN);
	t->weight = zalloc(sizeof(float) * TR_BINS);
	t->fin = zalloc(sizeof(float) * TR_FFT);
	t->corr = zalloc(sizeof(float) * TR_FFT);
	t->cross = zalloc(sizeof(fftwf_complex) * TR_BINS);
	t->az = zalloc(sizeof(float) * (size_t)t->naz);
	t->lagtab = zalloc(sizeof(float) * (size_t)t->naz * (size_t)t->npairs);
	t->score = zalloc(sizeof(float) * (size_t)t->naz);
	if (!t->win || !t->weight || !t->fin || !t->corr || !t->cross || !t->az || !t->lagtab || !t->score)
		goto fail;
	for (int i = 0; i < n; i++) {
		t->hist[i] = zalloc(sizeof(float) * TR_WIN);
		t->spec[i] = zalloc(sizeof(fftwf_complex) * TR_BINS);
		if (!t->hist[i] || !t->spec[i])
			goto fail;
	}
	for (int q = 0; q < t->npairs; q++) {
		t->smooth[q] = zalloc(sizeof(fftwf_complex) * TR_BINS);
		t->gcc[q] = zalloc(sizeof(float) * (size_t)(2 * t->maxlag[q] + 1));
		if (!t->smooth[q] || !t->gcc[q])
			goto fail;
	}

	for (int k = 0; k < TR_WIN; k++)
		t->win[k] = (float)(0.5 - 0.5 * cos(2.0 * M_PI * k / TR_WIN));
	double wsum = 0.0;
	for (int k = 1; k < TR_BINS - 1; k++) {
		double f = (double)k * rate / TR_FFT, w;
		if (f < TR_F_LO || f >= TR_F_HI)
			w = 0.0;
		else if (f <= TR_F_FLAT)
			w = 1.0;
		else {
			double c = cos(0.5 * M_PI * (f - TR_F_FLAT) / (TR_F_HI - TR_F_FLAT));
			w = c * c;
		}
		t->weight[k] = (float)w;
		wsum += w;
	}
	t->wnorm = (float)(2.0 * wsum);
	if (!(t->wnorm > 0.0f))
		goto fail;

	for (int a = 0; a < t->naz; a++) {
		double az = start + a;
		double r = az * M_PI / 180.0, u[3] = { sin(r), cos(r), 0.0 };
		t->az[a] = wrap180((float)az);
		for (int q = 0; q < t->npairs; q++) {
			double proj = 0.0;
			for (int k = 0; k < 3; k++)
				proj += ((double)pos[t->pi[q]][k] - pos[t->pj[q]][k]) * u[k];
			t->lagtab[(size_t)a * t->npairs + q] = (float)(proj * kfac);  /* lag of mic j behind mic i */
		}
	}

	pthread_mutex_lock(&plan_lock);
	t->r2c = fftwf_plan_dft_r2c_1d(TR_FFT, t->fin, t->spec[0], FFTW_ESTIMATE);
	t->c2r = fftwf_plan_dft_c2r_1d(TR_FFT, t->cross, t->corr, FFTW_ESTIMATE);
	pthread_mutex_unlock(&plan_lock);
	if (!t->r2c || !t->c2r)
		goto fail;
	memset(t->fin, 0, sizeof(float) * TR_FFT);
	memset(t->spec[0], 0, sizeof(fftwf_complex) * TR_BINS);

	t->unsure_lim = (int)ceil(t->p.track_unsure_ms * 1e-3 * rate / G16MIC_BLOCK);
	t->hold_lim = (int)ceil(t->p.track_hold_ms * 1e-3 * rate / G16MIC_BLOCK);
	if (t->unsure_lim < 1)
		t->unsure_lim = 1;
	if (t->hold_lim < 1)
		t->hold_lim = 1;
	t->max_step = t->p.track_max_slew_deg_s * (float)G16MIC_BLOCK / (float)rate;
	if (!(t->max_step >= 0.0f))
		t->max_step = 0.0f;
	t->rise_db = TR_FLOOR_RISE_DB_S * (float)G16MIC_BLOCK / (float)rate;
	return t;

fail:
	g16mic_tracker_destroy(t);
	return NULL;
}

static void spectrum(g16mic_tracker *t, const float *x, fftwf_complex *out)
{
	for (int k = 0; k < TR_WIN; k++)
		t->fin[k] = x[k] * t->win[k];
	memset(t->fin + TR_WIN, 0, sizeof(float) * (TR_FFT - TR_WIN));
	fftwf_execute_dft_r2c(t->r2c, t->fin, out);
}

/* Weighted, whitened cross-spectrum conj(A) * B into t->corr (lag of B
 * behind A). sm, when given, is smoothed in place and used instead. */
static void pair_corr(g16mic_tracker *t, fftwf_complex *A, fftwf_complex *B, fftwf_complex *sm)
{
	for (int k = 0; k < TR_BINS; k++) {
		float re = A[k][0] * B[k][0] + A[k][1] * B[k][1];
		float im = A[k][0] * B[k][1] - A[k][1] * B[k][0];
		float mag = sqrtf(re * re + im * im);
		float cr = 0.0f, ci = 0.0f;
		if (mag > 1e-30f && isfinite(mag)) {
			cr = re / mag;
			ci = im / mag;
		}
		if (sm) {
			sm[k][0] += TR_SMOOTH * (cr - sm[k][0]);
			sm[k][1] += TR_SMOOTH * (ci - sm[k][1]);
			cr = sm[k][0];
			ci = sm[k][1];
		}
		t->cross[k][0] = cr * t->weight[k];
		t->cross[k][1] = ci * t->weight[k];
	}
	fftwf_execute_dft_c2r(t->c2r, t->cross, t->corr);
}

static float corr_at(const g16mic_tracker *t, int lag)
{
	return t->corr[(lag + TR_FFT) % TR_FFT] / t->wnorm;
}

/* Catmull-Rom interpolation of a pair's stored correlation at a fractional lag. */
static float interp(const float *g, int maxlag, float lag)
{
	float lim = (float)(maxlag - 2);
	if (lag > lim)
		lag = lim;
	if (lag < -lim)
		lag = -lim;
	float x = lag + (float)maxlag;
	int i = (int)floorf(x);
	float f = x - (float)i;
	int top = 2 * maxlag;
	int i0 = i - 1 < 0 ? 0 : i - 1, i2 = i + 1 > top ? top : i + 1, i3 = i + 2 > top ? top : i + 2;
	float p0 = g[i0], p1 = g[i], p2 = g[i2], p3 = g[i3];
	return p1 + 0.5f * f * (p2 - p0 + f * (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3 + f * (3.0f * (p1 - p2) + p3 - p0)));
}

float g16mic_gcc_phat_tdoa(g16mic_tracker *t, const float *a, const float *b, float *peak_ratio)
{
	if (peak_ratio)
		*peak_ratio = 0.0f;
	if (!t || !a || !b)
		return 0.0f;
	spectrum(t, a, t->spec[0]);
	spectrum(t, b, t->spec[1]);
	pair_corr(t, t->spec[0], t->spec[1], NULL);

	int L = t->lagmax_all, best = 0;
	float bv = -INFINITY;
	for (int l = -L; l <= L; l++) {
		float v = corr_at(t, l);
		if (v > bv) {
			bv = v;
			best = l;
		}
	}
	float d = 0.0f;
	if (best > -L && best < L) {
		float ym = corr_at(t, best - 1), y0 = bv, yp = corr_at(t, best + 1);
		float den = ym - 2.0f * y0 + yp;
		if (den < 0.0f)
			d = 0.5f * (ym - yp) / den;
		if (d > 0.5f)
			d = 0.5f;
		if (d < -0.5f)
			d = -0.5f;
	}
	if (peak_ratio) {
		float second = 0.0f;
		for (int l = -L + 1; l < L; l++) {
			if (abs(l - best) <= 2)
				continue;
			float v = corr_at(t, l);
			if (v > corr_at(t, l - 1) && v >= corr_at(t, l + 1) && v > second)
				second = v;
		}
		float r = bv <= 0.0f ? 0.0f : (second > 1e-6f ? bv / second : TR_CONF_CAP);
		*peak_ratio = r > TR_CONF_CAP ? TR_CONF_CAP : r;
	}
	return (float)best + d;
}

void g16mic_tracker_update(g16mic_tracker *t, const float *const *chan, g16mic_track_out *out)
{
	if (!t || !chan)
		return;

	/* 1. history and energy */
	double energy = 0.0;
	for (int i = 0; i < t->n; i++) {
		float *h = t->hist[i];
		memmove(h, h + G16MIC_BLOCK, sizeof(float) * (TR_WIN - G16MIC_BLOCK));
		for (int k = 0; k < G16MIC_BLOCK; k++) {
			float v = chan[i] ? chan[i][k] : 0.0f;
			if (!isfinite(v))
				v = 0.0f;
			h[TR_WIN - G16MIC_BLOCK + k] = v;
			energy += (double)v * v;
		}
	}
	float edb = (float)(10.0 * log10(energy / ((double)t->n * G16MIC_BLOCK) + 1e-15));
	if (!t->have_floor) {
		t->floor_db = edb < TR_FLOOR_INIT_DB ? edb : TR_FLOOR_INIT_DB;
		t->have_floor = 1;
	}
	t->vad = edb > t->floor_db + t->p.vad_threshold_db && edb > TR_VAD_ABS_DB;
	if (edb < t->floor_db)
		t->floor_db = edb;
	else
		t->floor_db += t->rise_db;

	/* 2. GCC-PHAT per pair */
	for (int i = 0; i < t->n; i++)
		spectrum(t, t->hist[i], t->spec[i]);
	for (int q = 0; q < t->npairs; q++) {
		pair_corr(t, t->spec[t->pi[q]], t->spec[t->pj[q]], t->smooth[q]);
		int ml = t->maxlag[q];
		for (int l = -ml; l <= ml; l++)
			t->gcc[q][l + ml] = corr_at(t, l);
	}

	/* 3. SRP-PHAT */
	int best = 0;
	for (int a = 0; a < t->naz; a++) {
		const float *lt = t->lagtab + (size_t)a * t->npairs;
		float s = 0.0f;
		for (int q = 0; q < t->npairs; q++)
			s += interp(t->gcc[q], t->maxlag[q], lt[q]);
		s /= (float)t->npairs;
		t->score[a] = s;
		if (s > t->score[best])
			best = a;
	}

	/* 4. confidence */
	float bs = t->score[best], second = -INFINITY;
	for (int a = 0; a < t->naz; a++)
		if (fabsf(angdiff(t->az[a], t->az[best])) > TR_EXCL_DEG && t->score[a] > second)
			second = t->score[a];
	float conf;
	if (!(bs > 0.0f))
		conf = 0.0f;
	else if (second == -INFINITY)
		conf = 1.0f;
	else
		conf = bs / ((second > 0.0f ? second : 0.0f) + TR_COH_FLOOR);
	if (!(conf <= TR_CONF_CAP))
		conf = conf > TR_CONF_CAP ? TR_CONF_CAP : 0.0f;  /* also catches NaN */
	t->conf = conf;
	if (t->vad)
		t->doa = t->az[best];

	/* 5. state machine */
	const float hyst = t->p.track_hysteresis_deg;
	int cand = t->vad && conf >= t->p.track_conf_enter;
	if (t->vad) {
		if (conf < t->p.track_conf_exit) {
			if (t->unsure < INT_MAX)
				t->unsure++;
		} else {
			t->unsure = 0;
		}
	}
	if (cand)
		t->since_conf = 0;
	else if (t->since_conf < INT_MAX)
		t->since_conf++;

	int steering = t->locked && !t->fallback;
	if (cand) {
		float c = t->az[best];
		if (steering && fabsf(angdiff(c, t->target)) <= hyst) {
			t->run_n = 0;  /* agrees with the current target */
		} else {
			float mean = wrap180(t->run_ref + (t->run_n > 0 ? t->run_acc / (float)t->run_n : 0.0f));
			if (t->run_n > 0 && fabsf(angdiff(c, mean)) <= hyst) {
				t->run_acc += angdiff(c, t->run_ref);
				t->run_n++;
			} else {
				t->run_ref = c;
				t->run_acc = 0.0f;
				t->run_n = 1;
			}
			if (t->run_n >= TR_RUN) {
				float nt = wrap180(t->run_ref + t->run_acc / (float)t->run_n);
				t->run_n = 0;
				if (!steering) {
					t->locked = 1;
					t->fallback = 0;
					t->unsure = 0;
					t->target = nt;
					t->steer = nt;  /* the engine crossfades in from omni */
				} else {
					t->target = nt;
				}
			}
		}
	} else if (t->vad) {
		t->run_n = 0;  /* consecutive candidates only */
	}

	steering = t->locked && !t->fallback;
	if (steering && (t->unsure >= t->unsure_lim || t->since_conf >= t->hold_lim)) {
		t->fallback = 1;
		t->locked = 0;
		t->run_n = 0;
	} else if (steering && t->vad) {
		float d = angdiff(t->target, t->steer);
		if (d > t->max_step)
			d = t->max_step;
		if (d < -t->max_step)
			d = -t->max_step;
		t->steer = wrap180(t->steer + d);
	}

	if (out) {
		out->doa_az_deg = t->doa;
		out->confidence = t->conf;
		out->vad = t->vad;
		out->steer_az_deg = t->steer;
		out->locked = t->locked && !t->fallback;
		out->fallback = t->fallback;
	}
}
