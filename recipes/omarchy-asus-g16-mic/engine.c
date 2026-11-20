/* SPDX-License-Identifier: MIT */
/* engine.c: the processing engine behind every g16-mic mode.
 *
 * Any callback size in, the same output out. Input frames are re-chunked
 * into G16MIC_BLOCK-frame blocks through a FIFO; each block is processed
 * into output FIFOs that were pre-filled with exactly one block of zeros.
 * Output frame n is therefore processed input frame n - L for any chunking,
 * with L = G16MIC_BLOCK + H + C + G16MIC_FD_CENTER fixed for the engine's
 * life and the same in every mode:
 *   H  ceil(Rmax * rate / c) + 1 when the spatial modes are available
 *      (Rmax: largest mic distance from the array centroid), else 0
 *   C  ceil(largest calibration delay) when omni uses the calibration, else 0
 *
 * raw_out is the input delayed by L, bit for bit, all channels, in every mode.
 *
 * The calibrated path maps each mic to its stream channel, applies gain and
 * polarity, an optional DC blocker and 2nd-order Butterworth high-pass, and
 * replaces non-finite samples with 0 (counted). Mic i then goes through a
 * delay line of H + C - cal_delay_i + steer_i samples (integer part by
 * indexing, fractional part by the 33-tap filter). steer_i is 0 for omni and
 * the far-field steering delay for beam and track, so omni and beam share one
 * group delay and every crossfade between them is time aligned.
 *
 * Modes:
 *   raw    mono is stream channel map[0] delayed by L, bit-exact; no limiter
 *   omni   mean of the aligned calibrated mics, then the output limiter
 *   beam   delay-and-sum toward (steer_az_deg, steer_el_deg), unity gain on
 *          target, then the output limiter
 *   track  the tracker (track.c) runs on the aligned mics; while it is
 *          locked the output is delay-and-sum toward its steering direction,
 *          otherwise the omni signal. A steering change between blocks is a
 *          linear crossfade across the block from the old to the new delays.
 *
 * Mode changes (requests, and track falling back or relocking) take effect at
 * a block boundary with an equal-gain linear crossfade over xfade_ms, both
 * sides computed from the same aligned input. The limiter is the only level
 * stage: its gain is exactly 1 while |x| <= ceiling; above, it attacks at
 * once and releases over limiter_release_ms. There is no gate, expander or
 * AGC, so nothing ever silences speech.
 *
 * Real-time: process() and flush() neither allocate, lock nor do I/O.
 * Requests and statistics cross threads through atomics.
 */
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "g16mic.h"

/* dsp.c */
void g16mic__biquad_hpf(float hz, int rate, float coef[5]);
void g16mic__fd_run(const float *x, int dint, const float *taps, size_t frames, float *out, int accumulate);

#define EN_SLICE 8192           /* largest piece processed at once */
#define EN_MAX_CALL 16384       /* FIFO sizing (larger calls are sliced) */
#define EN_DC_HZ 5.0

enum { GEN_RAW = 0, GEN_OMNI, GEN_BEAM };

typedef struct {
	int kind;
	float az, el;
} gen_t;

typedef struct {
	int dint[G16MIC_MAX_CH];
	float taps[G16MIC_MAX_CH][G16MIC_FD_TAPS];
} delayset;

struct g16mic_engine {
	int C, M, rate;
	g16mic_params p;

	/* calibrated path */
	int map[G16MIC_MAX_CH];
	float gain[G16MIC_MAX_CH];
	int dc_on, hpf_on;
	float dc_R, hpf[5];
	float dc_x1[G16MIC_MAX_CH], dc_y1[G16MIC_MAX_CH];
	float hz1[G16MIC_MAX_CH], hz2[G16MIC_MAX_CH];
	float base[G16MIC_MAX_CH];
	float pos[G16MIC_MAX_CH][3];
	int omni_cal, spatial_ok;
	g16mic_cal_status spatial_reason;
	int H, Cd, P, DMAX;
	size_t L, HLc;

	delayset omni_ds;
	delayset beam_ds[2];

	/* buffers, all allocated in create */
	g16mic_fifo fin, fraw, fmono;
	float *blk_in, *blk_raw, *rawhist, *rawmono, *zeros;
	float *calhist[G16MIC_MAX_CH];
	float *aligned[G16MIC_MAX_CH];
	const float *aligned_c[G16MIC_MAX_CH];
	float *y_cur, *y_prev;
	g16mic_tracker *tr;

	/* real-time state */
	_Atomic int req;
	gen_t cur, prev;
	int cur_slot, prev_slot, fading;
	size_t fpos, flen, xfade_frames;
	float lim_g, lim_rel, lim_ceiling;
	int last_fb;
	int flushing;
	size_t flush_left;

	/* statistics */
	_Atomic uint64_t frames_in, frames_out, blocks, fallbacks, mode_switches, refused, nonfinite, limiter_blocks;
	_Atomic int st_mode_req, st_mode_active, st_degraded, st_vad;
	_Atomic float st_conf, st_doa, st_steer;
};

#define RLX memory_order_relaxed

static void delayset_make(const g16mic_engine *e, int steer, float az, float el, delayset *ds)
{
	float st[G16MIC_MAX_CH] = { 0 };

	if (steer)
		g16mic_steering_delays((const float (*)[3])e->pos, e->M, az, el, e->rate, st);
	for (int i = 0; i < e->M; i++) {
		float D = e->base[i] + st[i];
		if (!(D >= 0.0f))
			D = 0.0f;
		if (D > (float)e->DMAX)
			D = (float)e->DMAX;
		int di = (int)floorf(D);
		float fr = D - (float)di;
		if (fr >= 1.0f) {
			di++;
			fr = 0.0f;
		}
		ds->dint[i] = di;
		g16mic_fracdelay_taps(fr, ds->taps[i]);
	}
}

static int gen_equal(gen_t a, gen_t b)
{
	if (a.kind != b.kind)
		return 0;
	if (a.kind != GEN_BEAM)
		return 1;
	return a.az == b.az && a.el == b.el;
}

void g16mic_engine_destroy(g16mic_engine *e)
{
	if (!e)
		return;
	g16mic_tracker_destroy(e->tr);
	g16mic_fifo_free(&e->fin);
	g16mic_fifo_free(&e->fraw);
	g16mic_fifo_free(&e->fmono);
	free(e->blk_in);
	free(e->blk_raw);
	free(e->rawhist);
	free(e->rawmono);
	free(e->zeros);
	for (int i = 0; i < G16MIC_MAX_CH; i++) {
		free(e->calhist[i]);
		free(e->aligned[i]);
	}
	free(e->y_cur);
	free(e->y_prev);
	free(e);
}

g16mic_engine *g16mic_engine_create(int stream_channels, int rate, const g16mic_calib *cal, g16mic_cal_status spatial_status,
				    const g16mic_params *p)
{
	g16mic_engine *e;
	g16mic_calib id;
	const g16mic_calib *use;

	if (stream_channels < 1 || stream_channels > G16MIC_MAX_CH || rate != G16MIC_RATE)
		return NULL;
	e = calloc(1, sizeof *e);
	if (!e)
		return NULL;
	if (p)
		e->p = *p;
	else
		g16mic_params_default(&e->p);
	if ((int)e->p.mode < (int)G16MIC_MODE_RAW || (int)e->p.mode > (int)G16MIC_MODE_TRACK)
		goto fail;
	e->C = stream_channels;
	e->rate = rate;

	/* Which calibration the omni path uses. */
	e->omni_cal = g16mic_calib_omni_usable(cal, stream_channels);
	g16mic_calib_identity(&id, stream_channels);
	use = e->omni_cal ? cal : &id;
	e->M = use->channels;
	for (int i = 0; i < e->M; i++) {
		e->map[i] = use->map[i];
		e->gain[i] = powf(10.0f, use->gain_db[i] / 20.0f) * (use->polarity[i] < 0 ? -1.0f : 1.0f);
	}
	e->dc_on = use->dc_block ? 1 : 0;
	e->dc_R = (float)(1.0 - 2.0 * 3.14159265358979323846 * EN_DC_HZ / rate);
	e->hpf_on = isfinite(use->hpf_hz) && use->hpf_hz > 0.0f && use->hpf_hz < 0.45f * rate;
	if (e->hpf_on)
		g16mic__biquad_hpf(use->hpf_hz, rate, e->hpf);

	/* Are the spatial modes available? */
	e->spatial_reason = spatial_status;
	if (spatial_status == G16MIC_CAL_OK) {
		if (!cal)
			e->spatial_reason = G16MIC_CAL_MISSING;
		else if (!e->omni_cal)
			e->spatial_reason = cal->verified ? G16MIC_CAL_RANGE : G16MIC_CAL_UNVERIFIED;
		else if (!cal->have_pos)
			e->spatial_reason = G16MIC_CAL_ZERO_APERTURE;
		else if (e->M < 2 || e->M != stream_channels)
			e->spatial_reason = G16MIC_CAL_CHANNELS;
	}
	double rmax = 0.0;
	if (e->spatial_reason == G16MIC_CAL_OK) {
		double c[3] = { 0, 0, 0 };
		for (int i = 0; i < e->M; i++)
			for (int k = 0; k < 3; k++) {
				e->pos[i][k] = cal->pos[i][k];
				c[k] += cal->pos[i][k] / (double)e->M;
			}
		for (int i = 0; i < e->M; i++) {
			double d = 0.0;
			for (int k = 0; k < 3; k++)
				d += (e->pos[i][k] - c[k]) * (e->pos[i][k] - c[k]);
			d = sqrt(d);
			if (d > rmax)
				rmax = d;
		}
		if (!(rmax > 0.0) || !isfinite(rmax)) {
			e->spatial_reason = G16MIC_CAL_ZERO_APERTURE;
		} else {
			e->tr = g16mic_tracker_create((const float (*)[3])e->pos, e->M, rate, &e->p);
			if (!e->tr)
				e->spatial_reason = G16MIC_CAL_DUP_POSITION;
		}
	}
	e->spatial_ok = e->spatial_reason == G16MIC_CAL_OK;
	if (g16mic_mode_is_spatial(e->p.mode) && !e->spatial_ok)
		goto fail;

	/* Latency and delay lines. */
	e->H = e->spatial_ok ? (int)ceil(rmax * rate / G16MIC_SPEED_OF_SOUND) + 1 : 0;
	float maxcal = 0.0f;
	if (e->omni_cal)
		for (int i = 0; i < e->M; i++)
			if (use->delay_samples[i] > maxcal)
				maxcal = use->delay_samples[i];
	e->Cd = e->omni_cal ? (int)ceilf(maxcal) : 0;
	for (int i = 0; i < e->M; i++)
		e->base[i] = (float)(e->H + e->Cd) - (e->omni_cal ? use->delay_samples[i] : 0.0f);
	e->P = e->H + e->Cd + G16MIC_FD_CENTER;
	e->L = (size_t)G16MIC_BLOCK + (size_t)e->P;
	e->DMAX = 2 * e->H + e->Cd + 1;
	e->HLc = (size_t)G16MIC_BLOCK + (size_t)e->DMAX + G16MIC_FD_TAPS;

	const size_t C = (size_t)e->C, B = G16MIC_BLOCK;
	const size_t outcap = 2 * EN_MAX_CALL + e->L + 2 * B;
	if (g16mic_fifo_init(&e->fin, (EN_SLICE + 2 * B) * C) || g16mic_fifo_init(&e->fraw, outcap * C) ||
	    g16mic_fifo_init(&e->fmono, outcap))
		goto fail;
	e->blk_in = calloc(B * C, sizeof(float));
	e->blk_raw = calloc(B * C, sizeof(float));
	e->rawhist = calloc(((size_t)e->P + B) * C, sizeof(float));
	e->rawmono = calloc(B, sizeof(float));
	e->zeros = calloc(B * C, sizeof(float));
	e->y_cur = calloc(B, sizeof(float));
	e->y_prev = calloc(B, sizeof(float));
	if (!e->blk_in || !e->blk_raw || !e->rawhist || !e->rawmono || !e->zeros || !e->y_cur || !e->y_prev)
		goto fail;
	for (int i = 0; i < e->M; i++) {
		e->calhist[i] = calloc(e->HLc, sizeof(float));
		e->aligned[i] = calloc(B, sizeof(float));
		if (!e->calhist[i] || !e->aligned[i])
			goto fail;
		e->aligned_c[i] = e->aligned[i];
	}
	/* One block of zeros ahead of the first output. */
	if (g16mic_fifo_write(&e->fraw, e->zeros, B * C) != B * C || g16mic_fifo_write(&e->fmono, e->zeros, B) != B)
		goto fail;

	delayset_make(e, 0, 0.0f, 0.0f, &e->omni_ds);

	/* Output stage. */
	e->lim_ceiling = isfinite(e->p.limiter_ceiling) && e->p.limiter_ceiling > 0.0f ? e->p.limiter_ceiling : 0.891f;
	float rel_ms = isfinite(e->p.limiter_release_ms) && e->p.limiter_release_ms > 0.0f ? e->p.limiter_release_ms : 100.0f;
	e->lim_rel = expf(-1000.0f / (rel_ms * (float)rate));
	e->lim_g = 1.0f;
	float xf = isfinite(e->p.xfade_ms) && e->p.xfade_ms > 0.0f ? e->p.xfade_ms : 0.0f;
	e->xfade_frames = (size_t)lrintf(xf * (float)rate / 1000.0f);
	if (e->xfade_frames < 1)
		e->xfade_frames = 1;

	/* Initial mode. */
	atomic_init(&e->req, (int)e->p.mode);
	e->cur.kind = e->p.mode == G16MIC_MODE_RAW ? GEN_RAW : e->p.mode == G16MIC_MODE_BEAM ? GEN_BEAM : GEN_OMNI;
	e->cur.az = e->p.steer_az_deg;
	e->cur.el = e->p.steer_el_deg;
	e->cur_slot = 0;
	if (e->cur.kind == GEN_BEAM)
		delayset_make(e, 1, e->cur.az, e->cur.el, &e->beam_ds[0]);

	atomic_init(&e->frames_in, 0);
	atomic_init(&e->frames_out, 0);
	atomic_init(&e->blocks, 0);
	atomic_init(&e->fallbacks, 0);
	atomic_init(&e->mode_switches, 0);
	atomic_init(&e->refused, 0);
	atomic_init(&e->nonfinite, 0);
	atomic_init(&e->limiter_blocks, 0);
	atomic_init(&e->st_mode_req, (int)e->p.mode);
	atomic_init(&e->st_mode_active, e->cur.kind == GEN_RAW ? G16MIC_MODE_RAW :
					e->cur.kind == GEN_BEAM ? G16MIC_MODE_BEAM : G16MIC_MODE_OMNI);
	atomic_init(&e->st_degraded, 0);
	atomic_init(&e->st_vad, 0);
	atomic_init(&e->st_conf, 0.0f);
	atomic_init(&e->st_doa, 0.0f);
	atomic_init(&e->st_steer, 0.0f);
	return e;

fail:
	g16mic_engine_destroy(e);
	return NULL;
}

size_t g16mic_engine_latency(const g16mic_engine *e)
{
	return e ? e->L : 0;
}

int g16mic_engine_request_mode(g16mic_engine *e, g16mic_mode m)
{
	if (!e)
		return -1;
	if ((int)m < (int)G16MIC_MODE_RAW || (int)m > (int)G16MIC_MODE_TRACK ||
	    (g16mic_mode_is_spatial(m) && !e->spatial_ok)) {
		atomic_fetch_add_explicit(&e->refused, 1, RLX);
		return -1;
	}
	atomic_store_explicit(&e->req, (int)m, memory_order_release);
	atomic_store_explicit(&e->st_mode_req, (int)m, RLX);
	return 0;
}

/* One generator's output for the current block. */
static void gen_block(g16mic_engine *e, gen_t g, int slot, float *y)
{
	const size_t B = G16MIC_BLOCK;
	const float invM = 1.0f / (float)e->M;

	if (g.kind == GEN_RAW) {
		memcpy(y, e->rawmono, B * sizeof(float));
		return;
	}
	if (g.kind == GEN_OMNI) {
		for (size_t n = 0; n < B; n++) {
			float s = 0.0f;
			for (int i = 0; i < e->M; i++)
				s += e->aligned[i][n];
			y[n] = s * invM;
		}
		return;
	}
	const delayset *ds = &e->beam_ds[slot];
	for (int i = 0; i < e->M; i++)
		g16mic__fd_run(e->calhist[i] + e->HLc - B, ds->dint[i], ds->taps[i], B, y, i > 0);
	for (size_t n = 0; n < B; n++)
		y[n] *= invM;
}

static void run_block(g16mic_engine *e)
{
	const size_t B = G16MIC_BLOCK, C = (size_t)e->C;
	uint64_t bad = 0;

	/* raw: a P-frame delay line, bit for bit */
	memcpy(e->rawhist + (size_t)e->P * C, e->blk_in, B * C * sizeof(float));
	memcpy(e->blk_raw, e->rawhist, B * C * sizeof(float));
	for (size_t n = 0; n < B; n++)
		e->rawmono[n] = e->rawhist[n * C + (size_t)e->map[0]];
	memmove(e->rawhist, e->rawhist + B * C, (size_t)e->P * C * sizeof(float));

	/* calibrated path */
	for (int i = 0; i < e->M; i++) {
		float *h = e->calhist[i];
		float *x = h + e->HLc - B;
		memmove(h, h + B, (e->HLc - B) * sizeof(float));
		const size_t ch = (size_t)e->map[i];
		const float g = e->gain[i];
		float x1 = e->dc_x1[i], y1 = e->dc_y1[i], z1 = e->hz1[i], z2 = e->hz2[i];
		for (size_t n = 0; n < B; n++) {
			float s = e->blk_in[n * C + ch];
			if (!isfinite(s)) {
				s = 0.0f;
				bad++;
			}
			s *= g;
			if (e->dc_on) {
				float yv = s - x1 + e->dc_R * y1;
				x1 = s;
				y1 = fabsf(yv) < 1e-30f ? 0.0f : yv;
				s = y1;
			}
			if (e->hpf_on) {
				float yv = e->hpf[0] * s + z1;
				z1 = e->hpf[1] * s - e->hpf[3] * yv + z2;
				z2 = e->hpf[2] * s - e->hpf[4] * yv;
				if (fabsf(z1) < 1e-30f)
					z1 = 0.0f;
				if (fabsf(z2) < 1e-30f)
					z2 = 0.0f;
				s = yv;
			}
			x[n] = s;
		}
		e->dc_x1[i] = x1;
		e->dc_y1[i] = y1;
		e->hz1[i] = z1;
		e->hz2[i] = z2;
		g16mic__fd_run(x, e->omni_ds.dint[i], e->omni_ds.taps[i], B, e->aligned[i], 0);
	}
	if (bad)
		atomic_fetch_add_explicit(&e->nonfinite, bad, RLX);

	/* tracker and the target generator */
	int m = atomic_load_explicit(&e->req, memory_order_acquire);
	g16mic_track_out to = { 0 };
	if (e->tr) {
		g16mic_tracker_update(e->tr, e->aligned_c, &to);
		atomic_store_explicit(&e->st_conf, to.confidence, RLX);
		atomic_store_explicit(&e->st_doa, to.doa_az_deg, RLX);
		atomic_store_explicit(&e->st_steer, to.steer_az_deg, RLX);
		atomic_store_explicit(&e->st_vad, to.vad, RLX);
	}
	gen_t target = { GEN_OMNI, 0.0f, 0.0f };
	int fb = 0;
	switch (m) {
	case G16MIC_MODE_RAW:
		target.kind = GEN_RAW;
		break;
	case G16MIC_MODE_BEAM:
		target.kind = GEN_BEAM;
		target.az = e->p.steer_az_deg;
		target.el = e->p.steer_el_deg;
		break;
	case G16MIC_MODE_TRACK:
		if (to.locked && !to.fallback) {
			target.kind = GEN_BEAM;
			target.az = to.steer_az_deg;
		}
		fb = to.fallback;
		break;
	default:
		break;
	}
	if (fb && !e->last_fb)
		atomic_fetch_add_explicit(&e->fallbacks, 1, RLX);
	e->last_fb = fb;
	atomic_store_explicit(&e->st_degraded, fb, RLX);

	/* Start a transition only when none is running; a later change waits
	 * for the running crossfade to finish. */
	if (!e->fading && !gen_equal(target, e->cur)) {
		gen_t old = e->cur;
		int new_slot = old.kind == GEN_BEAM ? 1 - e->cur_slot : 0;
		e->prev = old;
		e->prev_slot = e->cur_slot;
		e->cur = target;
		e->cur_slot = new_slot;
		if (target.kind == GEN_BEAM)
			delayset_make(e, 1, target.az, target.el, &e->beam_ds[new_slot]);
		if (old.kind == GEN_BEAM && target.kind == GEN_BEAM) {
			e->flen = B;  /* steering moved: crossfade across this block */
		} else {
			e->flen = e->xfade_frames;
			atomic_fetch_add_explicit(&e->mode_switches, 1, RLX);
		}
		e->fpos = 0;
		e->fading = 1;
	}

	/* generators, crossfade */
	int mixed = e->fading;
	gen_block(e, e->cur, e->cur_slot, e->y_cur);
	if (e->fading) {
		gen_block(e, e->prev, e->prev_slot, e->y_prev);
		for (size_t n = 0; n < B; n++) {
			size_t pos = e->fpos + n;
			if (pos >= e->flen)
				continue;
			float w = (float)(pos + 1) / (float)e->flen;
			float a = e->y_prev[n], b = e->y_cur[n];
			if (!isfinite(a))
				a = b;
			if (!isfinite(b))
				b = a;
			e->y_cur[n] = (1.0f - w) * a + w * b;
		}
		e->fpos += B;
		if (e->fpos >= e->flen)
			e->fading = 0;
	}

	/* output limiter (not in plain raw) */
	float *y = e->y_cur;
	if (e->cur.kind == GEN_RAW && !mixed) {
		e->lim_g = 1.0f;
	} else {
		const float ceil_ = e->lim_ceiling, rel = e->lim_rel;
		float g = e->lim_g;
		int limited = 0;
		for (size_t n = 0; n < B; n++) {
			float x = y[n];
			if (!isfinite(x)) {
				x = 0.0f;  /* only reachable when both crossfade sides are bad */
				y[n] = 0.0f;
			}
			float a = fabsf(x);
			float tgt = a > ceil_ ? ceil_ / a : 1.0f;
			if (tgt < g) {
				g = tgt;
			} else if (g < 1.0f) {
				g = 1.0f - (1.0f - g) * rel;
				if (g > tgt)
					g = tgt;
				if (g > 1.0f - 1e-6f)
					g = 1.0f;
			}
			if (g < 1.0f) {
				float v = x * g;
				if (fabsf(v) > ceil_)
					v = copysignf(ceil_, v);
				y[n] = v;
				limited = 1;
			}
		}
		e->lim_g = g;
		if (limited)
			atomic_fetch_add_explicit(&e->limiter_blocks, 1, RLX);
	}

	g16mic_fifo_write(&e->fraw, e->blk_raw, B * C);
	g16mic_fifo_write(&e->fmono, y, B);

	int active = e->cur.kind == GEN_RAW ? G16MIC_MODE_RAW :
		     e->cur.kind == GEN_OMNI ? G16MIC_MODE_OMNI :
		     m == G16MIC_MODE_TRACK ? G16MIC_MODE_TRACK : G16MIC_MODE_BEAM;
	atomic_store_explicit(&e->st_mode_active, active, RLX);
	atomic_fetch_add_explicit(&e->blocks, 1, RLX);
}

/* Up to EN_SLICE frames: in (NULL = silence) -> blocks -> outputs. */
static void run_slice(g16mic_engine *e, const float *in, size_t n, float *raw_out, float *mono_out)
{
	const size_t B = G16MIC_BLOCK, C = (size_t)e->C;

	if (in) {
		g16mic_fifo_write(&e->fin, in, n * C);
	} else {
		for (size_t left = n; left > 0;) {
			size_t k = left < B ? left : B;
			g16mic_fifo_write(&e->fin, e->zeros, k * C);
			left -= k;
		}
	}
	while (g16mic_fifo_fill(&e->fin) >= B * C) {
		g16mic_fifo_read(&e->fin, e->blk_in, B * C);
		run_block(e);
	}
	g16mic_fifo_read(&e->fraw, raw_out, n * C);
	g16mic_fifo_read(&e->fmono, mono_out, n);
}

static void run_frames(g16mic_engine *e, const float *in, size_t frames, float *raw_out, float *mono_out)
{
	const size_t C = (size_t)e->C;

	for (size_t done = 0; done < frames;) {
		size_t n = frames - done < EN_SLICE ? frames - done : EN_SLICE;
		run_slice(e, in ? in + done * C : NULL, n, raw_out ? raw_out + done * C : NULL,
			  mono_out ? mono_out + done : NULL);
		done += n;
	}
	atomic_fetch_add_explicit(&e->frames_out, (uint64_t)frames, RLX);
}

void g16mic_engine_process(g16mic_engine *e, const float *in, size_t frames, float *raw_out, float *mono_out)
{
	if (!e || frames == 0)
		return;
	e->flushing = 0;
	atomic_fetch_add_explicit(&e->frames_in, (uint64_t)frames, RLX);
	run_frames(e, in, frames, raw_out, mono_out);
}

size_t g16mic_engine_flush(g16mic_engine *e, float *raw_out, float *mono_out, size_t max_frames)
{
	if (!e)
		return 0;
	if (!e->flushing) {
		e->flushing = 1;
		e->flush_left = e->L;
	}
	size_t n = max_frames < e->flush_left ? max_frames : e->flush_left;
	if (n == 0)
		return 0;
	run_frames(e, NULL, n, raw_out, mono_out);
	e->flush_left -= n;
	return n;
}

void g16mic_engine_get_stats(const g16mic_engine *e, g16mic_stats *out)
{
	if (!out)
		return;
	memset(out, 0, sizeof *out);
	if (!e)
		return;
	/* The atomics are only read; the casts drop const for C11's generic loads. */
	g16mic_engine *m = (g16mic_engine *)e;
	out->mode_requested = (g16mic_mode)atomic_load_explicit(&m->st_mode_req, RLX);
	out->mode_active = (g16mic_mode)atomic_load_explicit(&m->st_mode_active, RLX);
	out->spatial_available = e->spatial_ok;
	out->spatial_reason = e->spatial_reason;
	out->omni_calibrated = e->omni_cal;
	out->degraded = atomic_load_explicit(&m->st_degraded, RLX);
	out->confidence = atomic_load_explicit(&m->st_conf, RLX);
	out->doa_az_deg = atomic_load_explicit(&m->st_doa, RLX);
	out->steer_az_deg = atomic_load_explicit(&m->st_steer, RLX);
	out->vad_active = atomic_load_explicit(&m->st_vad, RLX);
	out->frames_in = atomic_load_explicit(&m->frames_in, RLX);
	out->frames_out = atomic_load_explicit(&m->frames_out, RLX);
	out->blocks = atomic_load_explicit(&m->blocks, RLX);
	out->fallbacks = atomic_load_explicit(&m->fallbacks, RLX);
	out->mode_switches = atomic_load_explicit(&m->mode_switches, RLX);
	out->refused_switches = atomic_load_explicit(&m->refused, RLX);
	out->nonfinite_samples = atomic_load_explicit(&m->nonfinite, RLX);
	out->limiter_blocks = atomic_load_explicit(&m->limiter_blocks, RLX);
}
