#!/bin/bash
# Service.qml headless (#145): quickshell on the offscreen platform loads it
# with a stub g16ctl, a stub `gdbus monitor` that emits two PropertiesChanged
# lines, fake monitors and a fake power source, with and without power-tune.
# Run: tests/service.test.sh   (skips without quickshell's `qs`)
set -u
command -v qs >/dev/null || { echo "service tests skipped: no qs"; exit 0; }
SVC=$(realpath "$(dirname "$0")/../Service.qml")
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/sys/class/leds/asus::kbd_backlight"
echo 1 >"$T/sys/class/leds/asus::kbd_backlight/brightness_hw_changed"
cat >"$T/helper" <<'EOF'
#!/bin/bash
echo "$*" >>"${0%/*}/calls.log"
case "$1" in
  get) printf 'HasPowerTune=%s\nHasAura=true\nKbdBrightness=1\nKbdColor=00FF88\nKbdZone=0\nKbdBoot=true\nKbdAwake=true\nKbdSleep=false\nKbdShutdown=true\nHasSlash=false\nChargeLimit=80\nHasWinlock=true\nWinlockMode=unlock\nWinlockService=active\n' "${PT:-false}" ;;
  list-modes) printf 'Static\nBounce\n' ;;
  *) sleep 0.3 ;;
esac
EOF
cat >"$T/monitor" <<'EOF'
#!/bin/bash
sleep 0.8
echo "/xyz/ljones/aura/19b6_3_4: org.freedesktop.DBus.Properties.PropertiesChanged ('xyz.ljones.Aura', {'Brightness': <uint32 3>}, @as [])"
echo "/xyz/ljones/asus: org.freedesktop.DBus.Properties.PropertiesChanged ('xyz.ljones.Power', {'ChargeControlEndThreshold': <byte 0x3c>}, @as [])"
exec sleep 30
EOF
chmod +x "$T/helper" "$T/monitor"
cat >"$T/shell.qml" <<EOF
import QtQuick
import Quickshell
ShellRoot {
  id: r
  property var s: null
  property var out: []
  function ok(name, cond) { out.push((cond ? "ok - " : "not ok - ") + name) }
  Component.onCompleted: {
    var c = Qt.createComponent("file://$SVC")
    if (c.status !== Component.Ready) { console.log("LOAD ERROR " + c.errorString()); Qt.exit(2); return }
    r.s = c.createObject(r, { helper: "$T/helper", monitorCommand: ["$T/monitor"], sysRoot: "$T/sys",
      configHome: "$T/cfg", stateHome: "$T/state", fakeMonitors: [{name: "eDP-1", refreshRate: 240}], fakeOnBattery: false })
  }
  Timer { interval: 600; running: true; onTriggered: {
    ok("get parsed: hasAura", r.s.hasAura === true)
    ok("hasPowerTune at start", r.s.hasPowerTune === EXPECT_PT)
    ok("refreshHz at start", r.s.refreshHz === (EXPECT_PT ? 240 : 0))
    ok("charge limit 80", r.s.chargeLimit === 80)
    ok("winlock mode", r.s.winlockMode === "unlock")
    ok("slash off without slash", r.s.slashOn === false)
    // queue: three writes while the first runs
    r.s.setKbdPower("sleep", true)
    ok("optimistic kbdSleep", r.s.kbdSleep === true)
    r.s.setLevel("ac", "low")
    ok("level vs live brightness", String(Quickshell.env("PT")) === "true" ? r.s.kbdBrightness === 1 : r.s.kbdBrightness === 1)
    r.s.setLevel("both", "high")
    r.s.setLevel("ac", "med")
    ok("queue keeps both then ac", JSON.stringify(r.s.pendingCmds.map(function(a){return a.slice(1).join(" ")})) === JSON.stringify(["kbd-level both high","kbd-level ac med"]))
    r.s.refresh()
    ok("refresh skipped while writes queued", r.s.pendingCmds.length === 2)
  } }
  Timer { interval: 1200; running: true; onTriggered: {
    ok("monitor: charge limit 60 from the signal, before any re-read", r.s.chargeLimit === 60)
  } }
  Timer { interval: 2200; running: true; onTriggered: {
    ok("power-tune: refreshHz " + r.s.refreshHz + ", hasPowerTune " + r.s.hasPowerTune, r.s.hasPowerTune === EXPECT_PT && r.s.refreshHz === (EXPECT_PT ? 240 : 0))
    ok("re-read after the drain restored charge limit 80", r.s.chargeLimit === 80)
    ok("queue drained", r.s.pendingCmds.length === 0)
    for (var i = 0; i < r.out.length; i++) console.log(r.out[i])
    Qt.exit(0)
  } }
}
EOF
fail=0
for pt in false true; do
  echo "== power-tune: $pt"
  sed "s/EXPECT_PT/$pt/g" "$T/shell.qml" >"$T/shell-$pt.qml"
  out=$(cd "$T" && PT=$pt QT_QPA_PLATFORM=offscreen timeout 30 qs -p "$T/shell-$pt.qml" 2>&1 |
    grep -E 'ok - |LOAD ERROR' | sed 's/^.*\(not ok\|ok\) - /\1 - /')
  echo "$out"
  [[ $(grep -c '^ok - ' <<<"$out") -eq 14 ]] && ! grep -q '^not ok\|LOAD' <<<"$out" || fail=1
done
((fail)) && { echo "FAILED"; exit 1; }
echo "service tests ok"
