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
#      plus one graph quantum (272 + 1024); processed, at the same graph
#      positions, must equal an offline omni engine fed the same frames;
#   6. the source goes away: status waiting, reconnects=1, nothing linked into
#      the capture and the decoy not taken; the source comes back under the
#      same name: connected again, linked only from the new node, and (after
#      another 3 s unread) raw is the new source's frames bit for bit;
#   7. `g16-mic run --source test_null_sink.monitor` is refused (exit 2) and
#      links nothing;
#   8. SIGTERM: exit 0 within 3 s, the g16_mic_* nodes and the status file
#      gone, no g16-mic process left.
# The decoy must never have streamed a buffer.
#
# Exit: 0 all passed; 1 a step failed; 77 (meson's skip) when the pipewire or
# wireplumber binary or the helper is missing, so the live path cannot run.
# Every process it starts is stopped on every exit path (trap), and nothing
# is written outside its temporary directory, which it removes.
#
# RED -> GREEN. Before this test, the live path of host.c had never run. Run
# against host.c as it was, it finds four host bugs (fixed in host.c, each
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
#     g16_mic_raw at the same graph position. They now read on the
#     capture's clock, one cycle behind it.
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

# Always under /tmp: Unix socket paths are short (108 bytes), and a fixed
# place makes a leftover easy to see (ls /tmp/g16mic-pw.*).
T=$(mktemp -d /tmp/g16mic-pw.XXXXXX) || { echo "FAIL: cannot create a temporary directory"; exit 1; }

PIDS=()
LAST_PID=
failed=0

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
    local f
    for f in g16mic.log pw.log wp.log helper.log; do
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
    if [[ -s $T/g16mic.log ]]; then
        echo "  last g16-mic messages:"
        tail -n 6 "$T/g16mic.log" | sed 's/^/    /'
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
last_latency() { sed -n 's/.*capturing .* latency \([0-9][0-9]*\) frames.*/\1/p' "$T/g16mic.log" | tail -n 1; }
log_records() { grep -vc '^#' "$1" 2>/dev/null; }

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
if [[ -s $T/raw1.f32 && -s $T/proc1.f32 ]]; then
    if "$HELPER" compare --input-log "$T/src1.log" --raw "$T/raw1.f32" --processed "$T/proc1.f32" \
        --channels 2 --latency "$LAT"; then
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
sleep 3
LAT2=$(last_latency)
[[ $LAT2 =~ ^[0-9]+$ ]] || LAT2=$LAT
start "$T/helper.log" "$HELPER" tap --target g16_mic_raw --out "$T/raw2.f32" --channels 2 --seconds 1
P_TAP3=$LAST_PID
wait "$P_TAP3"
r=$?
sleep 0.3
if ((r == 0)) && "$HELPER" compare --input-log "$T/src2.log" --raw "$T/raw2.f32" --channels 2 --latency "$LAT2"; then
    pass "6. after the reconnect raw is the new source's input bit for bit"
else
    bad "6. raw after the reconnect (tap exit $r) does not match the new source"
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

n=$(log_records "$T/decoy.log")
if [[ $n == 0 ]]; then
    pass "the decoy source never streamed"
else
    bad "the decoy source streamed $n buffers"
fi

exit "$failed"
