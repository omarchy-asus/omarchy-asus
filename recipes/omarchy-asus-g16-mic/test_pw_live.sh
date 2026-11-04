#!/bin/bash
# SPDX-License-Identifier: MIT
# test_pw_live.sh: g16-mic against a private PipeWire, end to end.
#
#   test_pw_live.sh G16MIC_BINARY TEST_PW_HELPER_BINARY
#
# Starts its own PipeWire daemon and WirePlumber, both under one temporary
# directory: their own HOME, XDG_* directories, runtime directory and socket
# name (g16-mic-test-<pid>), with D-Bus disabled. The daemon loads only the
# native protocol, metadata, node/client factories and links; its only
# devices are a dummy driver and a null sink. No ALSA, Bluetooth, Pulse or
# JACK module is loaded, so it never touches a real microphone, speaker or
# the desktop's daemon, and it makes no sound. Before any client runs, the
# test checks that the socket it talks to is the one it created and that the
# daemon behind it reports the unique name; otherwise it stops.
#
# Then, each step a PASS/FAIL line:
#   1. two synthetic microphones: decoy_usb_mic and test_g16_mic (2 channels
#      each, test_pw_helper source), next to the null sink's monitor;
#   2. `g16-mic run --source test_g16_mic --mode omni` with no calibration
#      file (omni, uncalibrated: latency 256 + 16 = 272 frames);
#   3. g16_mic_processed (1 channel, MONO) and g16_mic_raw (the source's
#      channels, F32) appear and the status says connected;
#   4. the only links into g16_mic_capture come from test_g16_mic: never the
#      decoy, never the sink monitor;
#   5. after 3 s with nobody reading the outputs, both are tapped for 3 s: raw
#      must be the source's frames bit for bit, at exactly the engine latency
#      (272): the capture and both outputs run in the same graph cycle;
#      processed, at the same graph positions, must equal an offline omni
#      engine fed the same frames;
#   6. the source goes away: status waiting, reconnects=1, nothing linked into
#      the capture and the decoy not taken; the source comes back under the
#      same name: connected again, linked only from the new node. A raw
#      reader linked before it came back gets the new source from its first
#      frame: no frame of the old stream (compare --old-log), no gap, at
#      exactly the engine latency plus queue_added_frames, which must be 0;
#      after another 3 s unread, raw is again the new source's frames bit
#      for bit at exactly the engine latency; then a late raw reader links
#      and unlinks 5 times while g16-mic runs, and every one of them must
#      start at current audio: its first frame at exactly the engine latency
#      (latency_first 272, never 1296 = 272 + one 1024-frame cycle behind)
#      and queue_added_frames 0 while it reads (no more than the graph-xrun
#      delay its own tap shows);
#   7. `g16-mic run --source test_null_sink.monitor` is refused (exit 2) and
#      links nothing;
#   9. (runs before 8) the source is replaced by one on its own driver and
#      clock, like a sound card (test_pw_helper source --driver, 300 ppm
#      slow): with readers on both outputs for 22 s, ring_overflow and
#      ring_underflow in the status file must not grow over 20 s of steady
#      state, the second 10 s of it under CPU load (min(nproc, 4) niced busy
#      loops, the test's own children), and raw must be one contiguous run
#      of the source's frames, bit for bit (compare --strict);
#   8. SIGTERM: exit 0 within 3 s, the g16_mic_* nodes and the status file
#      gone, no g16-mic process left;
#  10. stop drain (a fresh g16-mic, a quiet source, readers on both outputs):
#      SIGTERM exits 0 with drain_lost 0 and the whole engine tail flushed;
#      every frame of the last 100 ms before the stop up to and including
#      the last accepted cycle arrives, raw bit for bit and processed as the
#      offline engine with its tail flushed, with no gap or zero fill; the
#      zeros completing the last buffer after the last frame are exactly the
#      stop log's eos_pad / 3 (2 raw + 1 processed channels); later buffers
#      are not judged;
#  11. source removed mid-stream with readers on both outputs: the raw frames
#      missing at the end of the tap's marker sequence x 2 channels equal
#      source_lost_tail's raw share exactly (or 0 and 0); the source comes
#      back and a reader starts at once: no frame of the old stream, no gap,
#      at exactly the engine latency (queue_added_frames 0);
#  12. contention: the source on its own clock, g16-mic without real time
#      (RLIMIT_RTPRIO 0, no D-Bus for RTKit or the portal), nproc nice-0 busy
#      loops for 15 s: ring_overflow and ring_underflow +0, the queue within
#      its bound, raw one contiguous run with no zero-filled frame, and
#      latency_trimmed_frames +0 (the source's signal never has a quiet
#      1024-frame window: uniform noise at -20 dBFS peak on every channel,
#      so the quiet-only latency recovery must never fire here). nproc, the
#      1-minute load average, the RT status and the queue's added latency are
#      printed before the loops and during them. The step first checks the
#      load from other work (see G16MIC_LIVE_STRICT below);
#  13. overload (SIGSTOP of g16-mic for twice queue_bound_ms, at least 400
#      ms), raw read only: the frames missing from the raw tap's marker
#      sequence equal capture_gap + ring_overflow / 2 + latency_trimmed_frames
#      / 2 exactly (trimmed audio is neither delivered nor ring overflow), its
#      zero fills ring_underflow / 2, each term printed; depth and added
#      latency within the bound; then 3 s contiguous with no counter growth
#      (latency_trimmed_frames included), and which mechanism, if any,
#      returned the added latency to the target (quiet trim, oldest-drop
#      overflow, or none: it stays, bounded, while the signal is not quiet);
#  14. a stalled consumer (SIGSTOP of the raw tap, not g16-mic, for twice
#      queue_bound_ms, at least 400 ms): g16-mic keeps running within its
#      bound; if it counted a loss the tap's gap is exactly capture_gap +
#      ring_overflow / 2 + latency_trimmed_frames / 2 and the audio after it
#      is contiguous, otherwise the loss was the consumer's, g16-mic's
#      counters stay clean and the tap is contiguous after its one gap
#      (which case, and what returned the latency, is logged).
# The decoy must never have streamed a buffer.
#
# Environment:
#   G16MIC_LIVE_STRICT  Step 12 measures contention from its own busy loops,
#       so before it starts them it reads the 1-minute load average from
#       /proc/loadavg. If that is above nproc / 2 (load from other work, a
#       build say), the step cannot tell its own contention from the host's:
#       - unset or empty: it prints "SKIP-LOAD 12: host already at load X
#         from other work" and the whole test exits 77 (meson's skip), or 1
#         if an earlier step already failed (a skip never hides a FAIL);
#       - 1: it waits for the load to drop below nproc / 2, re-checking every
#         5 s for at most 10 minutes, and then runs; if the load never drops
#         step 12 FAILs (and steps 13 and 14, which run on its g16-mic, are
#         not run).
#   The run's first lines print nproc, the load average, the RLIMIT_RTPRIO
#   this shell grants and G16MIC_LIVE_STRICT; step 2 prints g16-mic's RT
#   status.
#
# Exit: 0 all passed; 1 a step failed; 77 (meson's skip) when the pipewire or
# wireplumber binary or the helper is missing, so the live path cannot run,
# or when step 12 finds the host already loaded (G16MIC_LIVE_STRICT unset).
# Every process it starts is stopped on every exit path (trap), and nothing
# is written outside its temporary directory, which it removes.
#
# RED -> GREEN. Before this test, the live path of host.c had never run. Run
# against host.c as it was, it finds five host bugs (fixed in host.c, each
# fix commented there):
#   - step 3: g16_mic_raw offered its channels as AUX0 AUX1 whatever the
#     source carried, so it did not have the source's FL FR channels;
#   - steps 5 and 6: the capture callback fed both output rings whether or not
#     anything read them. An unread ring fills up and then refuses new
#     samples, so a consumer linking later got audio from when the ring
#     filled (seconds old): the raw tap's latency check fails and, after the
#     source was replaced, frames of the old source arrive as "not input".
#   - steps 5 and 6: the capture and the outputs had no common node.group,
#     so the outputs ran on whichever driver their consumer brought, not
#     the microphone's clock, and the end-to-end latency drifted;
#   - step 5: the outputs read first-in first-out, so once one of them
#     missed a graph cycle g16_mic_processed sat a quantum away from
#     g16_mic_raw at the same graph position. They then read on the
#     capture's clock, one cycle behind it;
#   - step 9: the outputs read one graph cycle behind the capture by clock
#     position, so a late or overlapping cycle (a busy host, a source on its
#     own driver) made them zero-fill a cycle and then discard one:
#     ring_underflow and ring_overflow grew in steady state and words were
#     lost. host.c now processes each capture cycle and triggers both
#     outputs inside that same cycle (and step 5's latency is exactly the
#     engine's).
# Round 2 (steps 6 and 10-14): an output buffer holding more than one
# quantum is partly kept inside PipeWire's output adapter, uncounted. Run
# against such a host, step 6 sees latency 1296 instead of 272 after the
# reconnect, step 10 misses the last accepted cycle with drain_lost 0, step
# 11 misses 272 raw frames with source_lost_tail +0 and the reconnected
# stream starts 272 frames late, step 12 finds 2048 zero-filled raw frames
# with clean counters, and step 13's tap misses 17408 frames where the
# counters say 18432.
# Round 3 (steps 6 and 12): a raw reader linking while g16-mic runs could
# stay exactly one cycle behind for its whole run (latency 1296 = 272 +
# 1024, queue_added_frames 1024, no zeros or jumps); step 6's late-reader
# repetitions require latency_first 272 on every link. Under nproc busy loops
# on top of unrelated builds (load 43 on 16 cores) step 12 overflowed by
# 8192: sporadic graph xruns ratcheted the queue to its bound with nothing
# to bring the latency back; step 12 now also refuses to judge a host that
# is already loaded by other work (G16MIC_LIVE_STRICT).
# The integrator's first RED run output is recorded in the pull request.

set -u

G16MIC=${1:-}
HELPER=${2:-}

skip() {
    echo "SKIP: $1 not installed; the live PipeWire test cannot run here"
    exit 77
}
command -v pipewire >/dev/null 2>&1 || skip pipewire
command -v wireplumber >/dev/null 2>&1 || skip wireplumber
[[ -n $HELPER && -x $HELPER ]] || skip "test_pw_helper (the second argument)"
if [[ -z $G16MIC || ! -x $G16MIC ]]; then
    echo "FAIL: the g16-mic binary (the first argument) is missing"
    exit 1
fi
PW_BIN=$(command -v pipewire)
WP_BIN=$(command -v wireplumber)

STRICT=${G16MIC_LIVE_STRICT:-}
NPROC=$(nproc 2>/dev/null || echo 2)
loadavg1() { cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo '?'; }
echo "host: nproc=$NPROC loadavg=$(loadavg1) rlimit_rtprio=$(ulimit -r 2>/dev/null || echo '?')" \
    "G16MIC_LIVE_STRICT='$STRICT' (g16-mic's own RT status follows step 2)"

# Always under /tmp: Unix socket paths are short (108 bytes), and a fixed
# place makes a leftover easy to see (ls /tmp/g16mic-pw.*).
T=$(mktemp -d /tmp/g16mic-pw.XXXXXX) || { echo "FAIL: cannot create a temporary directory"; exit 1; }

PIDS=()
LAST_PID=
failed=0
G16LOG=$T/g16mic.log  # the running g16-mic's log (steps 10-12 start their own)

alive() { kill -0 "$1" 2>/dev/null; }
not_alive() { ! kill -0 "$1" 2>/dev/null; }

# poll SECONDS COMMAND...: runs COMMAND every 0.1 s until it succeeds or
# SECONDS pass; never unbounded.
poll() {
    local secs=$1 i
    shift
    for ((i = 0; i < secs * 10; i++)); do
        "$@" && return 0
        sleep 0.1
    done
    return 1
}

cleanup() {
    local i p left=()
    trap - EXIT INT TERM
    # newest first: taps and sources, g16-mic, WirePlumber, then PipeWire
    for ((i = ${#PIDS[@]} - 1; i >= 0; i--)); do
        kill -TERM "${PIDS[i]}" 2>/dev/null
    done
    for ((i = 0; i < 30; i++)); do
        left=()
        for p in "${PIDS[@]}"; do alive "$p" && left+=("$p"); done
        ((${#left[@]} == 0)) && break
        sleep 0.1
    done
    for p in "${left[@]}"; do kill -KILL "$p" 2>/dev/null; done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done
    local rc=0
    for p in "${PIDS[@]}"; do
        if alive "$p"; then
            echo "FAIL: process $p started by this test is still running"
            rc=1
        fi
    done
    if command -v pgrep >/dev/null 2>&1 && pgrep -f -- "$T/" >/dev/null 2>&1; then
        echo "FAIL: a process using $T is still running"
        rc=1
    fi
    # HOME points into $T; give rm the real one back, so a guard that refuses
    # to delete an ancestor of HOME does not stop the test's own cleanup.
    HOME=$REAL_HOME rm -rf -- "${T:?}"
    return "$rc"
}

show_logs() {
    local f logs=(g16mic.log)
    [[ ${G16LOG##*/} != g16mic.log ]] && logs+=("${G16LOG##*/}")
    for f in "${logs[@]}" pw.log wp.log helper.log; do
        [[ -s $T/$f ]] || continue
        echo "--- last lines of $f"
        tail -n 15 "$T/$f" | sed 's/^/    /'
    done
}

on_exit() {
    local rc=$?
    ((rc != 0 && rc != 77)) && show_logs
    cleanup || rc=1
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { echo "PASS: $*"; }
bad() {
    echo "FAIL: $*"
    failed=1
    if [[ -s $G16LOG ]]; then
        echo "  last g16-mic messages:"
        tail -n 6 "$G16LOG" | sed 's/^/    /'
    fi
}
fatal() {
    bad "$*"
    exit 1
}

# start LOG COMMAND...: runs COMMAND in the background, logging to LOG
start() {
    local log=$1
    shift
    "$@" >>"$log" 2>&1 &
    LAST_PID=$!
    PIDS+=("$LAST_PID")
}

# stop_pid PID SECONDS: SIGTERM, wait up to SECONDS, then SIGKILL (status 255).
# Returns the process's exit status.
stop_pid() {
    local p=$1 secs=$2
    kill -TERM "$p" 2>/dev/null
    if ! poll "$secs" not_alive "$p"; then
        kill -KILL "$p" 2>/dev/null
        wait "$p" 2>/dev/null
        return 255
    fi
    wait "$p" 2>/dev/null
}

# ---- the private environment ------------------------------------------------

SOCK=g16-mic-test-$$
REAL_HOME=${HOME:-/}
while IFS= read -r v; do
    case $v in PIPEWIRE_* | WIREPLUMBER_*) unset "$v" ;; esac
done < <(compgen -e)
unset PULSE_SERVER PULSE_RUNTIME_PATH DISPLAY WAYLAND_DISPLAY JACK_DEFAULT_SERVER \
    JOURNAL_STREAM NOTIFY_SOCKET LISTEN_FDS LISTEN_PID LISTEN_FDNAMES
export HOME=$T/home
export XDG_RUNTIME_DIR=$T/xdg
export XDG_CONFIG_HOME=$T/config
export XDG_CONFIG_DIRS=$T/config-dirs
export XDG_STATE_HOME=$T/state
export XDG_DATA_HOME=$T/data
export XDG_CACHE_HOME=$T/cache
export PIPEWIRE_RUNTIME_DIR=$T/pw
export PIPEWIRE_REMOTE=$SOCK
export PIPEWIRE_LOG_SYSTEMD=false
export DBUS_SESSION_BUS_ADDRESS=disabled:
export DBUS_SYSTEM_BUS_ADDRESS=disabled:
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME/pipewire" "$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d" \
    "$XDG_CONFIG_DIRS" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$PIPEWIRE_RUNTIME_DIR" ||
    fatal "cannot create the private directories under $T"
chmod 700 "$XDG_RUNTIME_DIR" "$PIPEWIRE_RUNTIME_DIR"
STATUS=$XDG_RUNTIME_DIR/g16-mic/status

# The daemon: native protocol, metadata, factories, links; a dummy driver and
# a null sink (its monitor ports are the "monitor" g16-mic must not take).
# The quantum is pinned to 1024 so the latency bound is fixed.
cat >"$T/pipewire.conf" <<EOF
context.properties = {
    core.daemon = true
    core.name = $SOCK
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum = 1024
    default.clock.min-quantum = 1024
    default.clock.max-quantum = 1024
    support.dbus = false
    module.x11.bell = false
    mem.warn-mlock = false
    mem.allow-mlock = false
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    # Grants each client its permissions; without it every client stays
    # "busy" after its hello and never sees the graph.
    { name = libpipewire-module-access }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-client-device }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
]
context.objects = [
    { factory = spa-node-factory
        args = {
            factory.name    = support.node.driver
            node.name       = Dummy-Driver
            node.group      = pipewire.dummy
            priority.driver = 20000
        }
    }
    { factory = adapter
        args = {
            factory.name     = support.null-audio-sink
            node.name        = test_null_sink
            node.description = "g16-mic test null sink"
            media.class      = Audio/Sink
            audio.position   = [ FL FR ]
            object.linger    = true
        }
    }
]
EOF

# Every client (the helper, g16-mic) reads this client.conf instead of the
# system one: the same modules, without realtime scheduling or D-Bus.
cat >"$XDG_CONFIG_HOME/pipewire/client.conf" <<'EOF'
context.properties = {
    support.dbus = false
    mem.warn-mlock = false
    mem.allow-mlock = false
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-client-device }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
]
EOF

# WirePlumber: the policy profile only (linking, defaults, metadata), with
# every device monitor and every D-Bus user off, and nothing restored from
# or saved to a state file.
cat >"$XDG_CONFIG_HOME/wireplumber/wireplumber.conf.d/90-g16-mic-test.conf" <<'EOF'
wireplumber.profiles = {
  g16mictest = {
    inherits = [ policy, mixin.stateless ]
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
    monitor.alsa = disabled
    monitor.alsa-midi = disabled
    monitor.bluez = disabled
    monitor.bluez-midi = disabled
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    support.dbus = disabled
    support.system-dbus = disabled
    support.portal-permissionstore = disabled
    script.client.access-portal = disabled
    support.reserve-device = disabled
    support.logind = disabled
    support.modem-manager = disabled
    support.mpris = disabled
    api.notifications = disabled
    hooks.linking.pause-playback = disabled
    hooks.device.profile.find-voice-call = disabled
    hooks.device.routes.automute-alsa = disabled
  }
}
wireplumber.settings = {
  node.stream.restore-target = false
  node.stream.restore-props = false
  node.restore-default-targets = false
  linking.follow-default-target = false
}
EOF

# ---- graph queries (test_pw_helper graph --dump; see test_pw_helper.c) ------

dump() { "$HELPER" graph --dump >"$T/graph.txt" 2>>"$T/helper.log"; }
node_ids() { awk -v want="name=$1" '$1 == "node" && $3 == want { sub(/^id=/, "", $2); print $2 }' "$T/graph.txt"; }
# "out=<name> out_id=<id>" for every link into node $1
links_into() { awk -v want="in=$1" '$1 == "link" && $4 == want { print $3, $5 }' "$T/graph.txt"; }
links_from() { awk -v want="out=$1" '$1 == "link" && $3 == want' "$T/graph.txt"; }
# "channel=<pos> format=<dsp format>" for every output port of node $1
out_ports() { awk -v want="node_name=$1" '$1 == "port" && $4 == want && $5 == "dir=out" { print $6, $8 }' "$T/graph.txt"; }
out_channels() { out_ports "$1" | awk '{ print $1 }' | sort | tr '\n' ' '; }
status_val() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null; }
last_latency() { sed -n 's/.*capturing .* latency \([0-9][0-9]*\) frames.*/\1/p' "$G16LOG" | tail -n 1; }
log_records() { grep -vc '^#' "$1" 2>/dev/null; }
is_num() { [[ $1 =~ ^[0-9]+$ ]]; }
# compare_val FILE KEY: a "KEY=<n>" line of a compare run's output
compare_val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
# Graph xruns: without real time under load a node of the chain (g16-mic's
# data thread, or the tap's) can run late, and PipeWire then runs the
# driver's cycle without it: the tap gets a quantum of silence for a cycle
# g16-mic's output missed, or misses the cycle itself, and the audio waits
# in g16-mic's queue. That delays the stream; it never cuts it. compare
# --allow-delays judges every frame at the engine latency plus the delays
# the tap shows (delay_zero_frames, delay_skip_frames), with no gap, repeat
# or other zero allowed. g16-mic counts the cycles its raw output missed
# (graph_missed_raw_frames); gm0 before a tap starts and xrun_since GM0 after
# it ended report that. delays FILE: a compare's delay_zero_frames +
# delay_skip_frames ("x" if missing).
delays() {
    local z k
    z=$(compare_val "$1" delay_zero_frames)
    k=$(compare_val "$1" delay_skip_frames)
    if is_num "$z" && is_num "$k"; then echo $((z + k)); else echo x; fi
}
gm0() {
    local v
    v=$(status_val graph_missed_raw_frames)
    if is_num "$v"; then echo "$v"; else echo x; fi
}
xrun_since() {
    local v
    v=$(status_val graph_missed_raw_frames)
    if is_num "$1" && is_num "$v"; then echo $((v - $1)); else echo x; fi
}
# load_line WHEN BUSY: the load and real-time conditions, for the log: nproc,
# the 1-minute load average, how many of the test's own busy loops run, the
# running g16-mic's RT status and its queue's added latency (current and
# max) and latency_trimmed_frames
load_line() {
    echo "load ($1): nproc=$NPROC busy=$2 loadavg=$(loadavg1) G16MIC_LIVE_STRICT='$STRICT'" \
        "rt_requested=$(status_val rt_requested) rt_status=$(status_val rt_status) rt_policy=$(status_val rt_policy)" \
        "rt_priority=$(status_val rt_priority) rt_reason=$(status_val rt_reason)" \
        "queue_added_frames=$(status_val queue_added_frames) queue_max_added_ms=$(status_val queue_max_added_ms)" \
        "(bound $(status_val queue_bound_ms)) latency_trimmed_frames=$(status_val latency_trimmed_frames)"
}
rt_known() { [[ $(status_val rt_status) == realtime || $(status_val rt_status) == not-realtime ]]; }

# ---- start the private daemon and session manager ---------------------------

start "$T/pw.log" env PIPEWIRE_CORE="$SOCK" "$PW_BIN" -c "$T/pipewire.conf"
PW_PID=$LAST_PID
sock_ready() { [[ -S $PIPEWIRE_RUNTIME_DIR/$SOCK ]] && alive "$PW_PID"; }
poll 10 sock_ready || fatal "the private PipeWire daemon did not create $PIPEWIRE_RUNTIME_DIR/$SOCK"
dump || fatal "cannot list the private daemon's graph"
core=$(awk '$1 == "core" { sub(/^name=/, "", $2); print $2 }' "$T/graph.txt")
[[ $core == "$SOCK" ]] || fatal "the daemon on the test socket calls itself '$core', not '$SOCK'; stopping before any client runs"
pass "private PipeWire daemon '$SOCK' on its own socket under the test directory"

start "$T/wp.log" "$WP_BIN" --profile=g16mictest
WP_PID=$LAST_PID
wp_ready() { alive "$WP_PID" && dump && grep -q '^metadata .* name=default$' "$T/graph.txt"; }
poll 15 wp_ready || fatal "the private WirePlumber did not come up (no default metadata)"
if grep -q -E '^node .*(alsa=1|bluez=1)' "$T/graph.txt" || grep -q -E '^device .* api=(alsa|bluez5)' "$T/graph.txt"; then
    fatal "the private graph has ALSA or Bluetooth objects"
fi
pass "private WirePlumber up (policy only; no ALSA or Bluetooth objects)"

# ---- 1. sources ---------------------------------------------------------------

start "$T/helper.log" "$HELPER" source --name decoy_usb_mic --channels 2 --log "$T/decoy.log"
start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --log "$T/src1.log"
P_SRC=$LAST_PID
sources_up() { dump && [[ -n $(node_ids decoy_usb_mic) && -n $(node_ids test_g16_mic) ]]; }
if poll 10 sources_up; then
    pass "1. sources decoy_usb_mic and test_g16_mic are in the graph"
else
    fatal "1. the synthetic sources did not appear"
fi

# ---- 2. g16-mic --------------------------------------------------------------

start "$T/g16mic.log" "$G16MIC" run --source test_g16_mic --mode omni --calib "$T/none.conf"
P_G16=$LAST_PID
g16_up() {
    alive "$P_G16" && dump &&
        [[ -n $(node_ids g16_mic_processed) && -n $(node_ids g16_mic_raw) ]] &&
        [[ -n $(out_ports g16_mic_raw) && -n $(out_ports g16_mic_processed) ]] &&
        [[ $(status_val source_state) == connected ]] &&
        links_into g16_mic_capture | grep -q '^out=test_g16_mic '
}
if poll 15 g16_up; then
    pass "2. g16-mic is running and capturing test_g16_mic"
else
    fatal "2. g16-mic did not connect to test_g16_mic within 15 s"
fi
LAT=$(last_latency)
if [[ $LAT == 272 ]]; then
    pass "2. engine latency $LAT frames (omni, uncalibrated: 256 + 16)"
else
    bad "2. engine latency '${LAT}' frames, expected 272 (omni, uncalibrated)"
    [[ $LAT =~ ^[0-9]+$ ]] || LAT=272
fi
poll 2 rt_known
echo "  2. $(load_line "after start" 0)"

# ---- 3. outputs ---------------------------------------------------------------

src_ch=$(out_channels test_g16_mic)
raw_ch=$(out_channels g16_mic_raw)
proc_ports=$(out_ports g16_mic_processed)
if [[ $src_ch == "channel=FL channel=FR " && $raw_ch == "$src_ch" ]] &&
    ! out_ports g16_mic_raw | grep -v -q 'float'; then
    pass "3. g16_mic_raw: 2 F32 channels at the source's positions (${raw_ch% })"
else
    bad "3. g16_mic_raw channels '${raw_ch% }' ($(out_ports g16_mic_raw | tr '\n' ' ')), source '${src_ch% }'"
fi
if [[ $(printf '%s\n' "$proc_ports" | wc -l) == 1 && $proc_ports == "channel=MONO format="*float* ]]; then
    pass "3. g16_mic_processed: 1 F32 channel, MONO"
else
    bad "3. g16_mic_processed ports: '$proc_ports'"
fi
if [[ $(status_val source_state) == connected && $(status_val mode_active) == omni && $(status_val omni) == uncalibrated ]]; then
    pass "3. status: connected, mode omni, uncalibrated"
else
    bad "3. status: source_state=$(status_val source_state) mode_active=$(status_val mode_active) omni=$(status_val omni)"
fi

# ---- 4. links -------------------------------------------------------------------

dump
into=$(links_into g16_mic_capture)
if [[ -n $into ]] && ! grep -q -v '^out=test_g16_mic ' <<<"$into"; then
    pass "4. only test_g16_mic is linked into g16_mic_capture ($(wc -l <<<"$into") links)"
else
    bad "4. links into g16_mic_capture: $(tr '\n' ';' <<<"$into")"
fi
if [[ -z $(links_from decoy_usb_mic) && -z $(links_from test_null_sink) ]]; then
    pass "4. nothing is linked from decoy_usb_mic or the test_null_sink monitor"
else
    bad "4. links from the decoy or the sink monitor: $(links_from decoy_usb_mic) $(links_from test_null_sink)"
fi

# ---- 5. data ------------------------------------------------------------------

sleep 3  # nobody reads the outputs meanwhile: a late consumer must still get current audio
m5=$(gm0)
start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw1.f32" --channels 2 --seconds 3
P_TAP1=$LAST_PID
start "$T/helper.log" "$HELPER" tap --target g16_mic_processed --out "$T/proc1.f32" --channels 1 --seconds 3
P_TAP2=$LAST_PID
wait "$P_TAP1"
r1=$?
wait "$P_TAP2"
r2=$?
if ((r1 == 0 && r2 == 0)); then
    pass "5. tapped 3 s of g16_mic_raw and g16_mic_processed"
else
    bad "5. taps exited $r1 (raw) and $r2 (processed)"
fi
sleep 0.3  # the source log is flushed every 100 ms
x5=$(xrun_since "$m5")
echo "  5. graph xruns of g16_mic_raw over the tap: $x5 frames"
if [[ -s $T/raw1.f32 && -s $T/proc1.f32 ]]; then
    if "$HELPER" compare --input-log "$T/src1.log" --raw "$T/raw1.f32" --processed "$T/proc1.f32" \
        --channels 2 --latency "$LAT" --allow-delays; then
        pass "5. raw is the input bit for bit; processed is the offline omni at the same latency"
    else
        bad "5. the tapped outputs do not match the input (see the compare lines above)"
    fi
else
    bad "5. no tap data to compare"
fi

# ---- 6. remove and re-add the source -----------------------------------------

dump
old_id=$(node_ids test_g16_mic)
stop_pid "$P_SRC" 3
r=$?
((r == 0)) || bad "6. the first test_g16_mic source exited $r"
gone_waiting() { [[ $(status_val source_state) == waiting && $(status_val reconnects) == 1 ]]; }
if poll 10 gone_waiting; then
    pass "6. source removed: status waiting, reconnects=1"
else
    bad "6. after removing the source: source_state=$(status_val source_state) reconnects=$(status_val reconnects)"
fi
absent_ok=1
for round in 1 2; do
    sleep 0.5
    dump || absent_ok=0
    if [[ -n $(links_into g16_mic_capture) || -n $(links_from decoy_usb_mic) || -n $(links_from test_null_sink) ]]; then
        absent_ok=0
        echo "  round $round: $(links_into g16_mic_capture | tr '\n' ';') $(links_from decoy_usb_mic | tr '\n' ';')"
    fi
done
if ((absent_ok)); then
    pass "6. while the source is gone nothing is captured (the decoy is not taken)"
else
    bad "6. something was linked into the capture while test_g16_mic was gone"
fi

# a reader linked before the source comes back sees the new stream from its
# first cycle: no frame of the old source may lead it, and it must start at
# exactly the engine latency (an old tail left anywhere shifts it)
m6a=$(gm0)
start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw6a.f32" --channels 2 --seconds 2
P_TAP6A=$LAST_PID
sleep 0.3  # the reader is linked to g16_mic_raw before the source returns
start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --start 50000000 --log "$T/src2.log"
P_SRC=$LAST_PID
new_id=
reconnected() {
    dump || return 1
    [[ $(status_val source_state) == connected ]] || return 1
    new_id=$(node_ids test_g16_mic)
    [[ -n $new_id && $new_id != *' '* ]] || return 1
    local into
    into=$(links_into g16_mic_capture)
    [[ -n $into ]] && ! grep -q -v -x "out=test_g16_mic out_id=$new_id" <<<"$into"
}
if poll 15 reconnected; then
    pass "6. source back: connected, linked only from the new test_g16_mic (node $new_id; was $old_id)"
else
    bad "6. no reconnect to the new test_g16_mic: state=$(status_val source_state) links: $(links_into g16_mic_capture | tr '\n' ';')"
fi
LAT2=$(last_latency)
[[ $LAT2 =~ ^[0-9]+$ ]] || LAT2=$LAT
sleep 1  # the reader is still reading; the status file is rewritten every 250 ms
qa6=$(status_val queue_added_frames)
wait "$P_TAP6A"
r=$?
sleep 0.3  # the source log is flushed every 100 ms
x6a=$(xrun_since "$m6a")
if ((r == 0)) && "$HELPER" compare --input-log "$T/src2.log" --old-log "$T/src1.log" --raw "$T/raw6a.f32" --channels 2 \
    --latency "$LAT2" --allow-delays --report-gaps --expect-gap 0 >"$T/cmp6a.txt" &&
    [[ $(compare_val "$T/cmp6a.txt" latency_first) == "$LAT2" ]]; then
    pass "6. a reader linked across the reconnect gets the new source from its first frame: no old-stream frame, first frame at latency $LAT2 (+ $(delays "$T/cmp6a.txt") frames of graph-xrun delay later)"
else
    bad "6. a reader linked across the reconnect (tap exit $r) got old-stream frames ($(compare_val "$T/cmp6a.txt" stale_lead_frames) leading, $(compare_val "$T/cmp6a.txt" stale_frames) in all), gaps or a latency other than $LAT2 (first frame at '$(compare_val "$T/cmp6a.txt" latency_first)', + $(delays "$T/cmp6a.txt") frames of graph-xrun delay)"
fi
sed 's/^/    /' "$T/cmp6a.txt" 2>/dev/null
d6a=$(delays "$T/cmp6a.txt")
echo "  reconnect: engine latency $LAT2, queue_added_frames '${qa6}' (want 0 after a clean reconnect, or no more than" \
    "the tap's $d6a frames of graph-xrun delay; g16-mic counted $x6a frames of raw-output misses)"
if is_num "$qa6" && is_num "$d6a" && ((qa6 <= d6a)); then
    pass "6. after the reconnect nothing is queued ahead of the new stream (queue_added_frames $qa6, graph-xrun delay $d6a)"
else
    bad "6. queue_added_frames is '${qa6}' after a clean reconnect, want 0 (graph-xrun delay in the tap: '$d6a')"
fi
sleep 3  # nobody reads the outputs: a later reader must still get current audio
m6b=$(gm0)
start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw2.f32" --channels 2 --seconds 1
P_TAP3=$LAST_PID
sleep 0.7  # the reader is linked and reading
qa6=$(status_val queue_added_frames)
is_num "$qa6" || qa6=x
wait "$P_TAP3"
r=$?
sleep 0.3
x6b=$(xrun_since "$m6b")
# a late reader starts at current audio: at the engine latency, whatever
# was queued before it linked; queue_added_frames then is at most the
# graph-xrun delay its own tap shows
r6=1
((r == 0)) && "$HELPER" compare --input-log "$T/src2.log" --old-log "$T/src1.log" --raw "$T/raw2.f32" --channels 2 \
    --latency "$LAT2" --allow-delays >"$T/cmp6b.txt" && r6=0
sed 's/^/    /' "$T/cmp6b.txt" 2>/dev/null
d6b=$(delays "$T/cmp6b.txt")
l6b=$(compare_val "$T/cmp6b.txt" latency_first)
if ((r6 == 0)) && is_num "$qa6" && is_num "$d6b" && ((qa6 <= d6b)) && [[ $l6b == "$LAT2" ]]; then
    pass "6. after the reconnect raw is the new source's input bit for bit at the engine latency ($LAT2; first frame at $l6b, queue_added_frames $qa6, graph-xrun delay $d6b, g16-mic counted $x6b)"
else
    bad "6. raw after the reconnect (tap exit $r, first frame at latency '$l6b', queue_added_frames $qa6, graph-xrun delay $d6b) does not match the new source at latency $LAT2"
fi

# Late readers, again and again: each links to g16_mic_raw while g16-mic runs
# and must start at current audio, its first frame at exactly the engine
# latency. The round 3 bug left such a reader one whole cycle behind for its
# whole run (latency_first 1296 = 272 + 1024, queue_added_frames 1024, no
# zero or jump to explain it), on some links only, so one reader is not
# enough to see it: 5 link/unlink rounds, each judged on its own.
late_ok=0
late_n=5
for ((i = 1; i <= late_n; i++)); do
    sleep 0.3  # unread between readers
    m=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw6c$i.f32" --channels 2 --seconds 1
    P_TAP6C=$LAST_PID
    sleep 0.7  # linked and reading; the status file is rewritten every 250 ms
    qa=$(status_val queue_added_frames)
    is_num "$qa" || qa=x
    wait "$P_TAP6C"
    r=$?
    sleep 0.3  # the source log is flushed every 100 ms
    x=$(xrun_since "$m")
    rc=1
    ((r == 0)) && "$HELPER" compare --input-log "$T/src2.log" --old-log "$T/src1.log" --raw "$T/raw6c$i.f32" --channels 2 \
        --latency "$LAT2" --allow-delays >"$T/cmp6c$i.txt" && rc=0
    lf=$(compare_val "$T/cmp6c$i.txt" latency_first)
    d=$(delays "$T/cmp6c$i.txt")
    echo "  6. late reader $i of $late_n: tap exit $r, compare exit $rc, first frame at latency '$lf' (want $LAT2)," \
        "queue_added_frames '$qa', graph-xrun delay '$d', g16-mic counted $x frames of raw-output misses"
    if ((rc == 0)) && [[ $lf == "$LAT2" ]] && is_num "$qa" && is_num "$d" && ((qa <= d)); then
        late_ok=$((late_ok + 1))
    else
        sed 's/^/      /' "$T/cmp6c$i.txt" 2>/dev/null
    fi
done
if ((late_ok == late_n)); then
    pass "6. $late_n late readers in a row each started at current audio: first frame at exactly the engine latency $LAT2, nothing queued ahead"
else
    bad "6. only $late_ok of $late_n late readers started at current audio at exactly the engine latency $LAT2 (one cycle behind is $((LAT2 + 1024)))"
fi

# ---- 7. a monitor is refused --------------------------------------------------

timeout -s KILL 10 "$G16MIC" run --source test_null_sink.monitor --seconds 2 >>"$T/g16mic-monitor.log" 2>&1
r=$?
dump
if ((r == 2)) && [[ -z $(links_from test_null_sink) && $(node_ids g16_mic_capture | wc -l) -le 1 ]]; then
    pass "7. g16-mic refuses test_null_sink.monitor (exit 2) and links nothing from it"
else
    bad "7. g16-mic with test_null_sink.monitor exited $r; links from the sink: $(links_from test_null_sink)"
    sed 's/^/    /' "$T/g16mic-monitor.log"
fi

# ---- 9. a source on its own driver, readers on both outputs, CPU load ---------
#
# The real microphone is an ALSA source that drives its own graph. Here the
# helper source is a driver with its own clock (300 ppm slow against the
# system clock), in a node.group of its own, so g16-mic's capture and outputs
# run on its cycles. Nothing may be dropped or repeated in steady state.

stop_pid "$P_SRC" 3
r=$?
((r == 0)) || bad "9. the second test_g16_mic source exited $r"
src_waiting() { [[ $(status_val source_state) == waiting ]]; }
poll 10 src_waiting || bad "9. after removing the source: source_state=$(status_val source_state)"
start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --driver --ppm 300 \
    --start 5000000 --log "$T/src3.log"
P_SRC=$LAST_PID
step9=1
if poll 15 reconnected; then
    pass "9. a source on its own driver is connected and the only one linked into the capture (node $new_id)"
else
    bad "9. no connect to the driving test_g16_mic: state=$(status_val source_state) links: $(links_into g16_mic_capture | tr '\n' ';')"
    step9=0
fi
src_driving_in() { grep -q '^# source: driving$' "$1"; }
src_driving() { src_driving_in "$T/src3.log"; }
if ((step9)); then
    if poll 5 src_driving; then
        pass "9. the source drives its own graph cycles"
    else
        if grep -q '^# source: not driving$' "$T/src3.log"; then
            bad "9. source: not driving (another driver ran its cycles; the own-clock case was not tested)"
        else
            bad "9. the source never reported driving a cycle"
        fi
        step9=0
    fi
fi
if ((step9)); then
    m9=$(gm0)
    # for the log: the counters that explain a gap in the tap (capture_gap:
    # input the capture never got; late_link_discarded: a start-window
    # restart; latency_trimmed_frames: a quiet-cycle trim)
    d9_keys=(capture_gap late_link_discarded latency_trimmed_frames ring_overflow)
    d9_0=()
    for k in "${d9_keys[@]}"; do d9_0+=("$(status_val "$k")"); done
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw9.f32" --channels 2 --seconds 22
    P_TAP9R=$LAST_PID
    start "$T/helper.log" "$HELPER" tap --target g16_mic_processed --out "$T/proc9.f32" --channels 1 --seconds 22
    P_TAP9P=$LAST_PID
    sleep 2  # settle: both readers linked
    ov0=$(status_val ring_overflow)
    un0=$(status_val ring_underflow)
    sleep 10  # steady state, idle
    n_busy=$(nproc 2>/dev/null || echo 2)
    ((n_busy > 4)) && n_busy=4
    busy=()
    for ((i = 0; i < n_busy; i++)); do
        start /dev/null nice -n 19 bash -c 'while :; do :; done'
        busy+=("$LAST_PID")
    done
    sleep 10  # steady state, under load
    for p in "${busy[@]}"; do stop_pid "$p" 2; done
    ov1=$(status_val ring_overflow)
    un1=$(status_val ring_underflow)
    if [[ $ov0 =~ ^[0-9]+$ && $ov1 =~ ^[0-9]+$ && $un0 =~ ^[0-9]+$ && $un1 =~ ^[0-9]+$ ]]; then
        d_ov=$((ov1 - ov0))
        d_un=$((un1 - un0))
        if ((d_ov == 0 && d_un == 0)); then
            pass "9. no ring overflow or underflow in 20 s with the source on its own driver, 10 s of it under CPU load (overflow +$d_ov, underflow +$d_un)"
        else
            bad "9. ring overflow or underflow in 20 s with the source on its own driver, 10 s of it under CPU load (overflow +$d_ov, underflow +$d_un)"
        fi
    else
        bad "9. the status file has no ring counters: ring_overflow '$ov0' -> '$ov1', ring_underflow '$un0' -> '$un1'"
    fi
    wait "$P_TAP9R"
    r1=$?
    wait "$P_TAP9P"
    r2=$?
    if ((r1 == 0 && r2 == 0)); then
        pass "9. tapped 22 s of g16_mic_raw and g16_mic_processed"
    else
        bad "9. taps exited $r1 (raw) and $r2 (processed)"
    fi
    sleep 0.3  # the source log is flushed every 100 ms
    x9=$(xrun_since "$m9")
    d9=()
    for i in "${!d9_keys[@]}"; do
        v=$(status_val "${d9_keys[i]}")
        if is_num "$v" && is_num "${d9_0[i]}"; then d9+=("${d9_keys[i]} +$((v - d9_0[i]))"); else d9+=("${d9_keys[i]} x"); fi
    done
    echo "  9. graph xruns of g16_mic_raw over the tap: $x9 frames; over the tap: ${d9[*]};" \
        "$(load_line "end of step 9" 0)"
    if [[ -s $T/raw9.f32 ]] && "$HELPER" compare --strict --allow-delays --input-log "$T/src3.log" --raw "$T/raw9.f32" --channels 2; then
        pass "9. raw is the source's frames bit for bit with no gaps or repeats across the window (zero fills only as graph-xrun delays; g16-mic counted $x9 frames of raw-output misses)"
    else
        bad "9. raw has gaps, repeats or zero fills with the source on its own driver (see the compare lines above)"
    fi
fi

# ---- 8. SIGTERM ---------------------------------------------------------------

stop_pid "$P_G16" 3
r=$?
if ((r == 0)); then
    pass "8. g16-mic stopped on SIGTERM with exit 0 within 3 s"
else
    bad "8. g16-mic exit status $r after SIGTERM (255: still running after 3 s, killed)"
fi
dump
if [[ -z $(node_ids g16_mic_processed) && -z $(node_ids g16_mic_raw) && -z $(node_ids g16_mic_capture) ]]; then
    pass "8. g16_mic_processed, g16_mic_raw and g16_mic_capture are gone"
else
    bad "8. g16-mic nodes left in the graph: $(grep -E '^node .* name=g16_mic_' "$T/graph.txt" | tr '\n' ';')"
fi
if [[ ! -e $STATUS ]] && not_alive "$P_G16"; then
    pass "8. status file removed; no g16-mic process left"
else
    bad "8. status file or g16-mic process left behind"
fi

# ---- steps 10-14: fresh g16-mic runs, after step 8 ----------------------------
#
# Steps 10, 11 and 12 each start their own g16-mic (the one of steps 2-9 is
# gone, so the output node names are unique again) with its own status
# directory, so a run's counters and its status file's removal are its own;
# steps 13 and 14 run on step 12's.

# status counters snapshotted around an event (counters, delta)
COUNTERS=(ring_overflow ring_underflow capture_gap stale_dropped late_link_discarded source_lost_tail
    drain_lost trigger_refused late_runs tail_flushed eos_pad latency_trimmed_frames)
# counters: the COUNTERS values from the status file, space separated ("x" if missing)
counters() {
    local k v out=()
    for k in "${COUNTERS[@]}"; do
        v=$(status_val "$k")
        [[ $v =~ ^[0-9]+$ ]] || v=x
        out+=("$v")
    done
    echo "${out[*]}"
}
# delta BEFORE AFTER KEY: how much KEY grew between two counters snapshots, or "x"
delta() {
    local -a a b
    local i
    read -r -a a <<<"$1"
    read -r -a b <<<"$2"
    for i in "${!COUNTERS[@]}"; do
        [[ ${COUNTERS[i]} == "$3" ]] || continue
        if [[ ${a[i]:-x} == x || ${b[i]:-x} == x ]]; then echo x; else echo $((b[i] - a[i])); fi
        return
    done
    echo x
}
# queue_bounded STEP WHAT: the queue's observed depth and added latency are
# within its bound (queue_max_depth_cycles <= queue_capacity_cycles,
# queue_max_added_ms <= queue_bound_ms); a PASS or FAIL line
queue_bounded() {
    local qd qc qm qb
    qd=$(status_val queue_max_depth_cycles)
    qc=$(status_val queue_capacity_cycles)
    qm=$(status_val queue_max_added_ms)
    qb=$(status_val queue_bound_ms)
    if is_num "$qd" && is_num "$qc" && ((qc > 0 && qd <= qc)) &&
        awk -v m="$qm" -v b="$qb" 'BEGIN { exit !(m ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/ && b > 0 && m + 0 <= b + 0) }'; then
        pass "$1. the queue stayed within its bound $2 (depth $qd of $qc cycles, max added latency $qm ms of $qb ms)"
    else
        bad "$1. the queue left its bound $2: queue_max_depth_cycles '$qd' of '$qc', queue_max_added_ms '$qm' of '$qb'"
    fi
}
src_waiting() { [[ $(status_val source_state) == waiting ]]; }

# run_g16 TAG [ENV-OR-WRAPPER...]: a fresh g16-mic on test_g16_mic (omni, no
# calibration) with its own status directory $T/xdg<TAG> and log
# $T/g16mic<TAG>.log; ENV-OR-WRAPPER (VAR=value words, then an optional
# wrapper command) go between env and the binary.
run_g16() {
    local tag=$1
    shift
    G16LOG=$T/g16mic$tag.log
    mkdir -p "$T/xdg$tag" && chmod 700 "$T/xdg$tag"
    STATUS=$T/xdg$tag/g16-mic/status
    start "$G16LOG" env XDG_RUNTIME_DIR="$T/xdg$tag" "$@" "$G16MIC" run --source test_g16_mic --mode omni --calib "$T/none.conf"
    P_G16=$LAST_PID
}

# A client config for g16-mic only (steps 12-14): the test's client.conf with
# PipeWire's libpipewire-module-rt loaded first, as the packaged one does, so
# real time is requested through PipeWire's own mechanism. The daemon, the
# helper source and the taps keep the plain client.conf (no real time).
cat >"$XDG_CONFIG_HOME/pipewire/g16-mic-rt.conf" <<'RTCONF'
context.properties = {
    support.dbus = true
    mem.warn-mlock = false
    mem.allow-mlock = false
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-rt
        args = { nice.level = -11 rt.prio = 88 }
        flags = [ ifexists nofail ]
    }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-client-device }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-metadata }
]
RTCONF

# ---- 10. stop drain -----------------------------------------------------------
#
# A quiet source (-50 dBFS peak: quiet speech, above the -60 dBFS latency
# trim threshold, so no cycle of it may be trimmed), taps on both outputs running before and
# after the stop: every frame of the last 100 ms before the stop, up to and
# including the last cycle g16-mic accepted, must arrive, raw bit for bit
# and processed as the offline engine with its tail flushed, with no gap or
# zero fill. The zeros completing the last buffer after the last frame must
# be exactly the counted eos_pad (2 raw + 1 processed channels); buffers
# after that one are not judged.

stop_pid "$P_SRC" 3
r=$?
((r == 0)) || bad "10. the driving test_g16_mic source of step 9 exited $r"
start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --quiet --start 70000000 --log "$T/src10.log"
P_SRC=$LAST_PID
run_g16 10
step10=1
if poll 15 g16_up; then
    pass "10. a fresh g16-mic (own status directory) captures a quiet test_g16_mic"
else
    bad "10. the fresh g16-mic did not connect to the quiet test_g16_mic within 15 s"
    step10=0
fi
LAT10=$(last_latency)
is_num "$LAT10" || LAT10=$LAT
if ((step10)); then
    m10=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw10.f32" --channels 2 --seconds 8
    P_TAP10R=$LAST_PID
    start "$T/helper.log" "$HELPER" tap --target g16_mic_processed --out "$T/proc10.f32" --channels 1 --seconds 8
    P_TAP10P=$LAST_PID
    sleep 3  # both taps linked and reading well before the stop
    qa10=$(status_val queue_added_frames)
    tr10=$(status_val latency_trimmed_frames)
    if ! is_num "$qa10"; then
        bad "10. the status has no queue_added_frames ('$qa10')"
        qa10=0
    fi
    stop_pid "$P_G16" 3
    r=$?
    if ((r == 0)); then
        pass "10. g16-mic exited 0 after SIGTERM, within 3 s, with readers linked"
    else
        bad "10. g16-mic exit status $r after SIGTERM with readers linked (255: killed after 3 s)"
    fi
    # the taps outlive the stop; they end on their own when the outputs go,
    # or here (exit 1 for a short capture is expected; the data is written)
    stop_pid "$P_TAP10R" 3
    r1=$?
    stop_pid "$P_TAP10P" 3
    r2=$?
    ((r1 <= 1 && r2 <= 1)) || bad "10. taps exited $r1 (raw) and $r2 (processed)"
    sleep 0.3  # the source log is flushed every 100 ms
    last_line=$(sed -n 's/.*stop: last accepted cycle at graph position \([0-9][0-9]*\) (\([0-9][0-9]*\) frames).*/\1 \2/p' "$G16LOG" | tail -n 1)
    drain_line=$(sed -n 's/.*stop: drained in \([0-9.][0-9.]*\) ms, tail \([0-9][0-9]*\) frames, drain_lost \([0-9][0-9]*\).*/\1 \2 \3/p' "$G16LOG" | tail -n 1)
    eos_pad=$(sed -n 's/.*stop: drained in .*eos_pad \([0-9][0-9]*\).*/\1/p' "$G16LOG" | tail -n 1)
    gm10=$(sed -n 's/.*stop: drained in .*graph_missed_raw_frames \([0-9][0-9]*\).*/\1/p' "$G16LOG" | tail -n 1)
    if is_num "$gm10" && is_num "$m10"; then x10=$((gm10 - m10)); else x10=x; fi
    last_pos='' last_frames='' drain_ms='' drain_tail='' drain_lost=''
    read -r last_pos last_frames <<<"$last_line"
    read -r drain_ms drain_tail drain_lost <<<"$drain_line"
    echo "  stop log: last accepted cycle at ${last_pos:-?} (${last_frames:-?} frames); drained in ${drain_ms:-?} ms," \
        "tail ${drain_tail:-?}, drain_lost ${drain_lost:-?}, eos_pad ${eos_pad:-?}; queue_added_frames before the stop $qa10," \
        "latency_trimmed_frames before the stop '$tr10' (the quiet source is above the trim threshold: it must stay 0);" \
        "graph xruns of g16_mic_raw over the taps $x10 frames"
    # a fresh g16-mic, a source above the trim threshold: nothing trimmed
    if is_num "$tr10" && ((tr10 == 0)); then
        pass "10. latency_trimmed_frames 0 before the stop (no cycle of the -50 dBFS source is quiet)"
    else
        bad "10. latency_trimmed_frames '$tr10' before the stop (want 0: the -50 dBFS source has no quiet cycle)"
    fi
    if is_num "$drain_lost" && is_num "$drain_tail" && ((drain_lost == 0 && drain_tail == LAT10)); then
        pass "10. the stop drained with drain_lost 0 and the whole $LAT10-frame engine tail flushed ($drain_ms ms)"
    else
        bad "10. stop log: drain_lost '$drain_lost' (want 0), tail '$drain_tail' (want $LAT10)"
    fi
    if is_num "$last_pos" && is_num "$last_frames" && [[ -s $T/raw10.f32 && -s $T/proc10.f32 ]]; then
        # the window: 100 ms (4800 frames) before the last accepted cycle, and the cycle
        win_pos=$((last_pos > 4800 ? last_pos - 4800 : 0))
        win_frames=$((last_pos + last_frames - win_pos))
        # the taps linked to a fresh g16-mic: the engine latency, each
        # counted xrun delaying what follows (queue_added_frames grows by
        # the xruns that left their quantum queued)
        lat10=$LAT10
        if "$HELPER" compare --quiet --input-log "$T/src10.log" --raw "$T/raw10.f32" --processed "$T/proc10.f32" \
            --channels 2 --latency "$lat10" --allow-delays --last-pos "$win_pos" --last-frames "$win_frames" \
            --report-gaps --expect-gap 0 >"$T/cmp10.txt"; then
            pass "10. the last 100 ms before the stop and the last accepted cycle arrived whole ($win_frames frames at graph positions $win_pos..$((win_pos + win_frames - 1)), latency $LAT10 plus the graph-xrun delays before it, g16-mic counted $x10): raw bit for bit, processed with its flushed tail, no gap, no zero fill but delays ($(compare_val "$T/cmp10.txt" last_missing) missing)"
        else
            bad "10. frames of the last 100 ms or of the last accepted cycle are missing or wrong, or raw has gaps or zero fills (last_missing=$(compare_val "$T/cmp10.txt" last_missing), gap_frames_total=$(compare_val "$T/cmp10.txt" gap_frames_total), zero_fill_frames=$(compare_val "$T/cmp10.txt" zero_fill_frames))"
        fi
        sed 's/^/    /' "$T/cmp10.txt"
        eos_z=$(compare_val "$T/cmp10.txt" eos_zero_frames)
        pad_calc=$(((last_frames - lat10 % last_frames) % last_frames))
        echo "  end of stream: raw has $eos_z zero frames after the last frame in its buffer," \
            "$(compare_val "$T/cmp10.txt" after_eos_frames) frames in later buffers (not judged);" \
            "eos_pad ${eos_pad:-?} samples / 3 (2 raw + 1 processed channels) = $(is_num "$eos_pad" && echo $((eos_pad / 3)) || echo '?') frames;" \
            "a ${last_frames}-frame quantum after a $lat10-frame tail leaves $pad_calc"
        if ! is_num "$eos_pad"; then
            bad "10. the stop log does not report eos_pad (want '..., eos_pad <samples>' on the 'stop: drained' line)"
        elif is_num "$eos_z" && ((eos_pad % 3 == 0 && eos_z * 3 == eos_pad)); then
            pass "10. the zeros after the last frame are exactly the counted eos_pad ($eos_z frames x 3 = $eos_pad samples)"
        else
            bad "10. raw has '$eos_z' zero frames after the last frame, eos_pad says $eos_pad samples (want $eos_z x 3)"
        fi
    else
        bad "10. no stop log line or no tap data to check the last cycle with"
    fi
    dump
    if [[ -z $(node_ids g16_mic_processed) && -z $(node_ids g16_mic_raw) && -z $(node_ids g16_mic_capture) ]] &&
        [[ ! -e $STATUS ]] && not_alive "$P_G16"; then
        pass "10. after the drain the g16_mic_* nodes, the status file and the process are gone"
    else
        bad "10. g16-mic nodes, status file or process left after the drain"
    fi
fi
alive "$P_G16" && stop_pid "$P_G16" 3

# ---- 11. source removed mid-stream, then re-added -----------------------------
#
# Readers on both outputs while the source goes: the raw frames missing at
# the end of the tap's marker sequence (after the last delivered one, up to
# the source's last frame) are exactly what source_lost_tail counts (frames
# x channels: 2 raw + 1 processed per frame; both outputs take the same
# cycles), or nothing is missing and nothing counted. The source comes back
# with new frame numbers and a reader starts at once: the new stream must
# carry no frame of the old one, and its latency is the engine latency
# (queue_added_frames 0), not the engine latency plus an old tail.

stop_pid "$P_SRC" 3
start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --start 80000000 --log "$T/src11a.log"
P_SRC=$LAST_PID
run_g16 11
step11=1
if poll 15 g16_up; then
    pass "11. a fresh g16-mic captures test_g16_mic"
else
    bad "11. the fresh g16-mic did not connect within 15 s"
    step11=0
fi
LAT11=$(last_latency)
is_num "$LAT11" || LAT11=$LAT
if ((step11)); then
    m11=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw11a.f32" --channels 2 --seconds 8
    P_TAP11R=$LAST_PID
    start "$T/helper.log" "$HELPER" tap --target g16_mic_processed --out "$T/proc11a.f32" --channels 1 --seconds 8
    P_TAP11P=$LAST_PID
    sleep 2
    c0=$(counters)
    stop_pid "$P_SRC" 3
    r=$?
    ((r == 0)) || bad "11. the source exited $r"
    poll 10 src_waiting || bad "11. after removing the source: source_state=$(status_val source_state)"
    sleep 1  # the 50 ms tail window, then the status file's next rewrite
    c1=$(counters)
    x11=$(xrun_since "$m11")
    echo "  11. graph xruns of g16_mic_raw before the source went: $x11 frames"
    stop_pid "$P_TAP11R" 3
    stop_pid "$P_TAP11P" 3
    d_slt=$(delta "$c0" "$c1" source_lost_tail)
    d_ov=$(delta "$c0" "$c1" ring_overflow)
    # the last frame the capture took is the source's last logged frame (it
    # ran in the same graph cycle as the capture until it went)
    src_last=$(awk '$1 !~ /^#/ && NF == 3 { k = $2 + $3 - 1 } END { if (k != "") print k }' "$T/src11a.log")
    raw_last=
    r=1
    if [[ -s $T/raw11a.f32 ]]; then
        "$HELPER" compare --input-log "$T/src11a.log" --raw "$T/raw11a.f32" --channels 2 --allow-delays \
            --report-gaps --expect-gap 0 >"$T/cmp11a.txt"
        r=$?
        raw_last=$(compare_val "$T/cmp11a.txt" last_frame)
    fi
    if ((r == 0)) && is_num "$src_last" && is_num "$raw_last" && is_num "$d_slt"; then
        miss=$((src_last - raw_last))
        echo "  source lost: last source frame $src_last, last raw frame $raw_last ($miss frames missing from the raw marker" \
            "sequence: $((miss * 2)) raw samples); source_lost_tail +$d_slt (raw share $((d_slt * 2 / 3)) = 2/3 of it)," \
            "ring_overflow +$d_ov, tail_flushed +$(delta "$c0" "$c1" tail_flushed)," \
            "eos_pad +$(delta "$c0" "$c1" eos_pad), raw zeros after the last frame $(compare_val "$T/cmp11a.txt" trailing_zero_frames)"
        if ((miss >= 0 && d_slt % 3 == 0 && miss * 2 == d_slt * 2 / 3)); then
            if ((d_slt == 0)); then
                pass "11. the engine tail and the queues reached the outputs after the source went (0 missing, source_lost_tail 0)"
            else
                pass "11. exactly the counted tail is missing: $miss raw frames x 2 channels = source_lost_tail's raw share $((d_slt * 2 / 3)) ($d_slt over both outputs)"
            fi
        else
            bad "11. $miss raw frames ($((miss * 2)) samples) missing after the source loss, but source_lost_tail grew by $d_slt (raw share $((d_slt * 2 / 3)); want $((miss * 3)) in all)"
        fi
    else
        bad "11. raw before the source loss is not contiguous input, or no counters (compare exit $r, source_lost_tail '$d_slt')"
        sed 's/^/    /' "$T/cmp11a.txt" 2>/dev/null
    fi

    c2=$(counters)
    m11b=$(gm0)
    start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --start 90000000 --log "$T/src11b.log"
    P_SRC=$LAST_PID
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw11b.f32" --channels 2 --seconds 3
    P_TAP11B=$LAST_PID
    if poll 15 reconnected; then
        pass "11. the re-added source is connected (node $new_id)"
    else
        bad "11. no reconnect to the re-added test_g16_mic: state=$(status_val source_state)"
    fi
    sleep 1  # the reader is still reading; the status file is rewritten every 250 ms
    qa11=$(status_val queue_added_frames)
    wait "$P_TAP11B"
    r=$?
    sleep 0.3
    c3=$(counters)
    x11b=$(xrun_since "$m11b")
    LAT11b=$(last_latency)
    is_num "$LAT11b" || LAT11b=$LAT11
    echo "  reconnect: stale_dropped +$(delta "$c2" "$c3" stale_dropped), late_link_discarded +$(delta "$c2" "$c3" late_link_discarded)," \
        "ring_overflow +$(delta "$c2" "$c3" ring_overflow), queue_added_frames '$qa11', engine latency $LAT11b," \
        "graph xruns of g16_mic_raw since $x11b frames"
    if ((r == 0)) && "$HELPER" compare --input-log "$T/src11b.log" --old-log "$T/src11a.log" --raw "$T/raw11b.f32" --channels 2 \
        --latency "$LAT11b" --allow-delays --report-gaps --expect-gap 0 >"$T/cmp11b.txt" &&
        [[ $(compare_val "$T/cmp11b.txt" not_input_frames) == 0 && $(compare_val "$T/cmp11b.txt" stale_frames) == 0 ]]; then
        pass "11. the new stream carries no frame of the old source: only the new source's frames, in order, at the engine latency $LAT11b"
    else
        bad "11. the stream after the reconnect has old-stream frames ($(compare_val "$T/cmp11b.txt" stale_lead_frames) leading, $(compare_val "$T/cmp11b.txt" stale_frames) in all), other non-input frames, gaps or a latency other than $LAT11b (tap exit $r)"
    fi
    sed 's/^/    /' "$T/cmp11b.txt" 2>/dev/null
    d11=$(delays "$T/cmp11b.txt")
    if is_num "$qa11" && is_num "$d11" && ((qa11 <= d11)); then
        pass "11. nothing is queued ahead of the reconnected stream (queue_added_frames $qa11, graph-xrun delay in the tap $d11)"
    else
        bad "11. queue_added_frames is '$qa11' after the reconnect, want 0 (graph-xrun delay in the tap: '$d11')"
    fi
fi
alive "$P_G16" && stop_pid "$P_G16" 3

# ---- 12. contention, no real time ---------------------------------------------
#
# The field failure: a busy host and a g16-mic data thread without real-time
# scheduling. The source drives its own clock (as step 9); g16-mic runs with
# RLIMIT_RTPRIO 0 and both D-Bus addresses pointing at a socket that does not
# exist, so module-rt can get real time neither itself nor from RTKit or the
# portal. nproc busy loops at nice 0 (the test's own children) for 15 s; the
# daemon and the source keep their normal priority. Nothing may be lost or
# zero-filled: a late or refused output cycle waits in the queue (the added
# latency grows, within the bound) and is delivered a quantum at a time.
# The source's signal is uniform noise at -20 dBFS peak on both channels with
# no gap (test_pw_helper.c, sig()): no 1024-frame window of it is quiet
# (peak below -60 dBFS), so the quiet-only latency recovery has nothing it
# may trim and latency_trimmed_frames must stay +0 here.
#
# The load gate: the step judges contention from its own nproc loops. If the
# host is already above nproc / 2 from other work (the round 3 failure ran
# on top of unrelated builds, load 43 on 16 cores), the result says nothing
# about g16-mic: without G16MIC_LIVE_STRICT the test stops here as a skip
# (exit 77; 1 if a step already failed), with G16MIC_LIVE_STRICT=1 it waits
# up to 10 minutes for the load to drop and FAILs step 12 if it does not.

# load_above: the 1-minute load average is above nproc / 2 (or unreadable)
load_above() { awk -v l="$(loadavg1)" -v n="$NPROC" 'BEGIN { exit !(l !~ /^[0-9.]+$/ || l + 0 > n / 2) }'; }
LOAD_WAIT_S=600
step12=1
echo "  12. $(load_line "before step 12, other work only" 0)"
if load_above; then
    if [[ $STRICT != 1 ]]; then
        echo "SKIP-LOAD 12: host already at load $(loadavg1) from other work"
        ((failed)) && exit 1
        exit 77
    fi
    echo "  12. G16MIC_LIVE_STRICT=1: host at load $(loadavg1) from other work, above nproc / 2 = $(awk -v n="$NPROC" 'BEGIN { print n / 2 }');" \
        "waiting up to $((LOAD_WAIT_S / 60)) minutes for it to drop"
    for ((w = 0; w < LOAD_WAIT_S; w += 5)); do
        load_above || break
        sleep 5
    done
    if load_above; then
        bad "12. G16MIC_LIVE_STRICT=1: the host stayed above load nproc / 2 from other work for $((LOAD_WAIT_S / 60)) minutes (now $(loadavg1) on $NPROC); contention not measured (steps 13 and 14 not run)"
        step12=0
    else
        echo "  12. the load dropped to $(loadavg1) after about ${w} s; running"
    fi
fi

stop_pid "$P_SRC" 3
if ((step12)); then
    start "$T/helper.log" "$HELPER" source --name test_g16_mic --channels 2 --driver --ppm 300 \
        --start 100000000 --log "$T/src12.log"
    P_SRC=$LAST_PID
    if ! command -v prlimit >/dev/null 2>&1; then
        bad "12. prlimit (util-linux) is missing; g16-mic cannot be started without real-time rights"
        step12=0
    fi
fi
if ((step12)); then
    run_g16 12 DBUS_SESSION_BUS_ADDRESS="unix:path=$T/no-bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$T/no-bus" \
        PIPEWIRE_CONFIG_NAME=g16-mic-rt.conf prlimit --rtprio=0:0 --
    if poll 15 g16_up && poll 5 src_driving_in "$T/src12.log"; then
        pass "12. g16-mic (RLIMIT_RTPRIO 0, no D-Bus) captures a source that drives its own clock"
    else
        bad "12. g16-mic did not connect to the driving source within 15 s (or the source did not drive)"
        step12=0
    fi
fi
if ((step12)); then
    poll 5 rt_known
    echo "  real time: rt_requested=$(status_val rt_requested) rt_status=$(status_val rt_status) rt_policy=$(status_val rt_policy)" \
        "rt_priority=$(status_val rt_priority) rt_reason=$(status_val rt_reason)"
    if [[ $(status_val rt_status) == not-realtime ]]; then
        pass "12. status reports rt_status=not-realtime (policy $(status_val rt_policy), reason $(status_val rt_reason))"
    else
        bad "12. rt_status is '$(status_val rt_status)', want not-realtime (the contention must run without real time)"
    fi
    m12=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw12.f32" --channels 2 --seconds 19
    P_TAP12R=$LAST_PID
    start "$T/helper.log" "$HELPER" tap --target g16_mic_processed --out "$T/proc12.f32" --channels 1 --seconds 19
    P_TAP12P=$LAST_PID
    sleep 2  # settle: both readers linked
    c0=$(counters)
    n_busy=$NPROC
    echo "  12. $(load_line "before the loops" 0)"
    busy=()
    for ((i = 0; i < n_busy; i++)); do
        start /dev/null nice -n 0 bash -c 'while :; do :; done'
        busy+=("$LAST_PID")
    done
    sleep 7
    echo "  12. $(load_line "during the loops, 7 s in" "$n_busy")"
    sleep 7
    echo "  12. $(load_line "during the loops, 14 s in" "$n_busy")"
    sleep 1
    for p in "${busy[@]}"; do stop_pid "$p" 2; done
    sleep 0.5  # the status file's next rewrite
    c1=$(counters)
    d_ov=$(delta "$c0" "$c1" ring_overflow)
    d_un=$(delta "$c0" "$c1" ring_underflow)
    d_tr=$(delta "$c0" "$c1" latency_trimmed_frames)
    echo "  under load: trigger_refused +$(delta "$c0" "$c1" trigger_refused) (last errno $(status_val trigger_errno))," \
        "late_runs +$(delta "$c0" "$c1" late_runs), capture_gap +$(delta "$c0" "$c1" capture_gap)," \
        "queue_max_depth_cycles $(status_val queue_max_depth_cycles) of $(status_val queue_capacity_cycles)," \
        "queue_max_added_ms $(status_val queue_max_added_ms) (bound $(status_val queue_bound_ms))," \
        "queue_added_frames $(status_val queue_added_frames), latency_trimmed_frames +$d_tr"
    if is_num "$d_ov" && is_num "$d_un" && ((d_ov == 0 && d_un == 0)); then
        pass "12. no ring overflow or underflow over 15 s of $n_busy busy loops without real time (overflow +$d_ov, underflow +$d_un)"
    else
        bad "12. ring overflow +$d_ov, underflow +$d_un over 15 s of $n_busy busy loops without real time"
    fi
    # the signal has no quiet cycle, so the quiet-only recovery must not trim
    if is_num "$d_tr" && ((d_tr == 0)); then
        pass "12. latency_trimmed_frames +0: nothing trimmed from a signal with no quiet cycle"
    else
        bad "12. latency_trimmed_frames +$d_tr (want +0: the source's signal has no quiet 1024-frame window; 'x' means the status file lacks the counter)"
    fi
    queue_bounded 12 "under contention"
    wait "$P_TAP12R"
    r1=$?
    wait "$P_TAP12P"
    r2=$?
    ((r1 == 0 && r2 == 0)) || bad "12. taps exited $r1 (raw) and $r2 (processed)"
    sleep 0.3
    x12=$(xrun_since "$m12")
    echo "  12. graph xruns of g16_mic_raw over the tap: $x12 frames (PipeWire ran cycles without g16-mic's late data thread)"
    if [[ -s $T/raw12.f32 ]] && "$HELPER" compare --strict --allow-delays --input-log "$T/src12.log" --raw "$T/raw12.f32" --channels 2 \
        --report-gaps --expect-gap 0 >"$T/cmp12.txt"; then
        sed 's/^/    /' "$T/cmp12.txt"
        pass "12. raw is one contiguous run of the source's frames across the loaded window: no gap, zero fills only as graph-xrun delays (g16-mic counted $x12 frames of raw-output misses)"
    else
        sed 's/^/    /' "$T/cmp12.txt" 2>/dev/null
        bad "12. raw has gaps, repeats or zero fills under contention (see the compare lines above)"
    fi
fi

# ---- 13. overload and recovery ------------------------------------------------
#
# Deliberate starvation beyond the queue's bound, on step 12's g16-mic (still
# without real time): SIGSTOP for twice queue_bound_ms (at least 400 ms),
# then SIGCONT. Only g16_mic_raw is read here (an unread output queues
# nothing), so the sample counters are the raw output's: frames x 2.
# capture_gap counts the graph frames that went by without g16-mic's
# capture taking a buffer: input that was lost upstream, input the source
# held and delivered late, after the stall, or none at all where the
# source's own clock skipped a cycle without it producing anything (the
# compare's src_clock_skip_frames, from the source's log). Late input is
# not lost: it shows as end-to-end latency (the tap's latency_last against
# latency_first, less the counted xrun zeros and the queue's own change,
# queue_added_frames). So the frames missing from the raw tap's marker
# sequence, plus that late input, plus the source's clock skips, must be
# exactly capture_gap plus ring_overflow / 2 (oldest raw audio the queue
# dropped) plus latency_trimmed_frames / 2 (quiet raw cycles the latency
# recovery dropped: neither delivered nor overflow; it shortens the latency
# and queue_added_frames alike, so it shows only as missing frames), and its
# zero-filled frames exactly ring_underflow / 2 plus the counted graph
# xruns; the queue's depth and added latency stay within the bound;
# afterwards 3 s of steady state must lose and trim nothing. Which
# mechanism, if any, brought the added latency back is printed.

# raw_only: nothing reads g16_mic_processed (steps 13-14 account raw only)
raw_only() { dump && [[ -z $(links_from g16_mic_processed) ]]; }
# stall_ms: twice queue_bound_ms, at least 400 ms
stall_ms() { awk -v b="$(status_val queue_bound_ms)" 'BEGIN { m = 2 * b; if (m != m || m < 400) m = 400; printf "%d", m + 0.5 }'; }
ms_to_s() { awk -v ms="$1" 'BEGIN { printf "%.3f", ms / 1000 }'; }
# latency_back QA_BEFORE QA_AFTER TRIMMED OVERFLOW: which mechanism returned
# the queue's added latency (queue_added_frames) to where it was, for the log
latency_back() {
    if ! is_num "$1" || ! is_num "$2"; then
        echo "unknown (queue_added_frames '$1' -> '$2')"
    elif (($2 > $1)); then
        echo "none yet: the added latency stays at $2 frames (was $1), bounded; only a quiet cycle may be trimmed and this signal has none"
    elif is_num "$3" && (($3 > 0)); then
        echo "quiet trim: latency_trimmed_frames +$3 (queue_added_frames $1 -> $2)"
    elif is_num "$4" && (($4 > 0)); then
        echo "the oldest-drop overflow: ring_overflow +$4 (queue_added_frames $1 -> $2)"
    else
        echo "nothing to return: no latency was added (queue_added_frames $1 -> $2, nothing trimmed or dropped)"
    fi
}

if ((step12)) && alive "$P_G16"; then
    bound=$(status_val queue_bound_ms)
    stop_ms=$(stall_ms)
    poll 5 raw_only || bad "13. g16_mic_processed still has a reader; the raw-only accounting needs none"
    m13=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw13a.f32" --channels 2 --seconds 4
    P_TAP13A=$LAST_PID
    sleep 1  # the reader is linked
    c0=$(counters)
    qa0=$(status_val queue_added_frames)
    kill -STOP "$P_G16"
    sleep "$(ms_to_s "$stop_ms")"
    kill -CONT "$P_G16"
    wait "$P_TAP13A"
    r=$?
    sleep 0.5
    c1=$(counters)
    qa1=$(status_val queue_added_frames)
    x13=$(xrun_since "$m13")
    echo "  13. $(load_line "after the overload" 0)"
    d_gap=$(delta "$c0" "$c1" capture_gap)
    d_ov=$(delta "$c0" "$c1" ring_overflow)
    d_un=$(delta "$c0" "$c1" ring_underflow)
    d_tr=$(delta "$c0" "$c1" latency_trimmed_frames)
    echo "  stopped g16-mic ${stop_ms} ms (queue_bound_ms $bound): capture_gap +$d_gap, ring_overflow +$d_ov, ring_underflow +$d_un," \
        "latency_trimmed_frames +$d_tr, late_link_discarded +$(delta "$c0" "$c1" late_link_discarded)," \
        "trigger_refused +$(delta "$c0" "$c1" trigger_refused), late_runs +$(delta "$c0" "$c1" late_runs)," \
        "queue_added_frames $(status_val queue_added_frames)"
    echo "  13. latency after the overload: $(latency_back "$qa0" "$qa1" "$d_tr" "$d_ov")"
    queue_bounded 13 "through the overload"
    if is_num "$d_gap" && is_num "$d_ov" && is_num "$d_un" && is_num "$d_tr" &&
        ((d_ov % 2 == 0 && d_un % 2 == 0 && d_tr % 2 == 0)) &&
        is_num "$qa0" && is_num "$qa1" && is_num "$x13" && ((r == 0)) && [[ -s $T/raw13a.f32 ]]; then
        want_gap=$((d_gap + d_ov / 2 + d_tr / 2))
        want_zero=$((d_un / 2))
        "$HELPER" compare --input-log "$T/src12.log" --raw "$T/raw13a.f32" --channels 2 --allow-delays \
            --report-gaps >"$T/cmp13a.txt"
        g_tot=$(compare_val "$T/cmp13a.txt" gap_frames_total)
        g_zero=$(compare_val "$T/cmp13a.txt" zero_fill_frames)
        g_rep=$(compare_val "$T/cmp13a.txt" repeat_frames)
        g_bad=$(compare_val "$T/cmp13a.txt" not_input_frames)
        g_skip=$(compare_val "$T/cmp13a.txt" src_clock_skip_frames)
        g_cons=$(compare_val "$T/cmp13a.txt" consumer_lost_frames)
        l_first=$(compare_val "$T/cmp13a.txt" latency_first)
        l_last=$(compare_val "$T/cmp13a.txt" latency_last)
        late=x
        if is_num "$g_tot" && is_num "$g_zero" && is_num "$g_skip" && is_num "$g_cons" && is_num "$l_first" &&
            is_num "$l_last"; then
            # input that reached the tap later than before the stall: the
            # rise of the latency beyond the queue's own; a zero quantum the
            # tap got for a cycle without input (the source's clock skipped)
            # stands in for graph frames that were never input
            late=$((l_last - l_first - (qa1 - qa0) - g_zero))
        fi
        echo "  overload accounting: the raw tap misses $g_tot frames in $(compare_val "$T/cmp13a.txt" gap_count) gaps" \
            "(and $g_cons more at its own missed cycles, the consumer's loss)," \
            "has $g_zero zero-filled and its latency went $l_first -> $l_last (queue_added_frames $qa0 -> $qa1):" \
            "$late frames of input arrived late, not lost; the source's clock skipped $g_skip frames without producing;" \
            "counted: capture_gap $d_gap (graph frames the capture missed)" \
            "+ ring_overflow $d_ov / 2 = $((d_ov / 2)) (raw queue drops)" \
            "+ latency_trimmed_frames $d_tr / 2 = $((d_tr / 2)) (quiet raw cycles trimmed) = $want_gap missing or late;" \
            "ring_underflow $d_un / 2 = $want_zero of g16-mic's own zero fills; graph xruns of g16_mic_raw $x13 frames"
        if [[ $late =~ ^-?[0-9]+$ ]] && ((g_tot + late + g_skip == want_gap && g_zero >= want_zero && g_rep == 0 && g_bad == 0)); then
            pass "13. the overload lost or delayed exactly the counted $want_gap graph frames ($g_tot lost, $late late, $g_skip never produced) and zero-filled exactly the counted $want_zero, nothing else"
        else
            bad "13. the raw tap lost $g_tot frames, $late arrived late, the source skipped $g_skip and $g_zero were zero-filled ($g_rep repeated, $g_bad not input); the counters say $want_gap missing or late and $want_zero zero-filled"
        fi
        sed 's/^/    /' "$T/cmp13a.txt"
    else
        bad "13. cannot account for the overload: tap exit $r, capture_gap +$d_gap, ring_overflow +$d_ov, ring_underflow +$d_un, latency_trimmed_frames +$d_tr (want even sample counts)"
    fi
    m13b=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw13b.f32" --channels 2 --seconds 3
    P_TAP13B=$LAST_PID
    sleep 0.5  # the reader is linked
    c2=$(counters)
    qa2=$(status_val queue_added_frames)
    wait "$P_TAP13B"
    r=$?
    sleep 0.5
    c3=$(counters)
    qa3=$(status_val queue_added_frames)
    x13b=$(xrun_since "$m13b")
    d_ov=$(delta "$c2" "$c3" ring_overflow)
    d_un=$(delta "$c2" "$c3" ring_underflow)
    d_gap=$(delta "$c2" "$c3" capture_gap)
    d_tr=$(delta "$c2" "$c3" latency_trimmed_frames)
    echo "  13. latency over the 3 s after: $(latency_back "$qa2" "$qa3" "$d_tr" "$d_ov")"
    # the signal has no quiet cycle: the recovery may not trim it either
    if is_num "$d_ov" && is_num "$d_un" && is_num "$d_gap" && is_num "$d_tr" &&
        ((d_ov == 0 && d_un == 0 && d_gap == 0 && d_tr == 0)); then
        pass "13. after the overload, 3 s of steady state with no counter growth (latency_trimmed_frames included)"
    else
        bad "13. after the overload the counters still grow: ring_overflow +$d_ov, ring_underflow +$d_un, capture_gap +$d_gap, latency_trimmed_frames +$d_tr"
    fi
    if ((r == 0)) && "$HELPER" compare --strict --allow-delays --input-log "$T/src12.log" --raw "$T/raw13b.f32" --channels 2; then
        pass "13. raw after the overload is one contiguous run of the source's frames (zero fills only as graph-xrun delays; g16-mic counted $x13b)"
    else
        bad "13. raw after the overload has gaps, repeats or zero fills (tap exit $r)"
    fi
elif ((step12)); then
    bad "13. g16-mic is not running after step 12"
fi

# ---- 14. a stalled consumer ---------------------------------------------------
#
# The other side of the bound: g16-mic keeps running and the raw tap (the
# only reader, as in step 13) is SIGSTOPped for twice queue_bound_ms (at
# least 400 ms), then SIGCONT. g16-mic must keep running with its queue's
# depth and added latency within the bound. Either PipeWire back-pressured
# g16-mic (its raw output found no free buffer) and its queue dropped the
# oldest audio, counted: then the tap's gap is exactly capture_gap +
# ring_overflow / 2 + latency_trimmed_frames / 2 (quiet raw cycles the
# latency recovery dropped, neither delivered nor overflow), its zero fills
# exactly ring_underflow / 2, and what follows the gap is contiguous (the
# newest data, in order). Or PipeWire did not back-pressure it
# (ring_overflow, capture_gap and latency_trimmed_frames +0): then the loss
# was at the consumer, g16-mic's counters stay clean and the tap is
# contiguous after its one gap. Which case occurred, and which mechanism,
# if any, returned the added latency, is logged.

if ((step12)) && alive "$P_G16"; then
    bound=$(status_val queue_bound_ms)
    hold_ms=$(stall_ms)
    poll 5 raw_only || bad "14. g16_mic_processed still has a reader; the raw-only accounting needs none"
    m14=$(gm0)
    start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw14.f32" --channels 2 --seconds 4
    P_TAP14=$LAST_PID
    sleep 1  # the reader is linked
    c0=$(counters)
    qa0=$(status_val queue_added_frames)
    kill -STOP "$P_TAP14"
    sleep "$(ms_to_s "$hold_ms")"
    kill -CONT "$P_TAP14"
    wait "$P_TAP14"
    r=$?
    sleep 0.5
    c1=$(counters)
    qa1=$(status_val queue_added_frames)
    x14=$(xrun_since "$m14")
    echo "  14. $(load_line "after the stalled reader" 0)"
    d_gap=$(delta "$c0" "$c1" capture_gap)
    d_ov=$(delta "$c0" "$c1" ring_overflow)
    d_un=$(delta "$c0" "$c1" ring_underflow)
    d_tr=$(delta "$c0" "$c1" latency_trimmed_frames)
    echo "  stopped the raw tap ${hold_ms} ms (queue_bound_ms $bound): capture_gap +$d_gap, ring_overflow +$d_ov," \
        "ring_underflow +$d_un, latency_trimmed_frames +$d_tr, late_runs +$(delta "$c0" "$c1" late_runs)," \
        "trigger_refused +$(delta "$c0" "$c1" trigger_refused), queue_added_frames $qa1"
    echo "  14. latency after the stalled reader: $(latency_back "$qa0" "$qa1" "$d_tr" "$d_ov")"
    if alive "$P_G16" && [[ $(status_val source_state) == connected ]]; then
        pass "14. g16-mic kept running and capturing while its reader was stalled"
    else
        bad "14. g16-mic stopped or lost its source while its reader was stalled (source_state=$(status_val source_state))"
    fi
    queue_bounded 14 "with its reader stalled"
    if is_num "$d_gap" && is_num "$d_ov" && is_num "$d_un" && is_num "$d_tr" &&
        ((d_ov % 2 == 0 && d_un % 2 == 0 && d_tr % 2 == 0)) && ((r == 0)) && [[ -s $T/raw14.f32 ]]; then
        "$HELPER" compare --input-log "$T/src12.log" --raw "$T/raw14.f32" --channels 2 --report-gaps >"$T/cmp14.txt"
        sed 's/^/    /' "$T/cmp14.txt"
        g_tot=$(compare_val "$T/cmp14.txt" gap_frames_total)
        g_cnt=$(compare_val "$T/cmp14.txt" gap_count)
        g_zero=$(compare_val "$T/cmp14.txt" zero_fill_frames)
        g_rep=$(compare_val "$T/cmp14.txt" repeat_frames)
        g_bad=$(compare_val "$T/cmp14.txt" not_input_frames)
        g_skip=$(compare_val "$T/cmp14.txt" src_clock_skip_frames)
        l_rise=x
        l_a=$(compare_val "$T/cmp14.txt" latency_first)
        l_b=$(compare_val "$T/cmp14.txt" latency_last)
        [[ $l_a =~ ^-?[0-9]+$ && $l_b =~ ^-?[0-9]+$ ]] && l_rise=$((l_b - l_a))
        if ! is_num "$g_tot" || ! is_num "$g_cnt" || ! is_num "$g_zero" || ! is_num "$g_rep" || ! is_num "$g_bad" ||
            ! is_num "$g_skip"; then
            bad "14. the raw tap could not be analysed (see the compare lines above)"
        elif ((d_ov > 0 || d_gap > 0 || d_tr > 0)); then
            want_gap=$((d_gap + d_ov / 2 + d_tr / 2))
            want_zero=$((d_un / 2))
            echo "  14. case: g16-mic was back-pressured and counted the loss: ring_overflow $d_ov / 2 = $((d_ov / 2)) frames" \
                "(oldest dropped) + latency_trimmed_frames $d_tr / 2 = $((d_tr / 2)) (quiet raw cycles trimmed)" \
                "+ capture_gap $d_gap = $want_gap missing, ring_underflow $d_un / 2 = $want_zero zero-filled;" \
                "the tap misses $g_tot frames in $g_cnt gaps, $g_zero zero-filled, $g_rep repeated, $g_bad not input;" \
                "the source's clock skipped $g_skip frames without producing (in capture_gap, never input)"
            if ((g_tot + g_skip == want_gap && g_zero == want_zero && g_rep == 0 && g_bad == 0 && (d_gap > 0 || g_cnt <= 1))); then
                pass "14. the stalled reader lost exactly the counted $want_gap frames, and what follows the gap is the newest audio in order"
            else
                bad "14. the stalled reader's tap misses $g_tot frames ($g_cnt gaps, $g_zero zero-filled, $g_rep repeated, $g_bad not input); the counters say $want_gap missing and $want_zero zero-filled"
            fi
        else
            echo "  14. case: PipeWire did not back-pressure g16-mic (ring_overflow, capture_gap, latency_trimmed_frames +0): the $g_tot frames" \
                "missing from the tap ($g_cnt gaps) were lost at the consumer; ring_underflow +$d_un, graph xruns $x14 frames;" \
                "$g_zero zero-filled, the latency rose by $l_rise (zeros are graph-xrun delays only if it rose by as much)"
            if [[ $l_rise =~ ^-?[0-9]+$ ]] && ((d_un == 0 && g_zero <= l_rise && g_rep == 0 && g_bad == 0 && g_cnt <= 1)); then
                pass "14. g16-mic's counters stayed clean and the tap is contiguous after it resumed (the consumer's own loss: $g_tot frames)"
            else
                bad "14. with no counted loss: ring_underflow +$d_un, and the tap has $g_cnt gaps, $g_zero zero-filled, $g_rep repeated, $g_bad not input frames"
            fi
        fi
    else
        bad "14. cannot account for the stalled reader: tap exit $r, capture_gap +$d_gap, ring_overflow +$d_ov, ring_underflow +$d_un, latency_trimmed_frames +$d_tr (want even sample counts)"
    fi
elif ((step12)); then
    bad "14. g16-mic is not running after step 13"
fi
if alive "$P_G16"; then
    stop_pid "$P_G16" 3
    r=$?
    ((r == 0)) || bad "12-14. g16-mic exit status $r after SIGTERM"
fi

n=$(log_records "$T/decoy.log")
if [[ $n == 0 ]]; then
    pass "the decoy source never streamed"
else
    bad "the decoy source streamed $n buffers"
fi

exit "$failed"
