# omarchy-asus-g16-mic (EXPERIMENTAL)

`g16-mic` is an opt-in processor for the internal microphones of the ASUS ROG Zephyrus G16
(GA605KM). You run it by hand: it captures exactly one PipeWire source, the one you name, and
offers the result as new PipeWire sources that applications can pick. Nothing starts at install,
nothing is enabled, nothing goes into `/etc` or `pipewire.conf.d`, and the default source never
changes. Part of #400 (#401).

The package is **held** (`HOLD`): CI builds and tests it, nothing publishes it, until the
maintainer's G16 tests pass.

## Modes

| mode | what comes out of `g16_mic_processed` | needs a verified calibration |
|---|---|---|
| `raw` | no speech processing at all: the first mic's channel (`map` entry 0, or stream channel 0 without a verified calibration), bit-exact, no limiter; `g16_mic_raw` (in every mode) carries every captured channel bit-exact, in order, delayed by the same fixed latency as the other modes | no |
| `omni` (default) | the calibrated, delay-matched average of all mics | no (uncalibrated while the file is unverified) |
| `beam` | fractional-delay delay-and-sum toward a fixed direction (`--steer-az`), far-field steering from the mic positions, unity gain on the target, a limiter only at the output | yes |
| `track` | GCC-PHAT direction estimates per block, a confidence from the peak ratio, hysteresis, a bounded slew rate, holding through pauses (an energy voice-activity detector), and omni whenever it is unsure; it never gates to silence | yes |

Switching modes, and every fallback, crossfades between the old and new signal with their delays
matched, so nothing jumps or repeats. Stopping flushes the tail, so the end of a sentence is never
cut.

**Preserve speech.** When tracking is unsure, or a spatial mode cannot run, the output falls back
to the time-aligned calibrated omni signal (or raw, if omni cannot be built). It never suppresses
to silence. Every fallback is counted (`fallbacks`, `degraded` in the status).

## Nodes

- `g16_mic_processed`: mono, the current mode's output.
- `g16_mic_raw`: every captured channel, untouched.
- `g16_mic_clean`: mono, only with the echo-cancel fragment linked in (below).

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
`wrong_links`.

## Opting in

1. Find the internal microphone's `node.name`: `wpctl status` lists the sources with their ids;
   `wpctl inspect <id>` shows `node.name`. On the G16 today it is
   `alsa_input.pci-0000_65_00.6.analog-stereo` (2 channels).
2. `g16-mic run --source alsa_input.pci-0000_65_00.6.analog-stereo --mode omni`
3. In the application, pick **G16 mic (processed)** (`g16_mic_processed`) as its microphone.

### Echo cancellation and noise suppression (optional)

g16-mic has no suppressor or gain control of its own. For those, link the shipped fragment, which
loads PipeWire's own `libpipewire-module-echo-cancel` with its WebRTC backend:

```
mkdir -p ~/.config/pipewire/pipewire.conf.d
ln -s /usr/share/omarchy-asus-g16-mic/pipewire/g16-mic-aec.conf ~/.config/pipewire/pipewire.conf.d/
systemctl --user restart pipewire pipewire-pulse wireplumber
```

The chain is then: the G16 mics -> g16-mic (calibration, then omni, beam or track) ->
`g16_mic_processed` -> WebRTC echo canceller, with the playback (default) sink's monitor as its
reference -> one noise suppressor (its level is fixed by PipeWire's WebRTC backend; there is no
second one) -> no gain control -> `g16_mic_clean`. Pick `g16_mic_clean` in the application
instead of `g16_mic_processed`.

## Undo, exactly

1. Stop g16-mic: Ctrl-C in its terminal, or `pkill -INT -x g16-mic`. Endings are flushed before it
   exits.
2. If you linked the echo-cancel fragment:
   `rm ~/.config/pipewire/pipewire.conf.d/g16-mic-aec.conf`, then
   `systemctl --user restart pipewire pipewire-pulse wireplumber`.
3. If you made a calibration file: `rm -r ~/.config/g16-mic`.
4. `sudo pacman -R omarchy-asus-g16-mic`.

## Tests

`meson test` runs in the PKGBUILD's `check()` and in `tests/channel/g16-mic.sh` (which also checks
the recipe statically). All signals are synthetic, generated in the tests; no recorded audio.
Covered: arbitrary callback sizes with exact sample continuity; impulse delay; beam sign, unity
gain on target, headroom and chunk continuity; two talkers with the interferer louder (the target
is retained); quiet onsets and endings kept; pauses held; tracking hysteresis and bounded slew;
invalid geometry, NaN and zero aperture; an unverified or stale layout gives UNAVAILABLE; bounded
queues under overload with their drop counters; the source matcher never picks a monitor or an
unrelated mic (fake node lists); crossfade alignment and the tail flush; and the WebRTC echo
canceller (the library PipeWire's module uses, in a test-only binary) with a delayed reference,
slow clock drift and double talk, where the near-end speech must survive (retained energy and
correlation, not only echo reduction).

## Limitations

- **No verified G16 microphone geometry yet.** `beam` and `track` are UNAVAILABLE on the G16 until
  a measured calibration exists; the example file's positions are illustrative.
- Today's capture is 2 channels from one converter, and whether its channels are independent
  microphones is unproven.
- More than 2 channels need the experimental, default-off kernel capture (#403).
- The PipeWire host's live path (registry matching, linking, reconnect, the virtual sources) is
  compiled but not exercised against a running PipeWire in CI; it waits for the G16 tests. The
  decisions it makes (which node to capture, whether a spatial mode may run, the processing, the
  status) are the tested functions above.
- The echo reference is the default sink's monitor only: sound played through another device (a
  TV, a second sink an application chose) is not cancelled.
- ODAS is not integrated in this release.
- No hardware audio-quality results yet.

## License

MIT (`LICENSE`).
