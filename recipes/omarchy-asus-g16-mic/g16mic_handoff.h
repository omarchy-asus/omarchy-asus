/* SPDX-License-Identifier: MIT */
/* g16mic_handoff.h: the hand-off from the capture callback to the two
 * outputs of the g16-mic host (part of libg16mic; no PipeWire headers).
 *
 * The capture callback is the single producer: it runs the engine over each
 * capture cycle and pushes the cycle (mono for the processed output,
 * interleaved for the raw output) as one entry into a bounded lock-free
 * queue per output. Each output callback is the single consumer of its own
 * queue.
 *
 * Exactly one quantum per output buffer: g16mic_handoff_output() always
 * writes exactly the quantum the buffer asks for (the requested size, else
 * the last capture cycle's size), never more. PipeWire's output adapter
 * consumes one quantum per graph cycle from a buffer and keeps the rest of a
 * larger one hidden from us, so every frame this hand-off buffers is in its
 * own queue, where it is counted; none is parked in the adapter. The
 * consumer keeps a read position inside the oldest entry, so a quantum that
 * differs from the capture cycle size (256 or 1536 against 1024) is taken
 * across entry boundaries, contiguous.
 *
 * Added latency and its bound: in steady state an output takes, in the same
 * graph cycle, the cycle the capture just pushed, so the end-to-end latency
 * is exactly the engine latency (g16mic_engine_latency, 272 frames for
 * uncalibrated omni) and the target extra fill is G16MIC_HF_TARGET_CYCLES
 * (0). An output run that was refused or ran late leaves its cycle in the
 * queue: from then on that output carries that much added latency
 * (added_frames, max_added_frames). An output never delivers more than one
 * quantum a run, so it cannot catch up; it is hard-bounded by the queue
 * capacity, G16MIC_HF_CAP_CYCLES (8) x the cycle size: 170.7 ms at 1024
 * frames and 48 kHz.
 *
 * Latency trim (the only recovery; counted, quiet only): without it every
 * sporadic graph xrun would add a cycle for good, until the queue sat at
 * its bound and overflowed. The capture withholds a whole cycle from BOTH
 * outputs (it is never pushed) when, all at once:
 *   - every consuming output holds at least a whole cycle of the current
 *     stream before the push (more than the target, G16MIC_HF_TARGET_CYCLES
 *     = 0 extra cycles) and none is in its start window;
 *   - that excess has held at every push for G16MIC_HF_TRIM_HOLDOFF_MS
 *     (1000 ms, counted in pushed frames, no clock read);
 *   - at least G16MIC_HF_TRIM_EVERY_CYCLES (4) cycles have passed since the
 *     last trim: at most one quantum per 4 cycles;
 *   - the cycle is quiet on every raw channel AND the processed mono: every
 *     sample below G16MIC_HF_TRIM_QUIET_PEAK (-60 dBFS, 0.001). Never inside
 *     speech, a -40 dBFS tone burst or a sample marker.
 * The withheld cycle is the newest, judged by the producer at push time on
 * the cycle itself (RT-safe, no per-entry peak to store), so nothing already
 * queued is touched and no consumer can race the trim. The same cycle goes
 * from both outputs, so processed and raw stay sample aligned. Each trim brings both outputs one
 * cycle nearer the target and never below it (the output that holds the
 * least still holds a whole cycle). It is counted per output in samples
 * (latency_trimmed) and cycles (latency_trimmed_cycles), and once per
 * decision (latency_trims); never reset, and not a loss
 * (g16mic_handoff_lost_samples leaves it out). On input that is never
 * quiet the latency stays, bounded as above. Overflow past the bound still
 * drops the oldest entry and counts it as overflow.
 *
 * Overflow: a push into a queue that already holds G16MIC_HF_CAP_CYCLES
 * entries drops the OLDEST entry (the rest of it, from the consumer's read
 * position), never the newest and never part of an entry being read, and
 * counts exactly what it dropped (overflow, overflow_cycles).
 *
 * Epochs: every new capture (new engine) gets a new epoch. Entries of an
 * earlier epoch are dropped and counted (stale_dropped), never delivered: no
 * buffer g16mic_handoff_output() returns after g16mic_handoff_new_epoch()
 * contains an earlier epoch's sample, so a reconnected source never carries
 * the previous stream's tail.
 *
 * Consuming: the producer pushes into an output's queue only while the host
 * says a consumer is linked (g16mic_handoff_set_consuming). Linking records
 * the next capture cycle's sequence number; anything queued before it is
 * dropped and counted (late_link_discarded), so a late listener starts at
 * current audio, never at stale backlog.
 *
 * Start window (g16mic_handoff_start_output, g16mic_handoff_relink): for
 * G16MIC_HF_START_CYCLES capture cycles after a link, an output that holds
 * more than the cycle just pushed, right after the push, restarts at that
 * cycle (what came before: late_link_discarded). The cause it fixes: right
 * after a link PipeWire can run the output BEFORE the capture in a graph
 * cycle (the link schedules it too, and the capture's trigger is then
 * refused), so each of those runs takes the previous cycle. Once the order
 * turns normal (capture first) the output takes, every cycle, the one
 * before the capture's: one cycle behind for good (latency 1296 = 272 +
 * 1024, queue_added_frames 1024). Round 2 checked only the output's first
 * 4 runs, which an output-first spell longer than that outlasted. The check
 * is after the push of the same graph cycle, so it holds whatever order
 * PipeWire runs the two in: an output that is on time holds just that
 * cycle (it took the previous one, before or after the capture) and is
 * never touched. The engine tail pushed at a stop or source loss never
 * restarts an output.
 *
 * Stop: g16mic_handoff_begin_stop() ends input at the stop instant. The next
 * capture call accepts no input; it flushes the engine's latency tail and
 * pushes it as the last entry of each consuming output, then the hand-off
 * is stopped; later capture calls push nothing and are harmless, so the
 * host keeps calling them (and triggering the outputs) every cycle of the
 * drain. The outputs deliver the queue quantum by quantum; the final buffer
 * is zero-padded to the quantum (eos_pad), and once nothing is queued they
 * return 0 (end of stream). g16mic_handoff_drained() says when an output's
 * last buffer has passed through the graph; if that does not happen within
 * G16MIC_HF_DRAIN_MS, g16mic_handoff_abandon() counts what is left as
 * drain_lost.
 *
 * Real-time rules (as in g16mic.h): the functions marked RT-safe never lock,
 * sleep, allocate or make a system call. All allocation is in
 * g16mic_handoff_create(). Every counter is monotonic and never reset, except
 * the two "now" values (depth, added_frames).
 */
#ifndef G16MIC_HANDOFF_H
#define G16MIC_HANDOFF_H

#include <stddef.h>
#include <stdint.h>

#include "g16mic.h"

/* the two outputs */
#define G16MIC_HF_PROCESSED 0
#define G16MIC_HF_RAW 1
#define G16MIC_HF_NOUT 2

#define G16MIC_HF_CAP_CYCLES 8        /* queue capacity per output, whole cycles (power of two): the hard bound on depth and added latency */
#define G16MIC_HF_MAX_FRAMES 8192     /* largest cycle an entry carries, frames (at most 65535) */
#define G16MIC_HF_TARGET_CYCLES 0     /* steady-state extra fill: an output on time adds no latency; the latency trim steers back to it */
#define G16MIC_HF_START_CYCLES 32     /* start window after a link or relink, capture cycles (0.68 s at 1024 frames) */
#define G16MIC_HF_TRIM_HOLDOFF_MS 1000 /* trim: how long both outputs must hold a whole extra cycle first */
#define G16MIC_HF_TRIM_QUIET_DBFS (-60) /* trim: a cycle is quiet when every sample is below this, on all channels */
#define G16MIC_HF_TRIM_QUIET_PEAK 0.001f /* the same, linear: 10^(-60/20) */
#define G16MIC_HF_TRIM_EVERY_CYCLES 4 /* trim: at most one cycle per this many capture cycles */
#define G16MIC_HF_DRAIN_MS 500        /* stop: longest the host waits for the outputs to drain */
#define G16MIC_HF_TAIL_WINDOW_MS 50   /* source loss: how long the host keeps the outputs alive to deliver the tail */

/* g16mic_handoff_stopping() */
#define G16MIC_HF_RUNNING 0
#define G16MIC_HF_STOP_REQUESTED 1
#define G16MIC_HF_STOPPED 2

/* g16mic_handoff_abandon() causes */
#define G16MIC_HF_LOST_DRAIN 1
#define G16MIC_HF_LOST_SOURCE 2

/* One output's counters, exact per output. Samples (frames x the entry's
 * channels, or x the output's channels for what the output writes) unless
 * the name says frames or cycles.
 *
 * Every sample the producer makes for a consuming output ends in exactly
 * one of: delivered, width_mismatch, overflow, stale_dropped,
 * late_link_discarded, drain_lost, source_lost_tail, latency_trimmed
 * (withheld at the push by the quiet-only trim, never queued), or is still
 * queued (added_frames); the producer's oversize is counted before any of
 * them. underflow and eos_pad are zeros the output wrote that no capture
 * produced. */
typedef struct {
	uint64_t delivered;           /* queued samples handed to the output */
	uint64_t underflow;           /* zeros written while running for want of queued audio */
	uint64_t eos_pad;             /* zeros padding the final buffer of a stream to the quantum (end of stream; not a loss, not underflow) */
	uint64_t overflow;            /* queue full: the oldest entry's undelivered rest, dropped to make room */
	uint64_t overflow_cycles;     /* the same, in entries */
	uint64_t oversize;            /* the part of a capture cycle beyond max_frames, and requested frames beyond the output buffer */
	uint64_t width_mismatch;      /* queued samples of another channel count than the output's (written as zeros) */
	uint64_t stale_dropped;       /* queued samples of an earlier epoch (a previous source), dropped */
	uint64_t late_link_discarded; /* queued before the consumer (re)linked, dropped (not a loss) */
	uint64_t drain_lost;          /* still queued when the stop drain timed out */
	uint64_t source_lost_tail;    /* still queued when the source was lost and the tail window ended */
	uint64_t late_runs;           /* output runs that left at least a whole cycle queued behind them */
	uint64_t retries;             /* output runs that recopied because the producer dropped what they had copied */
	uint64_t latency_trimmed;     /* quiet samples withheld by the latency trim (not a loss, not in lost_samples) */
	uint64_t latency_trimmed_cycles; /* the same, in capture cycles */
	uint64_t max_depth;           /* most entries ever queued (never above G16MIC_HF_CAP_CYCLES) */
	uint64_t depth;               /* entries queued now (a partly taken one counts) */
	uint64_t added_frames;        /* frames queued now: the output's added latency */
	uint64_t max_added_frames;    /* most frames an output run left queued (largest added latency observed; at most G16MIC_HF_CAP_CYCLES x the cycle) */
} g16mic_hf_out_stats;

typedef struct {
	g16mic_hf_out_stats out[G16MIC_HF_NOUT];  /* G16MIC_HF_PROCESSED, G16MIC_HF_RAW */
	/* graph frames the capture never saw (the graph position jumped:
	 * starvation, SIGSTOP). This is input that never reached us, NOT output
	 * loss: it is in no output counter and not in
	 * g16mic_handoff_lost_samples(). */
	uint64_t capture_gap_frames;
	uint64_t tail_flushed_frames;  /* engine tail frames pushed at stops and source losses */
	uint64_t trigger_refused;      /* output triggers refused while the output was consuming */
	int trigger_errno;             /* errno of the last refused trigger (0 = none) */
	uint64_t last_cycle_frames;    /* frames of the last capture cycle pushed */
	uint64_t latency_trims;        /* capture cycles the latency trim withheld (one per decision, whatever the outputs) */
} g16mic_hf_stats;

typedef struct g16mic_handoff g16mic_handoff;

/* Control thread, not RT. Allocates both queues (cap_cycles_pow2 + 1 slots
 * of max_frames x 1 and max_frames x max_channels samples) and the
 * producer's scratch. max_channels 1..G16MIC_MAX_CH, cap_cycles_pow2 a power
 * of two >= 2 (the logical capacity), max_frames 1..65535. NULL on bad
 * arguments or out of memory. Starts in epoch 0, running, neither output
 * consuming. */
g16mic_handoff *g16mic_handoff_create(int max_channels, size_t cap_cycles_pow2, size_t max_frames);

/* Control thread, not RT. Frees everything; no callback may run. NULL is a
 * no-op. */
void g16mic_handoff_destroy(g16mic_handoff *hf);

/* Control thread, before the new capture's first cycle. Starts a new epoch
 * (a new engine / source) and returns it. Entries of earlier epochs still
 * queued are dropped (stale_dropped), never delivered: an output run that
 * copied any of them while the epoch changed recopies. The producer's
 * capture-gap tracking restarts. Lock-free, no allocation. */
uint64_t g16mic_handoff_new_epoch(g16mic_handoff *hf);

/* Control thread (stream state changes). on = 1 when the output is
 * streaming (a consumer is linked): from the next capture cycle on, cycles
 * are pushed into its queue; entries queued before that cycle are dropped
 * when it next runs (late_link_discarded). on = 0: nothing more is pushed.
 * Lock-free, no allocation. */
void g16mic_handoff_set_consuming(g16mic_handoff *hf, int out, int on);

/* Producer, RT-safe, before g16mic_handoff_capture: the output became
 * active since the previous capture cycle (the host activates its outputs
 * only once the capture streams, a cycle or more after the capture's first
 * cycles). The cycle about to be pushed is the first this output takes:
 * everything queued before it is dropped when it next runs
 * (late_link_discarded), so that backlog never becomes added latency for
 * the rest of the stream. Opens the start window, as start_output. */
void g16mic_handoff_relink(g16mic_handoff *hf, int out);

/* Control thread, after g16mic_handoff_set_consuming(on = 1): a consumer
 * linked. Opens the output's start window (above): for the next
 * G16MIC_HF_START_CYCLES capture cycles, an output that holds more than the
 * cycle just pushed restarts at it, and what came before (pushed between
 * the link and the consumer's first graph cycles, or taken a cycle late
 * after runs PipeWire made before the capture's) is dropped
 * (late_link_discarded) instead of becoming added latency for the rest of
 * the stream. Lock-free, no allocation. */
void g16mic_handoff_start_output(g16mic_handoff *hf, int out);

/* Capture callback (the single producer), RT-safe. Runs e over the cycle's
 * frames (interleaved, ch channels; ch must be the engine's channel count)
 * and pushes the result to each consuming output. A cycle above the
 * hand-off's max_frames is processed whole (engine state stays continuous),
 * its first max_frames are pushed and the rest is counted as oversize. A
 * full queue drops its oldest entry (overflow). A cycle the latency trim
 * withholds (quiet, both outputs a cycle behind for the hold-off) is pushed
 * to neither output (latency_trimmed). ticks / have_ticks: the
 * cycle's graph position, for capture_gap_frames. e may be NULL: nothing is
 * pushed. After g16mic_handoff_begin_stop() no input is accepted: the first
 * call flushes e's tail into the queues and stops, later calls do nothing. */
void g16mic_handoff_capture(g16mic_handoff *hf, g16mic_engine *e, const float *in, size_t frames, int ch, uint64_t ticks, int have_ticks);

/* Control thread, at a source loss; the caller guarantees no capture
 * callback runs (the control thread is the producer). Flushes e's latency
 * tail (if this epoch accepted any input) into the consuming outputs'
 * queues, marks the hand-off stopped (outputs that find nothing queued then
 * get end of stream, not underflow) and returns the tail frames pushed.
 * Not RT (but does not allocate). */
size_t g16mic_handoff_flush_tail(g16mic_handoff *hf, g16mic_engine *e);

/* Control thread (a stop signal). Requests the stop: the next capture call
 * accepts no input and pushes the tail. Lock-free. */
void g16mic_handoff_begin_stop(g16mic_handoff *hf);

/* Any thread, lock-free: G16MIC_HF_RUNNING (0), G16MIC_HF_STOP_REQUESTED
 * (1: the tail is not pushed yet) or G16MIC_HF_STOPPED (2). */
int g16mic_handoff_stopping(const g16mic_handoff *hf);

/* Control thread, before the next capture (source-loss path); no capture
 * callback runs. Back to running. Lock-free. */
void g16mic_handoff_reset_stop(g16mic_handoff *hf);

/* Any thread, lock-free. Samples the output still has to take: what is
 * queued, plus, while a stop is requested and the tail not yet pushed, the
 * tail still due. 0 for an output that is not consuming (no consumer to wait
 * for). */
size_t g16mic_handoff_pending(const g16mic_handoff *hf, int out);

/* Any thread, lock-free. 1 when the output is not consuming, or when the
 * hand-off is STOPPED, the output's queue is empty and its callback has run
 * at least once after the run that handed out its last real (or
 * zero-padded) buffer, so that buffer has gone through its graph cycle; 0
 * otherwise. The stop drain waits until both outputs are drained. */
int g16mic_handoff_drained(const g16mic_handoff *hf, int out);

/* Control thread; the caller guarantees no output callback runs. Empties
 * both queues and counts every queued sample (a partly taken entry from the
 * consumer's read position): of the current epoch as drain_lost (cause
 * G16MIC_HF_LOST_DRAIN) or source_lost_tail (G16MIC_HF_LOST_SOURCE); queued
 * before a re-link as late_link_discarded; of an earlier epoch as
 * stale_dropped. If a stop is still requested (no capture cycle came to push
 * the tail), the caller first stops the capture and calls
 * g16mic_handoff_flush_tail() so the tail is counted too. */
void g16mic_handoff_abandon(g16mic_handoff *hf, int cause);

/* Capture callback, RT-safe. res is pw_stream_trigger_process()'s result for
 * output out: a negative result while that output is consuming counts as
 * trigger_refused (and records -res as trigger_errno). */
void g16mic_handoff_note_trigger(g16mic_handoff *hf, int out, int res);

/* Output callback of out (its single consumer), RT-safe. dst has room for
 * max_frames x ch samples. want = requested, or the last capture cycle's
 * frames if requested is 0; a want above max_frames is cut to max_frames and
 * the cut counted as oversize. Writes exactly want frames and returns want:
 * - entries of another epoch or queued before the link are dropped first
 *   (counted), never written;
 * - queued audio first, oldest first, from the read position inside the
 *   oldest entry, across entries as needed; an entry of another channel
 *   count than ch is written as zeros (width_mismatch);
 * - if less than want is queued: while running (or a stop is requested but
 *   the tail is not pushed yet) the rest is zeros counted as underflow;
 *   once stopped the final buffer is zero-padded, counted as eos_pad.
 * Once stopped with nothing queued it writes nothing and returns 0 (end of
 * stream). Never more than one quantum: what does not fit stays queued. */
size_t g16mic_handoff_output(g16mic_handoff *hf, int out, float *dst, size_t max_frames, int ch, size_t requested);

/* Any thread, lock-free (each counter is exact, the set is not one atomic
 * snapshot). */
void g16mic_handoff_get_stats(const g16mic_handoff *hf, g16mic_hf_stats *st);

/* Pure. Samples produced and never delivered, over both outputs: overflow +
 * oversize + width_mismatch + stale_dropped + drain_lost + source_lost_tail
 * (the host's ring_overflow). underflow, eos_pad, late_link_discarded and
 * latency_trimmed are not in it; neither is capture_gap_frames (input,
 * not output). The host's ring_underflow is the sum of underflow. */
uint64_t g16mic_handoff_lost_samples(const g16mic_hf_stats *st);

/* Tests only: fn(arg, out) runs inside g16mic_handoff_output() after it has
 * copied from the queue and before it publishes its new read position, so a
 * test can run the producer in exactly that window (the recopy path). Set it
 * while no callback runs; NULL (the default) disables it. */
typedef void (*g16mic_hf_test_hook)(void *arg, int out);
void g16mic_handoff_set_test_hook(g16mic_handoff *hf, g16mic_hf_test_hook fn, void *arg);

#endif /* G16MIC_HANDOFF_H */
