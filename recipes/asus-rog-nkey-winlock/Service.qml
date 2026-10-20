import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.UPower

// Shared state for the G16 Control widget (omarchy-asus.g16). The shell mounts
// this once (manifest kind "service"); every bar's widget reads it, so two
// monitors no longer mean two pollers.
//
// Nothing here runs on a timer while the panel is closed:
//   - asusd property changes arrive as D-Bus PropertiesChanged signals, read
//     from ONE long-lived `gdbus monitor` (quickshell has no generic D-Bus API).
//   - Fn+F2/F3 brightness changes that bypass asusd arrive as an inotify event
//     on the LED's brightness_hw_changed (the kernel sysfs_notify()s it).
//   - power-tune.conf (KBD_AC/KBD_BATTERY) and the power-tune Hz pin are files
//     watched with FileView. omarchy-power-tune is not packaged: without it
//     (HasPowerTune=false) the per-source levels and the refresh rate hide.
//   - On-battery comes from Quickshell's UPower, refresh rate from Quickshell's
//     Hyprland monitor list.
// `g16ctl get` (a few busctl calls) runs once at start, when a panel opens,
// every pollOpenMs while one is open, after a control is used, and when asusd
// restarts. It no longer runs `g16-winlock status` (opened hidraw every poll,
// and the panel never displayed the result) or `omarchy-power-tune hz get`.
Item {
  id: svc
  visible: false

  // Set by the shell for service plugins; unused, declared so assignment works.
  property var shell: null
  property var manifest: null

  // ---- injectable for headless tests ----
  property string helper: decodeURIComponent(Qt.resolvedUrl("g16ctl").toString().replace(/^file:\/\//, ""))
  property var monitorCommand: ["gdbus", "monitor", "--system", "--dest", "xyz.ljones.Asusd"]
  property string sysRoot: "/sys"
  property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  // null = use Quickshell.Hyprland; tests pass [{name, refreshRate}].
  property var fakeMonitors: null
  // null = use UPower.onBattery; tests pass true/false.
  property var fakeOnBattery: null
  property int pollOpenMs: 5000

  // ---- panel-open tracking (every bar's widget reports in) ----
  property int openCount: 0
  readonly property bool panelOpen: openCount > 0
  property bool sliderDragging: false

  // ---- keyboard ----
  property bool hasAura: false
  property int kbdBrightness: 0
  property string kbdColor: "FF00FF"
  property string kbdAC: "off"
  property string kbdBattery: "off"
  property bool hasPowerTune: false
  readonly property bool onBattery: fakeOnBattery !== null ? fakeOnBattery === true : UPower.onBattery
  property bool kbdBoot: true
  property bool kbdAwake: true
  property bool kbdSleep: true
  property bool kbdShutdown: true

  // ---- slash ----
  property bool hasSlash: false
  property bool slashOn: false
  property int slashBrightness: 0
  property int slashPattern: 0
  readonly property string slashPatternName: slashPattern >= 0 && slashPattern < slashModes.length
    ? String(slashModes[slashPattern]) : ""
  property bool showOnBoot: false
  property bool showOnShutdown: false
  property bool showOnSleep: false
  property bool showOnBattery: false
  property bool showBatteryWarning: false
  property bool showOnLidClosed: false
  property var slashModes: ["Static", "Bounce", "Slash", "Loading", "BitStream",
                            "Transmission", "Flow", "Flux", "Phantom", "Spectrum",
                            "Hazard", "Interfacing", "Ramp", "GameOver", "Start", "Buzzer"]

  // ---- display ----
  // The internal panel is the eDP output; power-tune resolves the same one by
  // EDID description, and this laptop has exactly one eDP.
  // Refresh changes go through power-tune; without it the section hides.
  readonly property int refreshHz: {
    if (!hasPowerTune) return 0
    var list = fakeMonitors !== null ? fakeMonitors
      : (Hyprland.monitors ? Hyprland.monitors.values : [])
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      if (!m || String(m.name).indexOf("eDP") !== 0) continue
      var rr = m.refreshRate !== undefined ? m.refreshRate
        : (m.lastIpcObject ? m.lastIpcObject.refreshRate : 0)
      return Math.round(Number(rr) || 0)
    }
    return 0
  }
  readonly property string refreshOverride: {
    var v = String(hzPinFile.loadedText || "").replace(/[^0-9]/g, "")
    return v !== "" ? v : "auto"
  }

  // ---- battery ----
  property int chargeLimit: 0

  // ---- Win-lock ----
  property bool hasWinlock: false
  property string winlockMode: "toast"
  property string winlockService: "inactive"

  // Writes queued behind the running one, in order. A newer write to the same
  // setting drops the queued one and goes to the back, so a slider drag cannot
  // outrun the daemon, an unrelated action is never dropped, and overlapping
  // writes always end on the last selection.
  property var pendingCmds: []

  readonly property var levelOptions: ["off", "low", "med", "high"]

  // ---------------------------------------------------------------- actions
  // queue-begin (pure helpers; exercised by an extracted-function test)
  // Identifies the setting a command writes: the verb, plus the scope/flag
  // argument for verbs that address one of several settings.
  function cmdKey(args) {
    var verb = args[1]
    if (verb === "kbd-level" || verb === "kbd-power" || verb === "slash-flag")
      return verb + " " + args[2]
    return verb
  }

  // True when running newArgs makes a queued oldArgs pointless: same setting,
  // or a kbd-level "both" that covers an earlier "ac"/"battery". A narrower
  // write never drops a queued "both" (it would lose the other scope).
  function supersedes(newArgs, oldArgs) {
    if (cmdKey(newArgs) === cmdKey(oldArgs)) return true
    return newArgs[1] === "kbd-level" && oldArgs[1] === "kbd-level"
        && newArgs[2] === "both"
  }

  // Returns the queue with superseded entries removed and args appended last,
  // so the final state is always the user's last selection.
  function enqueue(queue, args) {
    var q = []
    for (var i = 0; i < queue.length; i++)
      if (!supersedes(args, queue[i])) q.push(queue[i])
    q.push(args)
    return q
  }
  // queue-end

  function runCmd(args) {
    svc.writeGen++
    if (!actionProc.running) {
      actionProc.command = args
      actionProc.running = true
      return
    }
    svc.pendingCmds = enqueue(svc.pendingCmds, args)
  }

  // A read taken while writes are queued would put the old values back over the
  // optimistic ones. Skip it: actionProc refreshes once the queue drains. A
  // request that arrives mid-read reruns the read when it finishes.
  // writeGen counts writes; a read remembers the count it started at, and
  // parseState drops a read that a write overtook (the drain's refresh() then
  // sets refreshAgain, so a fresh read always follows).
  property bool refreshAgain: false
  property int writeGen: 0
  property int readGen: -1
  function refresh() {
    if (actionProc.running || svc.pendingCmds.length > 0) return
    if (stateProc.running) { svc.refreshAgain = true; return }
    svc.readGen = svc.writeGen
    stateProc.running = true
  }

  // Optimistic local update: the restart-and-reapply round trip takes a moment,
  // and leaving the segmented control on its old value that whole time reads as
  // a dropped click. A level for the active source (or both) is also the live
  // brightness, so the keyboard toggle sees it before the next `get`.
  function setLevel(scope, value) {
    if (scope === "ac") svc.kbdAC = value
    else if (scope === "battery") svc.kbdBattery = value
    else { svc.kbdAC = value; svc.kbdBattery = value }
    var active = !svc.hasPowerTune || scope === "both"
        || scope === (svc.onBattery ? "battery" : "ac")
    if (active) {
      var i = svc.levelOptions.indexOf(value)
      if (i >= 0) svc.kbdBrightness = i
    }
    runCmd([svc.helper, "kbd-level", scope, value])
  }
  // Flips kbdBrightness (0 off, 2 med) right away so a second click before the
  // next `get` sees the new state instead of queueing the same write again.
  function toggleKeyboard() {
    var on = svc.kbdBrightness === 0
    svc.kbdBrightness = on ? 2 : 0
    setLevel("both", on ? "med" : "off")
  }
  function setColor(hex) { svc.kbdColor = hex; runCmd([svc.helper, "kbd-color", hex]) }
  // Flag toggles set their property first, like the on/off switches, so a
  // second click before the next `get` toggles back instead of repeating.
  function setKbdPower(flag, value) {
    if (flag === "boot") svc.kbdBoot = value
    else if (flag === "awake") svc.kbdAwake = value
    else if (flag === "sleep") svc.kbdSleep = value
    else if (flag === "shutdown") svc.kbdShutdown = value
    runCmd([svc.helper, "kbd-power", flag, value ? "true" : "false"])
  }
  function toggleSlash() {
    svc.slashOn = !svc.slashOn
    runCmd([svc.helper, "slash-enabled", svc.slashOn ? "true" : "false"])
  }
  function setSlashPattern(index) {
    if (index < 0 || index >= svc.slashModes.length) return
    svc.slashPattern = index
    runCmd([svc.helper, "slash-pattern", String(index)])
  }
  function applySlashBrightness() { runCmd([svc.helper, "slash-brightness", String(svc.slashBrightness)]) }
  function setSlashFlag(name, value) {
    var prop = ({ ShowOnBoot: "showOnBoot", ShowOnShutdown: "showOnShutdown",
                  ShowOnSleep: "showOnSleep", ShowOnBattery: "showOnBattery",
                  ShowBatteryWarning: "showBatteryWarning",
                  ShowOnLidClosed: "showOnLidClosed" })[name]
    if (prop) svc[prop] = value
    runCmd([svc.helper, "slash-flag", name, value ? "true" : "false"])
  }
  function setRefreshHz(value) { runCmd([svc.helper, "refresh", value]) }
  function setChargeLimit(value) {
    svc.chargeLimit = parseInt(value) || 0
    runCmd([svc.helper, "battery-limit", value])
  }
  function setWinlockMode(value) { svc.winlockMode = value; runCmd([svc.helper, "winlock-mode", value]) }

  function panelOpened() {
    svc.openCount += 1
    if (svc.openCount === 1) {
      refresh()
      if (svc.fakeMonitors === null && Hyprland.refreshMonitors) Hyprland.refreshMonitors()
    }
  }
  function panelClosed() { svc.openCount = Math.max(0, svc.openCount - 1) }

  // ---------------------------------------------------------------- parsing
  function bool(v) { return String(v) === "true" }

  function parseState(raw) {
    if (svc.readGen !== svc.writeGen || actionProc.running || svc.pendingCmds.length > 0)
      return
    var lines = String(raw).trim().split("\n")
    var m = ({})
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      m[lines[i].slice(0, eq).trim()] = lines[i].slice(eq + 1).trim()
    }
    if (m["HasAura"] === undefined) return

    svc.hasAura = bool(m["HasAura"])
    svc.hasPowerTune = bool(m["HasPowerTune"])
    if (svc.hasAura) {
      svc.kbdBrightness = parseInt(m["KbdBrightness"]) || 0
      if (m["KbdColor"]) svc.kbdColor = m["KbdColor"]
      // power-tune.conf is also watched; these only seed it.
      if (m["KbdAC"]) svc.kbdAC = m["KbdAC"]
      if (m["KbdBattery"]) svc.kbdBattery = m["KbdBattery"]
      svc.kbdBoot = bool(m["KbdBoot"])
      svc.kbdAwake = bool(m["KbdAwake"])
      svc.kbdSleep = bool(m["KbdSleep"])
      svc.kbdShutdown = bool(m["KbdShutdown"])
    }

    svc.hasSlash = bool(m["HasSlash"])
    if (svc.hasSlash) {
      svc.slashOn = bool(m["SlashEnabled"])
      if (!svc.sliderDragging) svc.slashBrightness = parseInt(m["SlashBrightness"]) || 0
      svc.slashPattern = parseInt(m["SlashPattern"]) || 0
      svc.showOnBoot = bool(m["SlashShowOnBoot"])
      svc.showOnShutdown = bool(m["SlashShowOnShutdown"])
      svc.showOnSleep = bool(m["SlashShowOnSleep"])
      svc.showOnBattery = bool(m["SlashShowOnBattery"])
      svc.showBatteryWarning = bool(m["SlashShowBatteryWarning"])
      svc.showOnLidClosed = bool(m["SlashShowOnLidClosed"])
    } else {
      svc.slashOn = false
    }

    svc.chargeLimit = parseInt(m["ChargeLimit"]) || 0
    svc.hasWinlock = bool(m["HasWinlock"])
    if (m["WinlockMode"]) svc.winlockMode = m["WinlockMode"]
    if (m["WinlockService"]) svc.winlockService = m["WinlockService"]
  }

  function parseModes(raw) {
    var out = []
    var lines = String(raw).trim().split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.length > 0) out.push(name)
    }
    if (out.length > 0) svc.slashModes = out
  }

  function parseConf(text) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var mm = lines[i].match(/^(KBD_AC|KBD_BATTERY)=["']?([A-Za-z]+)["']?\s*$/)
      if (!mm) continue
      if (mm[1] === "KBD_AC") svc.kbdAC = mm[2]
      else svc.kbdBattery = mm[2]
    }
  }

  // gdbus renders a variant's value as e.g. `uint32 2`, `byte 0x0b`, `true`.
  function scalar(v) {
    var s = String(v).trim().replace(/^(uint32|int32|uint16|int16|byte|uint64|int64|double|boolean)\s+/, "")
    if (s === "true" || s === "false") return s === "true"
    var n = Number(s)
    return isNaN(n) ? s : n
  }

  // One line of `gdbus monitor` output, e.g.
  //   /xyz/ljones/aura/19b6_3_4: org.freedesktop.DBus.Properties.PropertiesChanged
  //     ('xyz.ljones.Aura', {'Brightness': <uint32 2>}, @as [])
  // Returns true when the line was understood without a re-read.
  function handleMonitorLine(line) {
    line = String(line)
    if (line.indexOf("is owned by") !== -1) { refreshSoon.restart(); return false }
    if (line.indexOf("PropertiesChanged") === -1) return false
    var head = line.match(/PropertiesChanged \('([^']+)', \{(.*)\}, /)
    if (!head) { refreshSoon.restart(); return false }
    var iface = head[1]
    var body = head[2]
    var re = /'(\w+)': <([^<>]*)>/g
    var mm
    var understood = true
    var any = false
    while ((mm = re.exec(body)) !== null) {
      any = true
      var key = mm[1]
      var raw = mm[2]
      if (iface === "xyz.ljones.Aura") {
        if (key === "Brightness") svc.kbdBrightness = Number(scalar(raw)) || 0
        else if (key === "LedModeData") {
          var c = raw.match(/\((?:byte )?(0x[0-9a-fA-F]+|\d+), (?:byte )?(0x[0-9a-fA-F]+|\d+), (?:byte )?(0x[0-9a-fA-F]+|\d+)\)/)
          if (c) {
            var hex = ""
            for (var k = 1; k <= 3; k++) {
              var h = (Number(c[k]) & 255).toString(16).toUpperCase()
              hex += h.length < 2 ? "0" + h : h
            }
            svc.kbdColor = hex
          } else understood = false
        } else if (key === "LedPower") {
          var p = raw.match(/\((?:uint32 )?\d+, (true|false), (true|false), (true|false), (true|false)\)/)
          if (p) {
            svc.kbdBoot = p[1] === "true"; svc.kbdAwake = p[2] === "true"
            svc.kbdSleep = p[3] === "true"; svc.kbdShutdown = p[4] === "true"
          } else understood = false
        } else understood = false
      } else if (iface === "xyz.ljones.Slash") {
        var v = scalar(raw)
        if (key === "Enabled") svc.slashOn = v === true
        else if (key === "Brightness") { if (!svc.sliderDragging) svc.slashBrightness = Number(v) || 0 }
        else if (key === "Interval") svc.slashPattern = Number(v) || 0
        else if (key === "ShowOnBoot") svc.showOnBoot = v === true
        else if (key === "ShowOnShutdown") svc.showOnShutdown = v === true
        else if (key === "ShowOnSleep") svc.showOnSleep = v === true
        else if (key === "ShowOnBattery") svc.showOnBattery = v === true
        else if (key === "ShowBatteryWarning") svc.showBatteryWarning = v === true
        else if (key === "ShowOnLidClosed") svc.showOnLidClosed = v === true
        // Mode is internal (Interval is the pattern index) -- nothing to show.
      } else if (key === "ChargeControlEndThreshold") {
        svc.chargeLimit = Number(scalar(raw)) || 0
      }
    }
    // Signal without inline values (invalidated-only): re-read, but only if
    // somebody is looking at the panel; the bar fields are all inline.
    if ((!any || !understood) && svc.panelOpen) refreshSoon.restart()
    return any && understood
  }

  // ---------------------------------------------------------------- sources
  Process {
    id: stateProc
    command: [svc.helper, "get"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: svc.parseState(text) }
    onExited: if (svc.refreshAgain) { svc.refreshAgain = false; svc.refresh() }
  }

  Process {
    id: modesProc
    running: true
    command: [svc.helper, "list-modes"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: svc.parseModes(text) }
  }

  Process {
    id: actionProc
    onExited: {
      if (svc.pendingCmds.length > 0) {
        var q = svc.pendingCmds.slice()
        var next = q.shift()
        svc.pendingCmds = q
        actionProc.command = next
        actionProc.running = true
      } else {
        svc.refresh()
      }
    }
  }

  // The one long-lived D-Bus listener. It sleeps in poll() until asusd emits.
  // A crash loop backs off to 5 min; a listener that ran a while restarts fast.
  property int monitorBackoff: 5000
  property real monitorStartedAt: 0
  Process {
    id: monitorProc
    command: svc.monitorCommand
    running: true
    stdout: SplitParser { onRead: function(line) { svc.handleMonitorLine(line) } }
    onRunningChanged: if (running) svc.monitorStartedAt = Date.now()
    onExited: {
      if (Date.now() - svc.monitorStartedAt > 60000) svc.monitorBackoff = 5000
      monitorRestart.interval = svc.monitorBackoff
      monitorRestart.start()
      svc.monitorBackoff = Math.min(300000, svc.monitorBackoff * 2)
    }
  }
  Timer {
    id: monitorRestart
    interval: svc.monitorBackoff
    onTriggered: { monitorProc.running = true; svc.refresh() }
  }

  Timer { id: refreshSoon; interval: 400; onTriggered: svc.refresh() }

  // Fn+F2/F3 go straight to the kernel LED; brightness_hw_changed is
  // sysfs_notify()d, which inotify sees.
  FileView {
    id: kbdHwChanged
    path: svc.sysRoot + "/class/leds/asus::kbd_backlight/brightness_hw_changed"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); hwRead.restart() }
  }
  Timer {
    id: hwRead
    interval: 50
    onTriggered: {
      var n = parseInt(String(kbdHwChanged.text()).trim())
      if (!isNaN(n)) svc.kbdBrightness = n
    }
  }

  FileView {
    id: confFile
    path: svc.configHome + "/omarchy/power-tune.conf"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: svc.parseConf(text())
  }

  FileView {
    id: hzPinFile
    property string loadedText: ""
    path: svc.stateHome + "/omarchy/power-tune-hz"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: loadedText = text()
    onLoadFailed: loadedText = ""
  }

  // Panel-only detail: re-read while someone is looking.
  Timer {
    interval: svc.pollOpenMs
    running: svc.panelOpen
    repeat: true
    onTriggered: {
      svc.refresh()
      if (svc.fakeMonitors === null && Hyprland.refreshMonitors) Hyprland.refreshMonitors()
    }
  }

  Component.onCompleted: refresh()
}
