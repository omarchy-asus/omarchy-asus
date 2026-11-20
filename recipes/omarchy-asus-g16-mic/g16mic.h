/* SPDX-License-Identifier: MIT */
/* g16mic.h: the shared interface of libg16mic, the processing library behind
 * the `g16-mic` daemon (an opt-in microphone processor for the G16's internal
 * array, hosted on PipeWire).
 *
 * Coordinate convention (calibration files, steering, tracking):
 *   metres; x runs along the lid edge, left to right as seen by the user;
 *   y points toward the user; z points up.
 *   Azimuth is measured in the x-y plane: 0 deg = +y (toward the user),
 *   +90 deg = +x. Elevation is measured up from the x-y plane.
 *   The unit vector toward a source is
 *     u = (sin az cos el, cos az cos el, sin el).
 *
 * Layout id convention: the host describes the stream it captures as
 * "<node.name>/<N>ch" (for example
 * "alsa_input.pci-0000_65_00.6.analog-stereo/2ch"). A calibration file's
 * `layout=` must equal that string exactly before the spatial modes may run.
 *
 * Real-time rules: everything marked RT-safe neither allocates, locks, sleeps
 * nor does I/O. All allocation happens in the *_init / *_create calls.
 */
#ifndef G16MIC_H
#define G16MIC_H

#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include <time.h>

#define G16MIC_MAX_CH 8
#define G16MIC_RATE 48000
#define G16MIC_BLOCK 256            /* internal processing block, frames */
#define G16MIC_FD_TAPS 33           /* fractional-delay FIR taps */
#define G16MIC_FD_CENTER 16         /* FIR group delay, samples */
#define G16MIC_SPEED_OF_SOUND 343.0f

/* ---- rt.c: buffers and queues ------------------------------------------ */

/* Single-thread float FIFO (one owner; no atomics). */
typedef struct { float *buf; size_t cap, r, w, fill; } g16mic_fifo;
int g16mic_fifo_init(g16mic_fifo *f, size_t cap);  /* allocates (not RT); 0 ok, -1 fail */
void g16mic_fifo_free(g16mic_fifo *f);
size_t g16mic_fifo_write(g16mic_fifo *f, const float *src, size_t n);   /* writes min(n, space) */
size_t g16mic_fifo_read(g16mic_fifo *f, float *dst, size_t n);          /* reads min(n, fill); dst NULL discards */
size_t g16mic_fifo_fill(const g16mic_fifo *f);
size_t g16mic_fifo_space(const g16mic_fifo *f);

/* Lock-free bounded SPSC queue of fixed-size records. One producer thread
 * pushes, one consumer thread pops. A full queue drops the new record and
 * counts it; it never blocks and never grows. */
typedef struct { unsigned char *slots; size_t slot_size, cap; _Atomic size_t head, tail; _Atomic uint64_t pushed, dropped, popped; } g16mic_spsc;
int g16mic_spsc_init(g16mic_spsc *q, size_t slot_size, size_t cap_pow2);  /* cap must be power of two >= 2; -1 otherwise */
void g16mic_spsc_free(g16mic_spsc *q);
int g16mic_spsc_push(g16mic_spsc *q, const void *rec);  /* RT-safe: 1 pushed; 0 full -> dropped++ (never blocks, never allocates) */
int g16mic_spsc_pop(g16mic_spsc *q, void *rec);         /* 1 popped, 0 empty */
uint64_t g16mic_spsc_dropped(const g16mic_spsc *q);

/* Lock-free SPSC sample ring (floats). */
typedef struct { float *buf; size_t cap; _Atomic size_t head, tail; _Atomic uint64_t overflow, underflow; } g16mic_ring;
int g16mic_ring_init(g16mic_ring *r, size_t cap_pow2);  /* cap must be power of two >= 2; -1 otherwise */
void g16mic_ring_free(g16mic_ring *r);
size_t g16mic_ring_write(g16mic_ring *r, const float *src, size_t n);  /* writes what fits; overflow += n - written */
size_t g16mic_ring_read(g16mic_ring *r, float *dst, size_t n);        /* reads what is there; zero-fills the rest of dst; underflow += missing */
size_t g16mic_ring_fill(const g16mic_ring *r);

/* ---- calib.c: calibration and geometry --------------------------------- */

/* A parsed calibration file (format described in calibration.example.conf).
 * map[i] is the stream channel that feeds mic i. gain_db, polarity and
 * delay_samples correct each mic. pos[i] is mic i's position (metres, see the
 * coordinate convention above); have_pos is 1 only when every mic has one.
 * measured is "YYYY-MM-DD"; kernel is a kernel release prefix ("7.2");
 * layout is the host layout id ("<node.name>/<N>ch"). */
typedef struct { int channels; int map[G16MIC_MAX_CH]; float gain_db[G16MIC_MAX_CH]; int polarity[G16MIC_MAX_CH]; float delay_samples[G16MIC_MAX_CH]; float pos[G16MIC_MAX_CH][3]; int have_pos; float hpf_hz; int dc_block; int verified; char measured[11]; char kernel[64]; char layout[128]; int max_age_days; int rate; } g16mic_calib;
typedef enum { G16MIC_CAL_OK=0, G16MIC_CAL_MISSING, G16MIC_CAL_PARSE, G16MIC_CAL_NONFINITE, G16MIC_CAL_RANGE, G16MIC_CAL_CHANNELS, G16MIC_CAL_ZERO_APERTURE, G16MIC_CAL_DUP_POSITION, G16MIC_CAL_UNVERIFIED, G16MIC_CAL_STALE, G16MIC_CAL_KERNEL, G16MIC_CAL_LAYOUT } g16mic_cal_status;
void g16mic_calib_identity(g16mic_calib *c, int channels);  /* map=i, gain 0 dB, polarity +1, delay 0, no positions, hpf 80, dc_block 1, verified 0, max_age 365, rate 48000 */
/* Syntax and per-value checks. On any failure *out is zeroed (channels 0, so
 * g16mic_calib_omni_usable() is false for it) and err names the line or key. */
g16mic_cal_status g16mic_calib_parse(const char *text, g16mic_calib *out, char *err, size_t errlen);
g16mic_cal_status g16mic_calib_load(const char *path, g16mic_calib *out, char *err, size_t errlen);  /* MISSING if the file can't be opened; max 64 KiB */
/* What the host is actually capturing. now == 0 means time(NULL). */
typedef struct { int stream_channels; const char *layout; const char *kernel_release; time_t now; } g16mic_cal_context;
g16mic_cal_status g16mic_calib_check_spatial(const g16mic_calib *c, const g16mic_cal_context *ctx, char *err, size_t errlen);  /* OK only if the fixed beam / tracking may run */
int g16mic_calib_omni_usable(const g16mic_calib *c, int stream_channels);  /* 1 if omni may use this file's gain/polarity/delay: parsed, verified, map in range; else omni uses identity */
const char *g16mic_cal_status_name(g16mic_cal_status s);  /* "ok","missing","parse","nonfinite","range","channels","zero-aperture","duplicate-position","unverified","stale","kernel","layout" */

/* ---- match.c: choosing the capture source ------------------------------ */

typedef struct { uint32_t id; const char *node_name; const char *media_class; const char *device_class; } g16mic_node_info;  /* device_class may be NULL; "monitor" marks a sink monitor */
typedef enum { G16MIC_MATCH_FOUND=0, G16MIC_MATCH_ABSENT, G16MIC_MATCH_REFUSED_MONITOR, G16MIC_MATCH_REFUSED_CLASS, G16MIC_MATCH_REFUSED_OWN, G16MIC_MATCH_AMBIGUOUS, G16MIC_MATCH_BAD_NAME } g16mic_match_result;
/* Exact node.name match only: never a prefix, a description or "the first
 * available source". Refuses monitors, non-Audio/Source nodes and our own
 * g16_mic_* outputs. *index_out is set only on G16MIC_MATCH_FOUND. */
g16mic_match_result g16mic_match_source(const char *wanted, const g16mic_node_info *nodes, size_t n, size_t *index_out);
const char *g16mic_match_result_name(g16mic_match_result r);  /* "found","absent","refused-monitor","refused-class","refused-own","ambiguous","bad-name" */

/* ---- dsp.c / track.c / engine.c: processing ---------------------------- */

typedef enum { G16MIC_MODE_RAW=0, G16MIC_MODE_OMNI, G16MIC_MODE_BEAM, G16MIC_MODE_TRACK } g16mic_mode;
const char *g16mic_mode_name(g16mic_mode m);  /* "raw","omni","beam","track" */
int g16mic_mode_parse(const char *s, g16mic_mode *out);  /* 0 ok, -1 unknown */
int g16mic_mode_is_spatial(g16mic_mode m);
typedef struct { g16mic_mode mode; float steer_az_deg, steer_el_deg; float xfade_ms; float limiter_ceiling; float limiter_release_ms; float track_conf_enter, track_conf_exit; float track_hysteresis_deg; float track_max_slew_deg_s; float track_hold_ms; float track_unsure_ms; float vad_threshold_db; } g16mic_params;
void g16mic_params_default(g16mic_params *p);  /* mode omni, az 0, el 0, xfade 20 ms, ceiling 0.891 (-1 dBFS), release 100 ms, enter 2.0, exit 1.4, hysteresis 10 deg, slew 90 deg/s, hold 2000 ms, unsure 200 ms, vad 9 dB */
void g16mic_steering_delays(const float pos[][3], int n, float az_deg, float el_deg, int rate, float *delay_out);  /* per-mic alignment delay relative to the array centroid, in samples: delay_i = ((r_i - centroid) . u) * rate / c; a mic nearer the source hears it earlier and so gets a larger (positive) delay */
void g16mic_fracdelay_taps(float frac, float taps[G16MIC_FD_TAPS]);  /* windowed-sinc, total delay G16MIC_FD_CENTER + frac, frac in [0,1), taps sum to 1 */
typedef struct { g16mic_mode mode_requested, mode_active; int spatial_available; g16mic_cal_status spatial_reason; int omni_calibrated; int degraded; float confidence, doa_az_deg, steer_az_deg; int vad_active; uint64_t frames_in, frames_out, blocks, fallbacks, mode_switches, refused_switches, nonfinite_samples, limiter_blocks; } g16mic_stats;
typedef struct g16mic_tracker g16mic_tracker;
typedef struct { float doa_az_deg; float confidence; int vad; float steer_az_deg; int locked; int fallback; } g16mic_track_out;
g16mic_tracker *g16mic_tracker_create(const float pos[][3], int n, int rate, const g16mic_params *p);  /* preallocates + plans FFTW (FFTW_ESTIMATE); NULL on failure */
void g16mic_tracker_destroy(g16mic_tracker *t);
void g16mic_tracker_update(g16mic_tracker *t, const float *const *chan, g16mic_track_out *out);  /* chan[i]: G16MIC_BLOCK omni-aligned calibrated frames of mic i; RT-safe */
float g16mic_gcc_phat_tdoa(g16mic_tracker *t, const float *a, const float *b, float *peak_ratio);  /* TDOA of b relative to a over the last 2*G16MIC_BLOCK frames the tracker holds, samples, sub-sample (parabolic); exposed for tests; uses the tracker's preallocated buffers */
typedef struct g16mic_engine g16mic_engine;
g16mic_engine *g16mic_engine_create(int stream_channels, int rate, const g16mic_calib *cal, g16mic_cal_status spatial_status, const g16mic_params *p);  /* cal may be NULL; all allocation and FFTW planning here; returns NULL if p->mode is spatial and spatial_status != OK, or on bad args */
void g16mic_engine_destroy(g16mic_engine *e);
size_t g16mic_engine_latency(const g16mic_engine *e);  /* frames; same for raw and every mode */
int g16mic_engine_request_mode(g16mic_engine *e, g16mic_mode m);  /* any thread; 0 accepted (applied at the next block with a crossfade); -1 refused: spatial without OK calibration (refused_switches++) */
void g16mic_engine_process(g16mic_engine *e, const float *in, size_t frames, float *raw_out, float *mono_out);  /* RT-safe; in/raw_out interleaved frames x stream_channels; mono_out frames; writes exactly `frames` frames */
size_t g16mic_engine_flush(g16mic_engine *e, float *raw_out, float *mono_out, size_t max_frames);  /* tail flush on stop */
void g16mic_engine_get_stats(const g16mic_engine *e, g16mic_stats *out);

#endif /* G16MIC_H */
