# omarchy-asus-g16-mic (EXPERIMENTAL)

`g16-mic` is an opt-in processor for the internal microphones of the ASUS ROG Zephyrus G16
(GA605KM). You run it by hand: it captures exactly one PipeWire source, the one you name, and
offers the result as new PipeWire sources that applications can pick. Nothing starts at install,
nothing is enabled, nothing goes into `/etc` or `pipewire.conf.d`, and the default source never
changes. Part of #400 (#401).

The package is **held** (`HOLD`): CI builds and tests it, nothing publishes it, until the
maintainer's G16 tests pass. It builds against libpipewire 1.1 or newer
(`pw_stream_get_data_loop`).

## Modes

| mode | what comes out of `g16_mic_processed` | needs a verified calibration |
|---|---|---|
| `raw` | no speech processing at all: the first mic's channel (`map` entry 0, or stream channel 0 without a verified calibration), bit-exact, no limiter; `g16_mic_raw` (in every mode) carries every captured channel bit-exact, in order, delayed by the same fixed latency as the other modes | no |
| `omni` (default) | the calibrated, delay-matched average of all mics | no (uncalibrated while the file is unverified) |
| `beam` | fractional-delay delay-and-sum toward a fixed direction (`--steer-az`), far-field steering from the mic positions, unity gain on the target, a limiter only at the output | yes |
| `track` | GCC-PHAT direction estimates per block, a confidence from the peak ratio, hysteresis, a bounded slew rate, holding through pauses (an energy voice-activity detector), and omni whenever it is unsure; it never gates to silence | yes |

Switching modes, and every fallback, crossfades between the old and new signal with their delays
matched, so nothing jumps or repeats. Every accepted sample reaches the outputs, including the
last engine latency of audio still inside the engine (272 frames, 5.7 ms, for uncalibrated omni)
when g16-mic stops or the source goes away: the engine's tail is flushed into the outputs and
delivered while a consumer is linked (Delivery, below). Audio is lost only when a documented bound
is exceeded, and then it is counted exactly. The one deliberate exception is the latency
recovery: whole quanta of near-silence (below -60 dBFS on every channel), never speech or a
marker, dropped to win back latency added by late cycles, counted separately (Delivery, below).

## Delivery

**The queue.** The capture cycle hands each processed cycle to the two outputs through a bounded,
preallocated, lock-free queue per output (one producer, one consumer; nothing locks, sleeps or
allocates in the audio callbacks). All buffering is in this queue, where it is counted.

- One quantum per buffer: every output buffer carries exactly the quantum the graph asked for
  (the buffer's requested size, else the capture's cycle size), never more. PipeWire's output
  adapter consumes one quantum per graph cycle and would keep the rest of a larger buffer inside
  itself, out of sight and uncounted, so nothing is ever parked there.
- Capacity: 8 whole capture cycles per output. That is the hard bound on queue depth and on the
  latency the queue can add: 8 x quantum / 48 kHz, 170.7 ms at a 1024-frame quantum.
- Target fill: 0 extra cycles. In steady state an output takes the cycle captured in the same
  graph cycle, so the end-to-end latency stays exactly the engine latency (272 frames for
  uncalibrated omni).
- A late or refused output cycle (PipeWire refused its trigger, or the output's run was missed)
  leaves its audio in the queue: nothing is lost, and the added latency grows by that cycle,
  never beyond the bound. g16-mic never wins that latency back by sending extra audio: an output
  delivers at most one quantum a run.
  The status shows the added latency now and its observed maximum (`queue_added_frames`,
  `queue_max_added_frames`, `queue_max_added_ms`).
- Latency recovery, quiet cycles only. Without it, sporadic late cycles (graph xruns) would
  ratchet the queue up to its bound and then overflow. When every consuming output's queue has
  held at least one whole cycle more than its target fill (0 extra cycles) for longer than a
  hold-off of 1 s (`G16MIC_HF_TRIM_HOLDOFF_MS`, 1000), g16-mic withholds the newest capture
  cycle from both outputs (it is never queued), but only when that cycle is quiet on ALL
  channels, raw and processed (every sample below -60 dBFS, `G16MIC_HF_TRIM_QUIET_DBFS`), so
  never inside speech, a quiet speech burst or a test marker, and at most one cycle per 4
  (`G16MIC_HF_TRIM_EVERY_CYCLES`). The same cycle goes from both outputs, so `g16_mic_processed`
  and `g16_mic_raw` stay sample-aligned. Every trimmed sample is counted in its own counter,
  `latency_trimmed_frames` (samples, frames times channels like the others, summed over both
  outputs, never reset; `latency_trimmed_cycles` counts the trims), separate from
  `ring_overflow`. Residual risks: nothing is trimmed during continuous speech, so latency added
  by late cycles in a long stretch of speech stays until the next quiet cycle; and an output
  that is behind while the other is on time is not trimmed (that would cost the on-time one a
  cycle), so its added latency stays. Both are still within the 8-cycle bound, and the overflow
  rule below still applies.
- Overflow: only when an output falls more than 8 cycles behind (a stall longer than the bound,
  e.g. the process or a consumer stopped) does a new cycle not fit; then the OLDEST queued audio
  is dropped to make room, and counted exactly (`ring_overflow`). Nothing blocks, the queue never
  grows past its capacity, and no counter is ever reset.
- Underflow: an output with nothing queued delivers zeros, counted (`ring_underflow`).
- `g16_mic_processed` and `g16_mic_raw` stay sample-aligned: both carry the same cycles at the
  same latency.

**Stop (SIGINT, SIGTERM).** Input stops at the stop instant: from then on the capture accepts no
new input, pushes the engine's latency tail into the queues once, and keeps triggering both
outputs every cycle. The outputs deliver the queue quantum by quantum until the engine tail and
everything queued have passed through the graph, so the last accepted cycle arrives; the final
buffer is zero-padded to a whole quantum (counted as `eos_pad`, not a loss). If the capture stops
running meanwhile, g16-mic triggers the outputs itself once per quantum period. The drain takes
at most 500 ms; whatever cannot be delivered by then (no consumer, a stalled consumer) is counted
exactly as `drain_lost`. Then g16-mic exits 0, with its nodes and status file removed.

**Source loss.** When the named source disappears, the engine's tail is flushed into the queues,
and, if the outputs are still running, g16-mic triggers them itself (they have no capture to
drive them any more) once per quantum period for at most 50 ms to deliver it, quantum by
quantum. Whatever is still undelivered after that, the engine tail plus everything still queued
(or all of it when the capture had already paused and stopped the outputs before the source
went), is counted exactly, per output, as `source_lost_tail`, and the queues are emptied.
**A reconnect never emits stale data:** the new stream starts with empty queues, and anything of
the previous source still queued when it starts is dropped, never delivered after new audio, and
counted (`stale_dropped`).

**Late listener.** An application that links to an output after g16-mic started gets current
audio, not a backlog: anything queued before it linked is discarded and counted
(`late_link_discarded`), and it starts at exactly the engine latency (272 frames for
uncalibrated omni). That holds also when PipeWire runs the output before the capture in a graph
cycle (the output scheduled by the driver or a link rather than by the capture's trigger): such
an early run does not leave the listener one cycle behind for the rest of its run.

**Real time.** g16-mic asks for real-time scheduling of its audio thread through PipeWire's own
`libpipewire-module-rt` (an `RLIMIT_RTPRIO` allowance, else RTKit, else the realtime portal; no
root, no scheduling call of its own). Whether it got it is observed on the running audio thread
and reported in the status (`rt_*` keys, below). Without real time the queue still absorbs
ordinary scheduling delays up to its bound.

**Preserve speech.** When tracking is unsure, or a spatial mode cannot run, the output falls back
to the time-aligned calibrated omni signal (or raw, if omni cannot be built). It never suppresses
to silence. Every fallback is counted (`fallbacks`, `degraded` in the status).

## Nodes

- `g16_mic_processed`: mono, the current mode's output.
- `g16_mic_raw`: every captured channel, untouched.
- `g16_mic_clean`: mono, only with the echo-cancel fragment linked in (below).
- `g16_mic_clean_ns`: mono, only with the opt-in noise-suppression fragment linked in (below).

All of them have `priority.session = 0`, so the session manager never makes them the default
source; you pick them per application, or with `wpctl set-default` yourself.

The capture is matched by `node.name` only. g16-mic refuses monitors (`*.monitor`, or
`media.class` `Audio/Sink`), its own outputs and any other microphone; if the named source goes
away it waits and reconnects to the same name only, never to "the first available" source. If
something else is linked into its capture, it disconnects and counts it (`wrong_links`).

## Calibration and geometry file

Default path: `$XDG_CONFIG_HOME/g16-mic/calibration.conf` (else
`~/.config/g16-mic/calibration.conf`), or `--calib FILE`. The documented example is
`/usr/share/omarchy-asus-g16-mic/calibration.example.conf`. Syntax: `key=value`, one per line;
`#` starts a comment only at the start of a line; unknown or repeated keys are errors; lists are
comma separated with exactly `channels` items, mic 0 first.

| key | meaning |
|---|---|
| `format` | file format version; only `1` |
| `channels` | mics described, 1..8; must equal the captured stream's channel count |
| `rate` | sample rate of the measurement; only `48000` |
| `layout` | `<node.name>/<N>ch` of the stream it was measured on, exactly as `g16-mic status` prints it |
| `kernel` | kernel release prefix it was measured on, ending at a version boundary (`7.2` matches `7.2.8-9-omarchy`, not `7.20.1`) |
| `measured` | date of the measurement, `YYYY-MM-DD` (UTC) |
| `max_age_days` | how long the measurement stays valid, 1..3650 |
| `verified` | `true` only once the values were measured on this machine and checked |
| `map` | stream channel feeding each mic, 0..7, no repeats |
| `gain_db` | per-mic gain correction, -40..40 dB |
| `polarity` | per-mic `1` or `-1` |
| `delay` | per-mic delay correction in samples at 48 kHz, 0..32, fractional allowed |
| `hpf_hz` | high-pass corner, 0..500 Hz (0 off) |
| `dc_block` | DC blocker, `1` on, `0` off |
| `mic.N` | mic N's position `x,y,z` in metres, each \|value\| <= 1; every `mic.N` or none |

Coordinates are metres: x along the lid edge, left to right as seen by the user; y toward the
user; z up. Azimuth is measured in the x-y plane: 0 degrees points toward the user, +90 degrees
along +x.

Validation rejects NaN or infinite numbers, zero aperture (the spatial modes need two mics more
than 1 mm apart and a largest spacing of at least 5 mm), duplicate positions, a channel count
that differs from the stream's, an unverified file, a stale one (measured more than
`max_age_days` ago, or in the future), a kernel that does not match the prefix, and a layout that
is not the captured stream's. With any of these, `beam` and `track` report **UNAVAILABLE** and
refuse to start (`run` exits 2; `set-mode` is refused and counted in `refused_switches`), while
`raw` and `omni` keep working. `omni` applies the file's gains, polarities and delays only once it
is verified.

`g16-mic check-calib FILE [--source NODE_NAME] [--channels N]` prints which modes the file
allows and why the others are UNAVAILABLE.

## Command line

```
g16-mic run --source NODE_NAME [--calib FILE] [--mode raw|omni|beam|track] [--steer-az DEG] [--seconds N]
g16-mic status
g16-mic set-mode raw|omni|beam|track
g16-mic check-calib FILE [--source NODE_NAME] [--channels N]
g16-mic --version
```

Exit codes: 0 ok; 1 `check-calib` found the spatial modes unavailable, or the daemon failed; 2 a
refused source, an unavailable mode or a calibration that does not parse; 3 not running
(`status`, `set-mode`) or already running (`run`); 64 usage errors.

While it runs, the status file `$XDG_RUNTIME_DIR/g16-mic/status` (what `g16-mic status` prints)
is rewritten about four times a second and removed on stop. One `key=value` a line: `pid`,
`source`, `source_state` (waiting, connected, refused), `refuse_reason`, `mode_requested`,
`mode_active`, `spatial` (available or UNAVAILABLE), `spatial_reason`, `omni` (calibrated or
uncalibrated), `degraded`, `confidence`, `doa_az_deg`, `steer_az_deg`, `vad`, `frames_in`,
`frames_out`, `blocks`, `fallbacks`, `mode_switches`, `refused_switches`, `nonfinite_samples`,
`limiter_blocks`, `telemetry_dropped`, `ring_overflow`, `ring_underflow`, `reconnects`,
`wrong_links`, then the delivery and real-time keys below (in the file's order: `rt_*`, `queue_*`,
`late_runs`, `trigger_*`, `capture_gap`, the loss counters, `tail_flushed`, `eos_pad`). Sample counts are frames times the
output's channels (both outputs summed).

- `ring_overflow`: every sample lost between the capture and the outputs, whatever the cause (the
  oldest queued audio dropped when the bound is exceeded, an oversize cycle, a stale tail dropped
  at reconnect, `drain_lost`, `source_lost_tail`). It stays 0 in steady state and at an ordinary
  stop. Quiet quanta dropped by the latency recovery are not in it (`latency_trimmed_frames`).
- `latency_trimmed_frames`: samples withheld by the quiet-only latency recovery (whole cycles with
  every channel below -60 dBFS, both outputs alike, summed over both), never reset. Not speech,
  not part of `ring_overflow`. `latency_trimmed_cycles`: the number of trims (each one cycle
  from both outputs).
- `ring_underflow`: samples the outputs delivered as zeros for want of audio. It stays 0 in steady
  state.
- `eos_pad`: zero samples that complete the last quantum at the end of a stream (a stop or a
  source loss), so the last buffer is whole. Not a loss, not an underflow.
- `rt_requested`: 1 if g16-mic asked `libpipewire-module-rt` for real-time scheduling.
- `rt_status`: `realtime`, `not-realtime`, or `unknown` (no audio cycle observed yet).
- `rt_policy`: the audio thread's observed scheduling policy (`fifo`, `rr`, `other`, `batch`,
  `idle`, `unknown`).
- `rt_priority`: its observed scheduling priority.
- `rt_reason`: why it is not real-time (e.g. the `RLIMIT_RTPRIO` value and that RTKit or the
  portal did not grant it); empty when it is.
- `queue_capacity_cycles`: the queue's capacity per output, in capture cycles (8).
- `queue_bound_ms`: the most latency the queue can add at the current quantum.
- `queue_max_depth_cycles`: the deepest any output queue has been, in cycles (never above the
  capacity).
- `queue_added_frames`: the latency the queue adds now, in frames (the larger of the two
  outputs'); 0 in steady state, raised by a late or refused output cycle until a quiet-cycle trim,
  a stop, a reconnect or an overflow.
- `queue_max_added_frames`: the most latency the queue has added so far, in frames.
- `queue_max_added_ms`: the same in milliseconds (never above `queue_bound_ms`).
- `late_runs`: output runs that found more than one cycle queued (an earlier cycle of that output
  was late or refused; it still delivered one quantum).
- `trigger_refused`: output triggers PipeWire refused while a consumer was linked (the audio waits
  in the queue, not lost).
- `trigger_errno`: the errno of the last refused trigger, 0 if none.
- `capture_gap`: input frames that never reached g16-mic (the capture's graph clock jumped:
  starvation, a stopped process). This is input never seen, not output loss; it is not part of
  `ring_overflow`.
- `stale_dropped`: samples of a previous source dropped at reconnect, never delivered.
- `late_link_discarded`: backlog discarded when a consumer linked late.
- `drain_lost`: samples not delivered by the 500 ms stop drain.
- `source_lost_tail`: samples of a lost source not delivered within 50 ms: the engine tail plus
  everything still queued, per output.
- `tail_flushed`: engine tail frames flushed into the outputs at stops and source losses.

While no source is captured (and no tail is being delivered), both outputs are inactive: they
carry nothing rather than stalling their consumer's graph.

## Opting in

1. Find the internal microphone's `node.name`: `wpctl status` lists the sources with their ids;
   `wpctl inspect <id>` shows `node.name`. On the G16 today it is
   `alsa_input.pci-0000_65_00.6.analog-stereo` (2 channels).
2. `g16-mic run --source alsa_input.pci-0000_65_00.6.analog-stereo --mode omni`
3. In the application, pick **G16 mic (processed)** (`g16_mic_processed`) as its microphone.

### Echo cancellation (optional)

g16-mic has no echo canceller, suppressor or gain control of its own. For echo cancellation, link
the shipped default fragment, which loads PipeWire's own `libpipewire-module-echo-cancel` with its
WebRTC backend:

```
mkdir -p ~/.config/pipewire/pipewire.conf.d
ln -s /usr/share/omarchy-asus-g16-mic/pipewire/g16-mic-aec.conf ~/.config/pipewire/pipewire.conf.d/
systemctl --user restart pipewire pipewire-pulse wireplumber
```

The chain is then: the G16 mics -> g16-mic (calibration, then omni, beam or track) ->
`g16_mic_processed` -> WebRTC echo canceller, with the playback (default) sink's monitor as its
reference -> no noise suppression -> no gain control -> `g16_mic_clean`. Pick `g16_mic_clean` in
the application instead of `g16_mic_processed`.

Noise suppression is off on purpose: keep every word. When it is on, PipeWire's WebRTC backend
fixes its level at high and reads no setting to lower it, and suppression that strong can take
quiet or trailing words away with the noise. This fragment removes only the echo of what the
machine plays; background noise stays in the signal.

#### Noise suppression, high (opt-in, word-loss risk)

If the noise is the problem, the second fragment `g16-mic-aec-ns-high.conf` is the same echo
canceller plus PipeWire's noise suppressor at its fixed high level (gain control still off). It
has its own node names and adds `g16_mic_clean_ns` instead of `g16_mic_clean`. Link one of the two
fragments, not both: both would capture `g16_mic_processed` and run two echo cancellers.

**Check it on the G16 before relying on it: speak quietly, let sentences trail off, and talk over
playback, then listen for missing or clipped words. If words go missing, use the default fragment
instead.**

```
mkdir -p ~/.config/pipewire/pipewire.conf.d
ln -s /usr/share/omarchy-asus-g16-mic/pipewire/g16-mic-aec-ns-high.conf ~/.config/pipewire/pipewire.conf.d/
systemctl --user restart pipewire pipewire-pulse wireplumber
```

Pick `g16_mic_clean_ns` in the application.

## Undo, exactly

1. Stop g16-mic: Ctrl-C in its terminal, or `pkill -INT -x g16-mic`.
2. If you linked the echo-cancel fragment (`g16_mic_clean`):
   `rm ~/.config/pipewire/pipewire.conf.d/g16-mic-aec.conf`, then
   `systemctl --user restart pipewire pipewire-pulse wireplumber`.
3. If you linked the noise-suppression fragment (`g16_mic_clean_ns`):
   `rm ~/.config/pipewire/pipewire.conf.d/g16-mic-aec-ns-high.conf`, then
   `systemctl --user restart pipewire pipewire-pulse wireplumber`.
4. If you made a calibration file: `rm -r ~/.config/g16-mic`.
5. `sudo pacman -R omarchy-asus-g16-mic`.

## Tests

`meson test` runs in the PKGBUILD's `check()` and in `tests/channel/g16-mic.sh` (which also checks
the recipe statically, both fragments included). All signals are synthetic, generated in the
tests; no recorded audio.
Covered: arbitrary callback sizes with exact sample continuity; impulse delay; beam sign, unity
gain on target, headroom and chunk continuity; two talkers with the interferer louder (the target
is retained); quiet onsets and endings kept; pauses held; tracking hysteresis and bounded slew;
invalid geometry, NaN and zero aperture; an unverified or stale layout gives UNAVAILABLE; bounded
queues under overload with their drop counters; the source matcher never picks a monitor or an
unrelated mic (fake node lists); crossfade alignment and the engine's tail flush.

`test_handoff` drives the capture-to-outputs hand-off on a simulated graph schedule with a real
engine (uncalibrated omni, 2 channels), no PipeWire. Every scenario runs through a model of the
old two-slot hand-off (RED: it loses audio) and the queue (GREEN: it delivers it, bit-exact):
markers and quiet speech bursts (-40 dBFS) in the last cycles before a stop all arrive; output
still queued at the stop is delivered; a stalled consumer during the drain loses exactly what is
left, counted, in bounded time; a late listener starts at current audio at exactly the engine
latency, also when the output runs before the capture's cycle (the schedule that left a raw
listener one cycle behind); the quiet-only latency recovery trims only quiet cycles, never a
marker or a -40 dBFS quiet speech burst, keeps both outputs aligned, brings the latency back to
the target and counts `latency_trimmed_frames` exactly; a burst at the live test's step-10 level
(2^-5 of the test signal, about -50 dBFS, above the -60 dBFS threshold) is never trimmed, while
a cycle below the threshold may be; a disconnect and
reconnect never puts the old tail into the new stream (counted); refused or late output triggers
keep their audio in the queue with zero loss, the added latency bounded and reported; every output
buffer holds exactly one quantum; an overload beyond the bound keeps the queue and latency
bounded, drops the oldest audio and counts it exactly, and delivery is contiguous afterwards.

`test_aec` runs the WebRTC echo canceller (the library PipeWire's module uses, in a test-only
binary) with each fragment's settings, checked against the fragment files. With the default
(echo cancellation only): a delayed reference, a delay the library must find, slow clock drift,
and double talk, where the near-end speech must survive (retained energy and correlation, not
only echo reduction). With the opt-in noise-suppression-high settings, separately: double talk,
a near-end-only control and the echo reduction again; it prints how much near-end speech they
keep next to the default (the difference in dB) and asserts only the absolute floors for keeping
words.

`test_pw_live` runs g16-mic against a live PipeWire, isolated from the desktop. It starts a
private PipeWire daemon and a private WirePlumber (policy only, every device monitor and D-Bus
off), both under one temporary directory with their own `HOME`, `XDG_RUNTIME_DIR`,
`PIPEWIRE_RUNTIME_DIR` and socket name; before any client runs it checks that the daemon on that
socket is the one it started. The daemon's only devices are a dummy driver and a null sink; no
ALSA, Bluetooth, Pulse or JACK module is loaded, so no real microphone or speaker is touched and
nothing is audible. Two synthetic 2-channel sources (`test_g16_mic` and a decoy, `decoy_usb_mic`)
feed generated signals. It checks: `g16_mic_processed` (1 channel, MONO, F32) and `g16_mic_raw`
(the source's channels and positions, F32) appear and the status says connected; only the named
source is linked into the capture, never the decoy or the null sink's monitor; 3 s of each output,
tapped on the private socket, match the input (raw bit for bit, processed equal to an offline omni
of the same frames, both at the documented latency: exactly the engine latency, 272 frames for
uncalibrated omni, because g16-mic processes each capture cycle and hands it to both outputs
inside the same PipeWire graph cycle (the outputs are trigger-driven by the capture, as
`module-filter-chain` does, with the queue at its target fill, one quantum per buffer); when the
source is removed g16-mic waits and captures nothing, and when a source of the same name comes
back it reconnects to that one only and raw is again the input bit for bit, at the same 272-frame
latency (step 6: no cycle hidden in PipeWire's adapter, and a raw reader linking while g16-mic
runs is not left one cycle behind, 1296 frames); a source on its own driver and clock, read on both outputs for 20 s, half of
it under CPU load (step 9), shows no `ring_overflow` or `ring_underflow` growth and raw stays
bit-exact with no repeats, and its accounting is exact: every raw gap in its tap must equal what
g16-mic counted over the window: `capture_gap` + `latency_trimmed_frames` / 3 + the raw share of
`ring_overflow` + `late_link_discarded` (those are samples summed over both outputs, 2 raw + 1
processed a frame, so the raw share must be exactly none, half or a third), and a gap no counter
accounts for fails the step; `g16-mic run` on the sink's monitor is refused (exit 2); SIGTERM exits 0 within 3 s with
the nodes and status file gone and no process left; the decoy never streamed. Steps 10 to 14
start fresh g16-mic runs: (10) stop drain: a marker burst in the last 100 ms before SIGTERM, and
the last accepted cycle, arrive on both outputs (raw bit-exact, processed matching an offline
engine) with zero `drain_lost`; its source is quiet speech, the test signal scaled by 2^-5
(peak 0.003125, about -50 dBFS), about 10 dB above the -60 dBFS threshold of the quiet-only
latency trim, so the trim cannot legitimately fire inside the burst the step needs intact, and
the step asserts `latency_trimmed_frames` +0 through the drain; (11) source loss and reconnect: the source is removed mid-stream,
its tail (engine tail plus queued audio) is delivered or counted exactly as `source_lost_tail`, and
after it comes back the new stream starts at the engine latency and contains no samples of the
old one; (12) controlled contention resembling the original failure (load about 18 on 16
cores): `nproc` busy loops at nice 0, g16-mic without real time, the load average, `nproc` and
the RT status recorded before and during, and still no `ring_overflow` or `ring_underflow`
growth, contiguous raw with no zero fills, and `latency_trimmed_frames` 0 (the step's signal
has no quiet cycles); (13) a separate
overload and recovery test: g16-mic is stopped (SIGSTOP) for longer than the queue bound, the
queue and added latency stay within the bound, and the raw tap loses exactly what the counters
say (input the capture never saw, `capture_gap`, plus the queue's counted drops), and afterwards
raw is contiguous again in steady state; (14) a consumer-only stall: the raw output's only tap
(not g16-mic) is stopped (SIGSTOP) for longer than the queue bound; g16-mic keeps running, its
queue depth and added latency never pass the bound, and if the stall back-pressured the output
(its queue filled and dropped the oldest audio) the tap misses exactly `capture_gap` plus
`ring_overflow` / 2 frames and is the newest audio in order after the gap; otherwise the loss
was the consumer's own and g16-mic's counters stay clean (the test logs which case ran). The
test output records
the RT status and the load conditions of each step. Every process it
starts is stopped on every exit path and its temporary directory is removed. Steps 9 and 12
must not pass on a host that is already busy: if other work holds the 1-minute load average
above `nproc`/2 when either is about to start, it prints `SKIP-LOAD 9: ...` or `SKIP-LOAD 12:
host already at load X from other work` and the whole test exits 77 (skip), unless
`G16MIC_LIVE_STRICT=1` is set; then it waits for the load to fall below `nproc`/2 and runs, and
fails if it does not. The two waits share one 10-minute budget for the whole run, and meson's
timeout for `test_pw_live` is 1020 s (the 600 s wait plus about 420 s of the test's own runtime),
so a strict run waits rather than times out. `tests/channel/g16-mic.sh` fails a SKIP-LOAD skip
(a skip does not pass) and its message names SKIP-LOAD and `G16MIC_LIVE_STRICT=1`. Otherwise
the test skips (exit 77) only where the `pipewire` or `wireplumber` binary is missing; the
PKGBUILD's `checkdepends` makes it run in the clean chroot, and `tests/channel/g16-mic.sh` fails
if it skipped on a host that has both.

## Limitations

- **No verified G16 microphone geometry yet.** `beam` and `track` are UNAVAILABLE on the G16 until
  a measured calibration exists; the example file's positions are illustrative.
- Today's capture is 2 channels from one converter, and whether its channels are independent
  microphones is unproven.
- More than 2 channels need the experimental, default-off kernel capture (#403).
- The live PipeWire path runs only against the private test graph (`test_pw_live`). Untested so
  far: real ALSA capture hardware, the G16's own microphones, the user's WirePlumber policy and
  configuration, and PipeWire's echo-cancel module in a live graph (the live test does not load
  either fragment; `test_aec` checks the library they use, offline).
- The noise-suppression-high fragment's effect on real speech is unmeasured on the G16; its word
  loss there is the open question.
- The echo reference is the default sink's monitor only: sound played through another device (a
  TV, a second sink an application chose) is not cancelled.
- Latency recovery waits for a quiet cycle: during long continuous speech, latency added by late
  cycles (graph xruns) stays until the speech pauses. It is still bounded (8 cycles, 170.7 ms at
  a 1024-frame quantum), and past the bound the oldest audio is dropped and counted as
  `ring_overflow`.
- ODAS is not integrated in this release.
- No hardware audio-quality results yet.

## License

MIT (`LICENSE`).
