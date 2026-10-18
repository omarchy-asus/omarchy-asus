import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One control surface for every LED on this Zephyrus G16 (GA605), which is why
// this widget replaces the older Slash-only one rather than sitting beside it.
// The machine has exactly two user-controllable lights, and they are reached
// very differently:
//
//   Keyboard backlight -- a real kernel LED (/sys/class/leds/asus::kbd_backlight)
//     owned by asusd's xyz.ljones.Aura interface. This panel does NOT write its
//     brightness directly: omarchy-power-tune re-applies KBD_AC/KBD_BATTERY on
//     every UPower event and a 30s poll, so a direct write is reverted within
//     half a minute. Brightness therefore edits power-tune.conf and restarts
//     that unit, which is why it is presented as two per-power-source levels
//     rather than one slider. Colour and power-state flags are untouched by
//     power-tune and go straight over D-Bus.
//
//   Slash bar (lid) -- not a kernel LED at all; nothing for it appears under
//     /sys/class/leds. It is asusd's xyz.ljones.Slash interface on the same
//     object as Aura.
//
// The hardware reports SupportedBasicModes = [Static] and SupportedBasicZones =
// [], so the keyboard is single-zone, static-colour only. No breathe/rainbow
// section is offered because this keyboard cannot do them, whatever
// `asusctl aura effect` advertises.
Panel {
  id: root
  moduleName: "omarchy-asus.g16"
  ipcTarget: "omarchy-asus.g16"

  // g16ctl sits next to this file, wherever the plugin directory is (a user
  // install or a link to the packaged copy).
  readonly property string helper:
    decodeURIComponent(Qt.resolvedUrl("g16ctl").toString().replace(/^file:\/\//, ""))

  // ---- keyboard ----
  property bool hasAura: false
  property int kbdBrightness: 0
  property string kbdColor: "FF00FF"
  property string kbdAC: "off"
  property string kbdBattery: "off"
  property bool onBattery: false
  property bool kbdBoot: true
  property bool kbdAwake: true
  property bool kbdSleep: true
  property bool kbdShutdown: true

  // ---- slash ----
  property bool hasSlash: false
  property bool slashOn: false
  property int slashBrightness: 0
  property int slashPattern: 0
  property string slashPatternName: ""
  property bool showOnBoot: false
  property bool showOnShutdown: false
  property bool showOnSleep: false
  property bool showOnBattery: false
  property bool showBatteryWarning: false
  property bool showOnLidClosed: false

  property var slashModes: ["Static", "Bounce", "Slash", "Loading", "BitStream",
                            "Transmission", "Flow", "Flux", "Phantom", "Spectrum",
                            "Hazard", "Interfacing", "Ramp", "GameOver", "Start", "Buzzer"]

  // 0 = keyboard, 1 = slash

  // Coalesces writes so a slider drag cannot outrun the daemon.
  property var pendingCmd: null

  readonly property var levelOptions: [
    { value: "off",  label: "Off"  },
    { value: "low",  label: "Low"  },
    { value: "med",  label: "Med"  },
    { value: "high", label: "High" }
  ]

  readonly property var swatches: [
    "FFFFFF", "FF0000", "FF6A00", "FFD400", "6AFF00",
    "00FF88", "00E5FF", "0066FF", "8A2BE2", "FF00FF"
  ]

  readonly property string effectiveLevel: onBattery ? kbdBattery : kbdAC
  readonly property bool kbdOn: kbdBrightness > 0
  readonly property bool anyOn: kbdOn || slashOn
  readonly property int slashPercent: Math.round(slashBrightness / 255 * 100)

  // 0 = System (front page), 1 = Keyboard, 2 = Lid slash.
  property int tab: 0

  // ---- display (refresh goes through power-tune, never a raw modeset:
  // a hotplug or `hyprctl reload` re-applies monitors.lua and would revert it) ----
  property int refreshHz: 0
  property string refreshOverride: "auto"
  readonly property bool refreshAvailable: root.refreshHz > 0
  readonly property var refreshOptions: [
    { value: "60",   label: "60Hz"  },
    { value: "240",  label: "240Hz" },
    { value: "auto", label: "Auto"  }
  ]

  // ---- battery charge ceiling (asusctl; sysfs is the source of truth) ----
  property int chargeLimit: 0
  readonly property bool chargeAvailable: root.chargeLimit > 0
  readonly property var chargeOptions: [
    { value: "60",  label: "60%"  },
    { value: "80",  label: "80%"  },
    { value: "100", label: "100%" }
  ]

  // ---- Win-lock (firmware Fn+Super; helper + user service) ----
  property bool hasWinlock: false
  property string winlockMode: "toast"
  property string winlockService: "inactive"
  readonly property bool winlockAvailable: root.hasWinlock
  readonly property var winlockModeOptions: [
    { value: "toast",  label: "Toast"  },
    { value: "unlock", label: "Unlock" }
  ]

  function runCmd(args) {
    if (actionProc.running) { root.pendingCmd = args; return }
    actionProc.command = args
    actionProc.running = true
  }

  function refresh() { if (!stateProc.running) stateProc.running = true }

  function bool(v) { return String(v) === "true" }

  function parseState(raw) {
    var lines = String(raw).trim().split("\n")
    var m = ({})
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      m[lines[i].slice(0, eq).trim()] = lines[i].slice(eq + 1).trim()
    }
    if (m["HasAura"] === undefined) return

    root.hasAura = bool(m["HasAura"])
    root.kbdBrightness = parseInt(m["KbdBrightness"]) || 0
    if (m["KbdColor"]) root.kbdColor = m["KbdColor"]
    if (m["KbdAC"]) root.kbdAC = m["KbdAC"]
    if (m["KbdBattery"]) root.kbdBattery = m["KbdBattery"]
    root.onBattery = bool(m["OnBattery"])
    root.kbdBoot = bool(m["KbdBoot"])
    root.kbdAwake = bool(m["KbdAwake"])
    root.kbdSleep = bool(m["KbdSleep"])
    root.kbdShutdown = bool(m["KbdShutdown"])

    root.hasSlash = bool(m["HasSlash"])
    if (root.hasSlash) {
      root.slashOn = bool(m["SlashEnabled"])
      // Do not yank the handle out from under a drag in progress.
      if (!slashSlider.dragging)
        root.slashBrightness = parseInt(m["SlashBrightness"]) || 0
      root.slashPattern = parseInt(m["SlashPattern"]) || 0
      root.slashPatternName = m["SlashPatternName"] || ""
      root.showOnBoot = bool(m["SlashShowOnBoot"])
      root.showOnShutdown = bool(m["SlashShowOnShutdown"])
      root.showOnSleep = bool(m["SlashShowOnSleep"])
      root.showOnBattery = bool(m["SlashShowOnBattery"])
      root.showBatteryWarning = bool(m["SlashShowBatteryWarning"])
      root.showOnLidClosed = bool(m["SlashShowOnLidClosed"])
    }

    root.refreshHz = parseInt(m["RefreshHz"]) || 0
    if (m["RefreshOverride"]) root.refreshOverride = m["RefreshOverride"]
    root.chargeLimit = parseInt(m["ChargeLimit"]) || 0

    root.hasWinlock = bool(m["HasWinlock"])
    if (m["WinlockMode"]) root.winlockMode = m["WinlockMode"]
    if (m["WinlockService"]) root.winlockService = m["WinlockService"]
  }

  function parseModes(raw) {
    var out = []
    var lines = String(raw).trim().split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.length > 0) out.push(name)
    }
    if (out.length > 0) root.slashModes = out
  }

  // Optimistic local update: the restart-and-reapply round trip takes a moment,
  // and leaving the segmented control on its old value that whole time reads as
  // a dropped click.
  function setLevel(scope, value) {
    if (scope === "ac") root.kbdAC = value
    else if (scope === "battery") root.kbdBattery = value
    else { root.kbdAC = value; root.kbdBattery = value }
    runCmd([root.helper, "kbd-level", scope, value])
  }

  function toggleKeyboard() {
    setLevel("both", root.kbdOn ? "off" : "med")
  }

  function setColor(hex) {
    root.kbdColor = hex
    runCmd([root.helper, "kbd-color", hex])
  }

  function setKbdPower(flag, value) {
    runCmd([root.helper, "kbd-power", flag, value ? "true" : "false"])
  }

  function toggleSlash() {
    root.slashOn = !root.slashOn
    runCmd([root.helper, "slash-enabled", root.slashOn ? "true" : "false"])
  }

  function setSlashPattern(index) {
    if (index < 0 || index >= root.slashModes.length) return
    root.slashPattern = index
    root.slashPatternName = root.slashModes[index]
    runCmd([root.helper, "slash-pattern", String(index)])
  }

  function applySlashBrightness() {
    runCmd([root.helper, "slash-brightness", String(root.slashBrightness)])
  }

  function setSlashFlag(name, value) {
    runCmd([root.helper, "slash-flag", name, value ? "true" : "false"])
  }

  // Named setRefreshHz, not setRefresh: refresh() already means "re-read state".
  function setRefreshHz(value) {
    root.refreshOverride = value
    runCmd([root.helper, "refresh", value])
  }

  function setChargeLimit(value) {
    root.chargeLimit = parseInt(value) || 0
    runCmd([root.helper, "battery-limit", value])
  }

  function setWinlockMode(value) {
    root.winlockMode = value
    runCmd([root.helper, "winlock-mode", value])
  }

  visible: hasAura || hasSlash || refreshAvailable || chargeAvailable || winlockAvailable
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  Process {
    id: stateProc
    command: [root.helper, "get"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseState(text) }
  }

  Process {
    id: modesProc
    running: true
    command: [root.helper, "list-modes"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseModes(text) }
  }

  Process {
    id: actionProc
    onExited: {
      if (root.pendingCmd) {
        var next = root.pendingCmd
        root.pendingCmd = null
        actionProc.command = next
        actionProc.running = true
      } else {
        root.refresh()
      }
    }
  }

  Timer {
    id: slashThrottle
    interval: 120
    repeat: false
    onTriggered: root.applySlashBrightness()
  }

  // Polls whether or not the panel is open, so the bar icon still tracks changes
  // made from a terminal. `get` fans out to several busctl calls, so the closed
  // interval is kept long.
  Timer {
    interval: root.opened ? 3000 : 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    // Stays the lid-slash streak even though this widget now covers both
    // lights: the slash is this laptop model's own mark, so it reads as "the
    // LEDs on this machine" in a way a generic keyboard glyph does not.
    iconComponent: Component {
      Item {
        SlashMark {
          anchors.centerIn: parent
          width: Style.space(13)
          height: Style.space(13)
          lit: root.anyOn
        }
      }
    }
    active: root.anyOn
    tooltipText: {
      var parts = []
      if (root.hasAura)
        parts.push("Keyboard " + (root.kbdOn ? root.effectiveLevel : "off"))
      if (root.hasSlash)
        parts.push("Slash " + (root.slashOn ? root.slashPatternName : "off"))
      return parts.join("  ·  ")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.hasAura) root.toggleKeyboard()
        else root.toggleSlash()
      } else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && (root.hasAura || root.hasSlash)
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Only interactive when there is something to scroll. The panel fits
        // whole on the 1440p external; it is the 1000px-tall internal panel
        // (2560x1600 at scale 1.6) that needs this.
        interactive: contentHeight > height

        Column {
          id: column
          width: panelScroll.width
          spacing: Style.space(14)

          // ---------- Tabs ----------
          // System leads: refresh and charge ceiling are the controls reached
          // for daily. The LEDs are deliberately one step back.
          ButtonGroup {
            id: tabs
            width: parent.width
            visible: root.hasAura || root.hasSlash
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            options: [
              { value: "system",   label: "System"    },
              { value: "keyboard", label: "Keyboard"  },
              { value: "slash",    label: "Lid slash" }
            ]
            value: root.tab === 0 ? "system" : (root.tab === 1 ? "keyboard" : "slash")
            onChanged: function(v) {
              root.tab = (v === "system") ? 0 : (v === "keyboard" ? 1 : 2)
            }
          }

          // ================= KEYBOARD =================
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.hasAura && root.tab === 1

            PanelHero {
              width: parent.width
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              title: "Keyboard"
              meta: (root.kbdOn ? root.effectiveLevel : "off").toUpperCase()
              detail: root.onBattery ? "on battery" : "on AC"
              iconComponent: Component {
                KeyboardMark {
                  lit: root.kbdOn
                  color: root.bar ? root.bar.foreground : Color.foreground
                  implicitWidth: Style.space(34)
                  implicitHeight: Style.space(26)
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  checked: root.kbdOn
                  foreground: root.bar.foreground
                  onToggled: root.toggleKeyboard()
                }
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Level, per power source ----------
            Column {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              LevelRow {
                label: "On AC"
                value: root.kbdAC
                live: !root.onBattery
                onPicked: function(v) { root.setLevel("ac", v) }
              }

              LevelRow {
                label: "On battery"
                value: root.kbdBattery
                live: root.onBattery
                onPicked: function(v) { root.setLevel("battery", v) }
              }

              Text {
                width: parent.width
                text: "power-tune re-applies these on every power change, so they are "
                    + "set here rather than as one live slider."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Colour ----------
            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "COLOUR"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: swatchGrid
                width: parent.width
                columns: 10
                spacing: Style.space(6)

                readonly property real cell:
                  (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: root.swatches
                  Rectangle {
                    required property var modelData
                    width: swatchGrid.cell
                    height: swatchGrid.cell
                    radius: width / 2
                    color: "#" + modelData
                    border.width: root.kbdColor.toUpperCase() === String(modelData).toUpperCase() ? 2 : 0
                    border.color: root.bar.foreground
                    opacity: root.kbdOn ? 1.0 : 0.55

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setColor(String(modelData))
                    }

                    Behavior on opacity { NumberAnimation { duration: 150 } }
                  }
                }
              }

              Text {
                width: parent.width
                visible: !root.kbdOn
                text: "Backlight is off, so a colour change will not be visible yet."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Power states ----------
            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "KEEP LIT DURING"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: kbdPowerGrid
                width: parent.width
                columns: 4
                spacing: Style.space(6)

                readonly property real cellWidth:
                  (width - spacing * (columns - 1)) / columns

                FlagButton {
                  grid: kbdPowerGrid; label: "Boot"; state: root.kbdBoot
                  onToggle: root.setKbdPower("boot", !root.kbdBoot)
                }
                FlagButton {
                  grid: kbdPowerGrid; label: "Awake"; state: root.kbdAwake
                  onToggle: root.setKbdPower("awake", !root.kbdAwake)
                }
                FlagButton {
                  grid: kbdPowerGrid; label: "Sleep"; state: root.kbdSleep
                  onToggle: root.setKbdPower("sleep", !root.kbdSleep)
                }
                FlagButton {
                  grid: kbdPowerGrid; label: "Shutdown"; state: root.kbdShutdown
                  onToggle: root.setKbdPower("shutdown", !root.kbdShutdown)
                }
              }
            }
          }

          // ================= SLASH =================
          Column {
            width: parent.width
            spacing: Style.space(14)
            visible: root.hasSlash && root.tab === 2

            PanelHero {
              width: parent.width
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              title: "Lid slash"
              meta: (root.slashOn ? (root.slashPatternName || "ON") : "OFF").toUpperCase()
              detail: root.slashOn ? root.slashPercent + "% brightness" : ""
              iconComponent: Component {
                SlashMark {
                  lit: root.slashOn
                  color: root.bar ? root.bar.foreground : Color.foreground
                  implicitWidth: Style.space(26)
                  implicitHeight: Style.space(34)
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  checked: root.slashOn
                  foreground: root.bar.foreground
                  onToggled: root.toggleSlash()
                }
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Brightness ----------
            Column {
              width: parent.width
              spacing: Style.space(8)

              Item {
                width: parent.width
                implicitHeight: slashHeader.implicitHeight

                PanelSectionHeader {
                  id: slashHeader
                  text: "BRIGHTNESS"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                }

                Text {
                  anchors.verticalCenter: slashHeader.verticalCenter
                  text: root.slashPercent + "%"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              PanelSlider {
                id: slashSlider
                bar: root.bar
                width: parent.width
                minimum: 0
                maximum: 255
                step: 1
                integer: true
                value: root.slashBrightness
                onMoved: function(v) {
                  root.slashBrightness = Math.round(v)
                  slashThrottle.restart()
                }
                onReleased: function(v) {
                  root.slashBrightness = Math.round(v)
                  slashThrottle.stop()
                  root.applySlashBrightness()
                }
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Pattern ----------
            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "PATTERN"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: modeGrid
                width: parent.width
                columns: 3
                spacing: Style.space(6)

                readonly property real cellWidth:
                  (width - spacing * (columns - 1)) / columns

                Repeater {
                  model: root.slashModes
                  Button {
                    required property var modelData
                    required property int index
                    width: modeGrid.cellWidth
                    text: String(modelData)
                    fontSize: Style.font.bodySmall
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.controlPaddingY
                    bordered: true
                    active: root.slashPattern === index
                    onClicked: root.setSlashPattern(index)
                  }
                }
              }

              Text {
                width: parent.width
                text: "Static is the steady one. Most others animate, and a few sit dark between plays."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            // ---------- Event animations ----------
            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "SHOW ANIMATION ON"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Grid {
                id: eventGrid
                width: parent.width
                columns: 3
                spacing: Style.space(6)

                readonly property real cellWidth:
                  (width - spacing * (columns - 1)) / columns

                FlagButton {
                  grid: eventGrid; label: "Boot"; state: root.showOnBoot
                  onToggle: root.setSlashFlag("ShowOnBoot", !root.showOnBoot)
                }
                FlagButton {
                  grid: eventGrid; label: "Shutdown"; state: root.showOnShutdown
                  onToggle: root.setSlashFlag("ShowOnShutdown", !root.showOnShutdown)
                }
                FlagButton {
                  grid: eventGrid; label: "Sleep"; state: root.showOnSleep
                  onToggle: root.setSlashFlag("ShowOnSleep", !root.showOnSleep)
                }
                FlagButton {
                  grid: eventGrid; label: "Battery"; state: root.showOnBattery
                  onToggle: root.setSlashFlag("ShowOnBattery", !root.showOnBattery)
                }
                FlagButton {
                  grid: eventGrid; label: "Low batt"; state: root.showBatteryWarning
                  onToggle: root.setSlashFlag("ShowBatteryWarning", !root.showBatteryWarning)
                }
                FlagButton {
                  grid: eventGrid; label: "Lid shut"; state: root.showOnLidClosed
                  onToggle: root.setSlashFlag("ShowOnLidClosed", !root.showOnLidClosed)
                }
              }
            }
          }

          // ================= DISPLAY =================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.refreshAvailable && root.tab === 0

            PanelSectionHeader {
              text: "DISPLAY"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            LevelRow {
              label: "Refresh"
              options: root.refreshOptions
              value: root.refreshOverride
              live: true
              onPicked: function(v) { root.setRefreshHz(v) }
            }

            Text {
              width: parent.width
              text: "Now " + root.refreshHz + "Hz. Auto follows power (60 on battery with your "
                  + "defaults). Pin 60 or 240 anytime — including on battery — if you want to "
                  + "override and burn the watts."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ================= BATTERY =================
          PanelSeparator {
            visible: root.chargeAvailable && root.refreshAvailable && root.tab === 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.chargeAvailable && root.tab === 0

            PanelSectionHeader {
              text: "BATTERY"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            LevelRow {
              label: "Charge to"
              options: root.chargeOptions
              value: String(root.chargeLimit)
              live: true
              onPicked: function(v) { root.setChargeLimit(v) }
            }

            Text {
              width: parent.width
              text: "Stopping short of full is the single biggest lever on pack "
                  + "lifespan. 100% is right before a trip, not as a resting state."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ================= WIN-LOCK =================
          PanelSeparator {
            visible: root.winlockAvailable && root.tab === 0
              && (root.refreshAvailable || root.chargeAvailable)
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.winlockAvailable && root.tab === 0

            PanelSectionHeader {
              text: "SUPER"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            LevelRow {
              label: "On Fn+Super"
              options: root.winlockModeOptions
              value: root.winlockMode
              live: true
              onPicked: function(v) { root.setWinlockMode(v) }
            }


            Text {
              width: parent.width
              text: root.winlockMode === "unlock"
                ? "Unlock mode fights accidental Fn+Super: toast, then SetFeature unlock. Service: "
                  + root.winlockService + "."
                : "Toast mode shows an OSD when firmware Super-lock toggles. Service: "
                  + root.winlockService + "."
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

        }
      }
    }
  }

  // A labelled segmented row. `live` marks the power source currently in force,
  // so it is obvious which of the two rows is the one you can see right now.
  component LevelRow: Item {
    id: row
    property string label: ""
    property string value: "off"
    property bool live: false
    // Defaults to the keyboard levels; Display and Battery pass their own.
    property var options: root.levelOptions
    signal picked(string value)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, group.implicitHeight)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(76)
      text: row.label
      color: row.live ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: row.live
      elide: Text.ElideRight
    }

    ButtonGroup {
      id: group
      anchors.left: rowLabel.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      fontSize: Style.font.bodySmall
      options: row.options
      value: row.value
      onChanged: function(v) { row.picked(v) }
    }
  }

  component FlagButton: Button {
    property Grid grid: null
    property string label: ""
    property bool state: false
    signal toggle()

    width: grid ? grid.cellWidth : implicitWidth
    text: label
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    active: state
    onClicked: toggle()
  }

  // Drawn rather than typeset, for the same reason the slash mark is: the bar
  // font has no keyboard glyph that reads correctly at 14px.
  component KeyboardMark: Item {
    id: kb
    property bool lit: false
    property color color: root.barForeground
    readonly property color ink: lit ? color : Qt.darker(color, 1.55)

    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)

    Rectangle {
      anchors.centerIn: parent
      width: kb.width
      height: Math.round(kb.width * 0.72)
      radius: Math.max(2, Math.round(kb.width * 0.14))
      color: "transparent"
      border.width: Math.max(1, Math.round(kb.width * 0.09))
      border.color: kb.ink

      Behavior on border.color { ColorAnimation { duration: 200 } }

      // Three key rows, the last one a single wide "spacebar".
      Column {
        anchors.centerIn: parent
        spacing: Math.max(1, Math.round(kb.width * 0.07))

        Repeater {
          model: 2
          Row {
            spacing: Math.max(1, Math.round(kb.width * 0.07))
            Repeater {
              model: 4
              Rectangle {
                width: Math.max(1, Math.round(kb.width * 0.11))
                height: Math.max(1, Math.round(kb.width * 0.09))
                radius: height / 2
                color: kb.ink
                Behavior on color { ColorAnimation { duration: 200 } }
              }
            }
          }
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.round(kb.width * 0.44)
          height: Math.max(1, Math.round(kb.width * 0.09))
          radius: height / 2
          color: kb.ink
          Behavior on color { ColorAnimation { duration: 200 } }
        }
      }
    }
  }

  // The lid element is one bold diagonal streak of mini-LEDs. Carried over from
  // the older Slash-only widget unchanged; see that widget's notes on why it is drawn and why
  // the lean is 55.2 degrees (the GA605 lid is 354 x 246 mm).
  component SlashMark: Item {
    id: mark
    property bool lit: false
    property color color: root.barForeground
    property real thickness: 0.15
    property real lean: -55.2

    implicitWidth: Style.space(16)
    implicitHeight: Style.space(16)

    readonly property real _rad: Math.abs(mark.lean) * Math.PI / 180
    readonly property real _len: Math.min(mark.height * 1.35,
                                          mark.width * 0.82 / Math.max(0.25, Math.sin(_rad)))

    Rectangle {
      anchors.centerIn: parent
      width: Math.max(2, Math.round(mark.height * mark.thickness))
      height: Math.round(mark._len)
      radius: width / 2
      rotation: mark.lean
      color: mark.lit ? mark.color : Qt.darker(mark.color, 1.55)

      Behavior on color { ColorAnimation { duration: 200 } }
    }
  }
}
