#!/usr/bin/python3 -I
"""Persistent bridge for the G16 Control widget (omarchy-asus.g16).

Launched by Service.qml as `/usr/bin/python3 -I -B <this file>` with a closed
environment. It speaks line-delimited JSON on stdin/stdout: commands in
({"id": N, "cmd": "...", "args": [...]}), and out a "state" object whenever
something changes plus one "reply" per command. Every state object carries
"ack", the id of the last command handled, so the shell can tell a state that
predates its latest click from one that includes it.

What it follows, all pushed, nothing on a timer:
  - asusd (xyz.ljones.Asusd, system bus): the keyboard's Aura object
    (brightness, colour, power flags), the lid Slash bar, the battery charge
    limit and panel overdrive, through PropertiesChanged signals. asusd
    leaving or coming back is seen as a bus name change.
  - UPower's OnBattery (system bus).
  - Hyprland's event socket: a monitor hotplug or a config reload re-applies
    monitors.lua, which puts the internal panel back on its native refresh
    rate, so both re-apply the per-source refresh rate.
  - The keyboard LED's brightness_hw_changed (Fn+F2/F3 bypass asusd), and
    the settings and state files below, through inotify.

Per power source (what omarchy-power-tune used to do, folded in here), from
~/.config/omarchy/power-tune.conf (same keys, plain KEY=VALUE, never sourced):
  KBD_AC / KBD_BATTERY                  off | low | med | high
  HZ_AC / HZ_BATTERY / HZ_GAMING        refresh rate of the internal panel
  PANEL_OVERDRIVE_AC / _BATTERY         0 | 1
  INTERNAL_OUTPUT                       connector name, or desc:<EDID description>
  BITDEPTH                              carried on every modeset (default: the
                                        panel's current format, 10 or 8)
A key that is absent is left alone: with no file nothing is enforced. The
refresh pin (~/.local/state/omarchy/power-tune-hz, an integer) wins over
gaming mode (power-tune-gaming exists), which wins over the power source.

Only the Python standard library and PyGObject's Gio/GLib are used. Nothing
here spawns a process or uses a shell. `g16_bridge.py gaming on|off|toggle`
and `g16_bridge.py hz <N>|auto` only write the state files and exit; the
running bridge sees the change and applies it.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402

# Local files and inotify only: never start gvfs (a session-bus daemon) for
# the file watches below.
os.environ["GIO_USE_VFS"] = "local"
os.environ["GIO_USE_VOLUME_MONITOR"] = "unix"

import gi  # noqa: E402

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

ASUSD = "xyz.ljones.Asusd"
AURA = "xyz.ljones.Aura"
SLASH = "xyz.ljones.Slash"
UPOWER = "org.freedesktop.UPower"
PROPS = "org.freedesktop.DBus.Properties"
SYSTEMD = "org.freedesktop.systemd1"
LEVELS = ["off", "low", "med", "high"]
SLASH_MODES = ["Static", "Bounce", "Slash", "Loading", "BitStream", "Transmission",
               "Flow", "Flux", "Phantom", "Spectrum", "Hazard", "Interfacing",
               "Ramp", "GameOver", "Start", "Buzzer"]
SLASH_FLAGS = ["ShowOnBoot", "ShowOnShutdown", "ShowOnSleep", "ShowOnBattery",
               "ShowBatteryWarning", "ShowOnLidClosed"]
CHARGE_PROP = "ChargeControlEndThreshold"
OVERDRIVE_NAME = "panel_overdrive"
WINLOCK_BIN = "/usr/bin/g16-winlock"
WINLOCK_UNIT = "g16-winlock.service"
MAX_LINE = 4096
CONF_KEYS = {"KBD_AC", "KBD_BATTERY", "HZ_AC", "HZ_BATTERY", "HZ_GAMING",
             "PANEL_OVERDRIVE_AC", "PANEL_OVERDRIVE_BATTERY", "INTERNAL_OUTPUT",
             "BITDEPTH"}


def env(name, default=""):
    v = os.environ.get(name, "")
    return v if v else default


HOME = env("HOME", "/")
CONFIG_HOME = env("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
STATE_HOME = env("XDG_STATE_HOME", os.path.join(HOME, ".local", "state"))
CONF_PATH = os.path.join(CONFIG_HOME, "omarchy", "power-tune.conf")
STATE_DIR = os.path.join(STATE_HOME, "omarchy")
HZ_PIN = os.path.join(STATE_DIR, "power-tune-hz")
GAMING_FLAG = os.path.join(STATE_DIR, "power-tune-gaming")
WINLOCK_DROPIN = os.path.join(CONFIG_HOME, "systemd", "user", WINLOCK_UNIT + ".d")
WINLOCK_MODE_CONF = os.path.join(WINLOCK_DROPIN, "mode.conf")
# Tests point these at a temp tree; on a real system they are the defaults.
SYSROOT = env("G16_BRIDGE_SYSROOT", "/sys")
WINLOCK_PATH = env("G16_BRIDGE_WINLOCK", WINLOCK_BIN)


def log(msg):
    print(f"g16-bridge: {msg}", file=sys.stderr, flush=True)


# ------------------------------------------------------------------ files
def read_conf(path=CONF_PATH):
    """KEY=VALUE lines; quotes stripped; anything else ignored (never sourced)."""
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"^\s*([A-Z_]+)=([\"']?)(.*?)\2\s*(?:#.*)?$", line)
                if m and m.group(1) in CONF_KEYS:
                    out[m.group(1)] = m.group(3).strip()
    except OSError:
        pass
    return out


def write_conf_key(key, value, path=CONF_PATH):
    """Rewrite KEY in place, or append it; other lines are kept as they are."""
    if key not in CONF_KEYS or not re.fullmatch(r"[A-Za-z0-9_.:\- ]*", value):
        raise ValueError(f"bad conf value for {key}")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = ["# Per power source settings for the G16 Control widget (and the",
                 "# omarchy-power-tune keys it replaces). A missing key is left alone."]
    done = False
    for i, line in enumerate(lines):
        if re.match(rf"^\s*{key}=", line):
            lines[i] = f"{key}={value}"
            done = True
    if not done:
        lines.append(f"{key}={value}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".g16-bridge.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def read_int_file(path):
    try:
        with open(path, encoding="ascii", errors="replace") as f:
            v = re.sub(r"[^0-9]", "", f.read())
        return int(v) if v else None
    except OSError:
        return None


def pinned_hz():
    return read_int_file(HZ_PIN)


def gaming_on():
    return os.path.exists(GAMING_FLAG)


def set_pin(value):
    os.makedirs(STATE_DIR, exist_ok=True)
    if value == "auto":
        try:
            os.unlink(HZ_PIN)
        except FileNotFoundError:
            pass
    elif re.fullmatch(r"[0-9]{2,3}", value):
        with open(HZ_PIN, "w", encoding="ascii") as f:
            f.write(value + "\n")
    else:
        raise ValueError(f"bad refresh value: {value}")


def set_gaming(value):
    os.makedirs(STATE_DIR, exist_ok=True)
    on = {"on": True, "off": False, "toggle": not gaming_on()}.get(value)
    if on is None:
        raise ValueError(f"bad gaming value: {value}")
    if on:
        open(GAMING_FLAG, "a").close()
    else:
        try:
            os.unlink(GAMING_FLAG)
        except FileNotFoundError:
            pass


def charge_limit_sysfs():
    base = os.path.join(SYSROOT, "class", "power_supply")
    try:
        names = sorted(n for n in os.listdir(base) if n.startswith("BAT"))
    except OSError:
        return 0
    for n in names:
        v = read_int_file(os.path.join(base, n, "charge_control_end_threshold"))
        if v is not None:
            return v
    return 0


def winlock_mode():
    m = "toast"
    try:
        with open(WINLOCK_MODE_CONF, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("Environment=G16_WINLOCK_MODE="):
                    m = line.split("=", 2)[2].strip().strip('"')
    except OSError:
        pass
    return m if m in ("toast", "unlock") else "toast"


# ------------------------------------------------------------------ hyprland
class Hyprland:
    """Hyprland's IPC: requests on .socket.sock ("<flags>/<command>", the way
    hyprctl sends them), events on .socket2.sock ("event>>data" lines)."""

    def __init__(self, on_event):
        sig = env("HYPRLAND_INSTANCE_SIGNATURE")
        run = env("XDG_RUNTIME_DIR")
        self.dir = os.path.join(run, "hypr", sig) if sig and run else ""
        self.on_event = on_event
        self.events = None
        self.buf = b""

    @property
    def available(self):
        return bool(self.dir) and os.path.exists(os.path.join(self.dir, ".socket.sock"))

    def request(self, cmd, timeout=2.0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(os.path.join(self.dir, ".socket.sock"))
            s.sendall(cmd.encode())
            chunks = []
            while True:
                d = s.recv(65536)
                if not d:
                    break
                chunks.append(d)
            return b"".join(chunks).decode(errors="replace")
        finally:
            s.close()

    def monitors(self):
        try:
            data = json.loads(self.request("j/monitors"))
            return data if isinstance(data, list) else []
        except (OSError, ValueError):
            return []

    def listen(self):
        if not self.dir or self.events:
            return
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(os.path.join(self.dir, ".socket2.sock"))
        except OSError as e:
            log(f"no Hyprland event socket: {e}")
            return
        s.setblocking(False)
        self.events = s
        GLib.io_add_watch(s.fileno(), GLib.PRIORITY_DEFAULT,
                          GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                          self._readable)

    def _readable(self, _fd, cond):
        try:
            d = self.events.recv(65536)
        except BlockingIOError:
            return True
        except OSError:
            d = b""
        if not d or cond & (GLib.IOCondition.HUP | GLib.IOCondition.ERR):
            self.events.close()
            self.events = None
            GLib.timeout_add_seconds(5, lambda: (self.listen(), False)[1])
            return False
        self.buf += d
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            name = line.split(b">>", 1)[0].decode(errors="replace")
            self.on_event(name)
        if len(self.buf) > MAX_LINE:
            self.buf = b""
        return True


# ------------------------------------------------------------------ bridge
class Bridge:
    def __init__(self):
        self.loop = GLib.MainLoop()
        self.system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
        try:
            self.session = Gio.bus_get_sync(Gio.BusType.SESSION)
        except GLib.Error:
            self.session = None
        self.ack = 0
        self.last_sent = None
        self.emit_pending = False
        self.on_battery = False
        self.conf = read_conf()
        self.aura = None      # object path
        self.slash = None
        self.charge = None    # (path, interface)
        self.overdrive = None  # (path, interface, property)
        self.cache = {}       # (path, iface) -> {prop: python value}
        self.hypr = Hyprland(self.hypr_event)
        self.refresh_hz = 0
        self.output = ""
        self.inbuf = b""
        self.monitors_ = []
        self.apply_timer = 0
        self.file_timer = 0
        self.winlock_state = "inactive"

    # ---- output ----
    def send(self, obj):
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    def state(self):
        aura = self.cache.get((self.aura, AURA), {}) if self.aura else {}
        slash = self.cache.get((self.slash, SLASH), {}) if self.slash else {}
        bright = aura.get("Brightness", 0)
        lmd = aura.get("LedModeData")
        color = "FF00FF"
        if isinstance(lmd, (list, tuple)) and len(lmd) >= 3 and len(lmd[2]) == 3:
            color = "".join(f"{int(c) & 255:02X}" for c in lmd[2])
        power = aura.get("LedPower")
        flags = [True, True, True, True]
        try:
            entry = power[0][0] if isinstance(power[0], (list, tuple)) and power[0] and isinstance(power[0][0], (list, tuple)) else power[0]
            flags = [bool(x) for x in entry[1:5]]
        except (TypeError, IndexError, KeyError):
            pass
        charge = charge_limit_sysfs()
        if self.charge:
            charge = int(self.cache.get(self.charge, {}).get(CHARGE_PROP, charge) or charge)
        pin = pinned_hz()
        s = {
            "type": "state", "ack": self.ack,
            "onBattery": self.on_battery,
            "hasAura": bool(self.aura),
            "kbdBrightness": max(0, min(3, int(bright))) if isinstance(bright, int) else 0,
            "kbdColor": color,
            "kbdAC": self.conf.get("KBD_AC", ""), "kbdBattery": self.conf.get("KBD_BATTERY", ""),
            "kbdBoot": flags[0], "kbdAwake": flags[1], "kbdSleep": flags[2], "kbdShutdown": flags[3],
            "hasSlash": bool(self.slash),
            "slashOn": bool(slash.get("Enabled", False)),
            "slashBrightness": int(slash.get("Brightness", 0) or 0),
            "slashPattern": int(slash.get("Interval", 0) or 0),
            "slashModes": SLASH_MODES,
            "chargeLimit": charge,
            "hasPanel": bool(self.output),
            "refreshHz": self.refresh_hz,
            "refreshOverride": str(pin) if pin else "auto",
            "gaming": gaming_on(),
            "hasOverdrive": bool(self.overdrive),
            "hasWinlock": os.access(WINLOCK_PATH, os.X_OK),
            "winlockMode": winlock_mode(),
            "winlockService": self.winlock_state,
        }
        for f in SLASH_FLAGS:
            s[f[0].lower() + f[1:]] = bool(slash.get(f, False))
        return s

    def emit(self):
        if self.emit_pending:
            return
        self.emit_pending = True

        def go():
            self.emit_pending = False
            s = self.state()
            if s != self.last_sent:
                self.last_sent = s
                self.send(s)
            return False
        GLib.timeout_add(30, go)

    # ---- D-Bus helpers ----
    def call(self, bus, name, path, iface, method, args=None, reply=None, timeout=3000):
        return bus.call_sync(name, path, iface, method, args, reply and GLib.VariantType(reply),
                             Gio.DBusCallFlags.NONE, timeout, None)

    def get_all(self, path, iface):
        try:
            v = self.call(self.system, ASUSD, path, PROPS, "GetAll",
                          GLib.Variant("(s)", (iface,)), "(a{sv})")
            self.cache[(path, iface)] = dict(v.unpack()[0])
        except GLib.Error as e:
            log(f"GetAll {path} {iface}: {e.message}")

    def set_prop(self, path, iface, prop, variant):
        self.call(self.system, ASUSD, path, PROPS, "Set",
                  GLib.Variant("(ssv)", (iface, prop, variant)))

    def raw_prop(self, path, iface, prop):
        v = self.call(self.system, ASUSD, path, PROPS, "Get",
                      GLib.Variant("(ss)", (iface, prop)), "(v)")
        return v.get_child_value(0).get_variant()

    # ---- asusd discovery ----
    def discover(self):
        self.aura = self.slash = self.charge = self.overdrive = None
        self.cache = {}
        seen = 0
        stack = ["/"]
        while stack and seen < 256:
            path = stack.pop()
            seen += 1
            try:
                xml = self.call(self.system, ASUSD, path, "org.freedesktop.DBus.Introspectable",
                                "Introspect", None, "(s)").unpack()[0]
                node = Gio.DBusNodeInfo.new_for_xml(xml)
            except GLib.Error:
                continue
            for child in node.nodes:
                stack.append((path.rstrip("/") + "/" + child.path) if child.path else path)
            for iface in node.interfaces:
                names = {p.name for p in iface.properties}
                if iface.name == AURA and not self.aura:
                    self.aura = path
                elif iface.name == SLASH and not self.slash:
                    self.slash = path
                elif CHARGE_PROP in names and not self.charge:
                    self.charge = (path, iface.name)
                if iface.name.startswith("xyz.ljones.") and not self.overdrive:
                    self.match_overdrive(path, iface.name, names)
        for key in [(self.aura, AURA), (self.slash, SLASH), self.charge,
                    self.overdrive[:2] if self.overdrive else None]:
            if key and key[0]:
                self.get_all(*key)
        log(f"asusd: aura={self.aura} slash={self.slash} charge={self.charge} overdrive={self.overdrive}")

    def match_overdrive(self, path, iface, names):
        # asus-armoury attributes: one object per attribute, named by its path
        # or a Name property; the value property is CurrentValue.
        if "CurrentValue" not in names:
            return
        if path.rstrip("/").endswith(OVERDRIVE_NAME):
            self.overdrive = (path, iface, "CurrentValue")
            return
        if "Name" in names:
            try:
                if str(self.raw_prop(path, iface, "Name").unpack()) == OVERDRIVE_NAME:
                    self.overdrive = (path, iface, "CurrentValue")
            except GLib.Error:
                pass

    def asusd_appeared(self, *_):
        self.discover()
        self.apply("asusd")
        self.emit()

    def asusd_vanished(self, *_):
        self.aura = self.slash = self.charge = self.overdrive = None
        self.cache = {}
        self.emit()

    def props_changed(self, _conn, _sender, path, _iface, _signal, params):
        iface, changed, invalidated = params.unpack()
        key = (path, iface)
        if path == "/org/freedesktop/UPower" and iface == UPOWER:
            if "OnBattery" in changed and bool(changed["OnBattery"]) != self.on_battery:
                self.on_battery = bool(changed["OnBattery"])
                self.apply("power source")
            self.emit()
            return
        if key in self.cache:
            self.cache[key].update(changed)
            if invalidated:
                self.get_all(path, iface)
            self.emit()

    # ---- power source ----
    def read_on_battery(self):
        try:
            v = self.call(self.system, UPOWER, "/org/freedesktop/UPower", PROPS, "Get",
                          GLib.Variant("(ss)", (UPOWER, "OnBattery")), "(v)")
            self.on_battery = bool(v.unpack()[0])
        except GLib.Error as e:
            log(f"UPower: {e.message}")

    # ---- the per-source policy (power-tune) ----
    def source(self):
        return "BATTERY" if self.on_battery else "AC"

    def target_hz(self):
        pin = pinned_hz()
        if pin:
            return pin
        if gaming_on() and self.conf.get("HZ_GAMING", "").isdigit():
            return int(self.conf["HZ_GAMING"])
        v = self.conf.get("HZ_" + self.source(), "")
        return int(v) if v.isdigit() else None

    def apply(self, why, refresh_only=False):
        """Apply the settings for the current power source. Keys that are not
        set are left alone. Gaming mode uses the AC keyboard and overdrive."""
        src = "AC" if gaming_on() and not pinned_hz() else self.source()
        log(f"apply ({why}): {self.source().lower()}")
        self.apply_refresh()
        if refresh_only:
            return
        level = self.conf.get("KBD_" + src, "").lower()
        if level in LEVELS and self.aura:
            self.set_level_now(level)
        od = self.conf.get("PANEL_OVERDRIVE_" + src, "")
        if od in ("0", "1") and self.overdrive:
            self.set_overdrive(int(od))

    def set_level_now(self, level):
        cur = self.cache.get((self.aura, AURA), {}).get("Brightness")
        if cur == LEVELS.index(level):
            return
        try:
            v = self.raw_prop(self.aura, AURA, "Brightness")
            self.set_prop(self.aura, AURA, "Brightness",
                          GLib.Variant(v.get_type_string(), LEVELS.index(level)))
        except GLib.Error as e:
            log(f"keyboard level {level}: {e.message}")

    def set_overdrive(self, value):
        path, iface, prop = self.overdrive
        try:
            cur = self.raw_prop(path, iface, prop)
            if int(cur.unpack()) != value:
                self.set_prop(path, iface, prop, GLib.Variant(cur.get_type_string(), value))
        except GLib.Error as e:
            log(f"panel overdrive {value}: {e.message}")

    # ---- the internal panel's refresh rate ----
    def find_output(self, monitors):
        want = self.conf.get("INTERNAL_OUTPUT", "")
        if want.startswith("desc:"):
            for m in monitors:
                if m.get("description") == want[5:]:
                    return m
        for m in monitors:
            if want and m.get("name") == want:
                return m
        for m in monitors:
            if str(m.get("name", "")).startswith("eDP"):
                return m
        return None

    def read_monitors(self):
        mons = self.hypr.monitors() if self.hypr.available else []
        m = self.find_output(mons)
        self.output = m["name"] if m and re.fullmatch(r"[A-Za-z0-9-]+", str(m.get("name", ""))) else ""
        self.refresh_hz = int(round(float(m.get("refreshRate", 0)))) if m and self.output else 0
        return m

    def apply_refresh(self):
        m = self.read_monitors()
        hz = self.target_hz()
        if not m or not self.output or not hz or hz == self.refresh_hz:
            return
        depth = self.conf.get("BITDEPTH", "")
        if not depth.isdigit():
            depth = "10" if "2101010" in str(m.get("currentFormat", "")) else "8"
        try:
            scale = round(float(m.get("scale", 1)), 6)
            lua = ('hl.monitor({ output = "%s", mode = "%dx%d@%d", position = "%dx%d", scale = %s, bitdepth = %s })'
                   % (self.output, int(m["width"]), int(m["height"]), hz,
                      int(m["x"]), int(m["y"]), scale, depth))
        except (KeyError, TypeError, ValueError):
            return
        prev = self.refresh_hz
        log(f"{self.output} {prev}Hz -> {hz}Hz")
        try:
            self.hypr.request("/eval " + lua)
        except OSError as e:
            log(f"modeset: {e}")
            return

        # Check a second later, and put the old mode back rather than leave
        # the panel dark if the output vanished.
        def verify():
            m2 = self.read_monitors()
            if not m2 and prev:
                log(f"{self.output or 'internal panel'} vanished after the modeset; restoring {prev}Hz")
                try:
                    self.hypr.request("/eval " + lua.replace("@%d\"" % hz, "@%d\"" % prev))
                except OSError:
                    pass
            self.emit()
            return False
        GLib.timeout_add(1000, verify)

    def hypr_event(self, name):
        if name in ("monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded"):
            # monitors.lua re-applies on these and puts the panel back on its
            # native rate: re-apply ours once things settle.
            if self.apply_timer:
                GLib.source_remove(self.apply_timer)

            def go():
                self.apply_timer = 0
                self.apply("hyprland " + name, refresh_only=True)
                self.emit()
                return False
            self.apply_timer = GLib.timeout_add(800, go)

    # ---- files ----
    def watch_files(self):
        self.monitors_ = []
        # GLib re-checks a watched file whose directory is missing every 4 s;
        # with the directories in place the watches are plain inotify.
        for d in {os.path.dirname(p) for p in (CONF_PATH, HZ_PIN, WINLOCK_MODE_CONF)}:
            try:
                os.makedirs(d, exist_ok=True)
            except OSError as e:
                log(f"cannot create {d}: {e}")
        for path in (CONF_PATH, HZ_PIN, GAMING_FLAG, WINLOCK_MODE_CONF):
            mon = Gio.File.new_for_path(path).monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, None)
            mon.connect("changed", self.file_changed)
            self.monitors_.append(mon)
        led = os.path.join(SYSROOT, "class", "leds", "asus::kbd_backlight", "brightness_hw_changed")
        if os.path.exists(led):
            mon = Gio.File.new_for_path(led).monitor_file(Gio.FileMonitorFlags.NONE, None)
            mon.connect("changed", self.led_changed)
            self.monitors_.append(mon)

    def file_changed(self, *_):
        if self.file_timer:
            GLib.source_remove(self.file_timer)

        def go():
            self.file_timer = 0
            new = read_conf()
            self.conf = new
            self.apply("settings changed")
            self.emit()
            return False
        self.file_timer = GLib.timeout_add(200, go)

    def led_changed(self, *_):
        led = os.path.join(SYSROOT, "class", "leds", "asus::kbd_backlight", "brightness_hw_changed")
        v = read_int_file(led)
        if v is not None and self.aura:
            self.cache.setdefault((self.aura, AURA), {})["Brightness"] = v
            self.emit()

    # ---- systemd (Win-lock mode) ----
    def unit_state(self):
        if not self.session:
            return "inactive"
        try:
            path = self.call(self.session, SYSTEMD, "/org/freedesktop/systemd1",
                             SYSTEMD + ".Manager", "GetUnit", GLib.Variant("(s)", (WINLOCK_UNIT,)),
                             "(o)", 1000).unpack()[0]
            v = self.call(self.session, SYSTEMD, path, PROPS, "Get",
                          GLib.Variant("(ss)", (SYSTEMD + ".Unit", "ActiveState")), "(v)", 1000)
            return str(v.unpack()[0])
        except GLib.Error:
            return "inactive"

    def set_winlock_mode(self, mode):
        if mode not in ("toast", "unlock"):
            raise ValueError(f"bad winlock mode: {mode}")
        os.makedirs(WINLOCK_DROPIN, exist_ok=True)
        with open(WINLOCK_MODE_CONF, "w", encoding="utf-8") as f:
            f.write(f"[Service]\nEnvironment=G16_WINLOCK_MODE={mode}\n")
        if not self.session:
            return
        mgr = "/org/freedesktop/systemd1"
        self.call(self.session, SYSTEMD, mgr, SYSTEMD + ".Manager", "Reload", None, None, 10000)
        self.call(self.session, SYSTEMD, mgr, SYSTEMD + ".Manager", "EnableUnitFiles",
                  GLib.Variant("(asbb)", ([WINLOCK_UNIT], False, True)), None, 10000)
        self.call(self.session, SYSTEMD, mgr, SYSTEMD + ".Manager", "RestartUnit",
                  GLib.Variant("(ss)", (WINLOCK_UNIT, "replace")), None, 10000)

    # ---- commands ----
    def need(self, what):
        if not what:
            raise ValueError("no asusd object for this (is asusd running?)")

    def command(self, cmd, args):
        a = [str(x) for x in args]
        if cmd == "get":
            self.last_sent = None
        elif cmd == "kbd-level":
            scope, level = a[0], a[1].lower()
            if scope not in ("ac", "battery", "both") or level not in LEVELS:
                raise ValueError(f"bad kbd-level: {scope} {level}")
            for s in (["AC", "BATTERY"] if scope == "both" else [scope.upper()]):
                write_conf_key("KBD_" + s, level)
                self.conf["KBD_" + s] = level
            if scope == "both" or scope.upper() == self.source():
                self.need(self.aura)
                self.set_level_now(level)
        elif cmd == "kbd-color":
            self.need(self.aura)
            hexv = a[0].lstrip("#")
            if not re.fullmatch(r"[0-9A-Fa-f]{6}", hexv):
                raise ValueError(f"bad colour: {a[0]}")
            v = self.raw_prop(self.aura, AURA, "LedModeData")
            mode, zone, _c1, c2, speed, direction = v.unpack()
            rgb = tuple(int(hexv[i:i + 2], 16) for i in (0, 2, 4))
            self.set_prop(self.aura, AURA, "LedModeData",
                          GLib.Variant(v.get_type_string(), (mode, zone, rgb, c2, speed, direction)))
        elif cmd == "kbd-power":
            self.need(self.aura)
            idx = {"boot": 1, "awake": 2, "sleep": 3, "shutdown": 4}.get(a[0])
            if idx is None or a[1] not in ("true", "false"):
                raise ValueError(f"bad kbd-power: {a}")
            v = self.raw_prop(self.aura, AURA, "LedPower")
            val = v.unpack()
            # (a(ubbbb)): one struct holding the per-zone list.
            outer = isinstance(val, tuple) and len(val) == 1 and isinstance(val[0], list)
            states = [list(x) for x in (val[0] if outer else val)]
            if not states:
                raise ValueError("asusd reported no LED power states")
            states[0][idx] = a[1] == "true"
            new = [tuple(x) for x in states]
            self.set_prop(self.aura, AURA, "LedPower",
                          GLib.Variant(v.get_type_string(), (new,) if outer else new))
        elif cmd in ("slash-enabled", "slash-brightness", "slash-flag", "slash-pattern"):
            self.need(self.slash)
            if cmd == "slash-enabled":
                prop, raw = "Enabled", a[0] == "true"
            elif cmd == "slash-brightness":
                prop, raw = "Brightness", max(0, min(255, int(a[0])))
            elif cmd == "slash-flag":
                if a[0] not in SLASH_FLAGS:
                    raise ValueError(f"bad slash flag: {a[0]}")
                prop, raw = a[0], a[1] == "true"
            else:
                prop, raw = "Interval", int(a[0])
                if not 0 <= raw < len(SLASH_MODES):
                    raise ValueError(f"bad slash pattern: {a[0]}")
            v = self.raw_prop(self.slash, SLASH, prop)
            self.set_prop(self.slash, SLASH, prop, GLib.Variant(v.get_type_string(), raw))
        elif cmd == "refresh":
            set_pin(a[0])
            self.apply("refresh pin", refresh_only=True)
        elif cmd == "gaming":
            set_gaming(a[0])
            self.apply("gaming")
        elif cmd == "battery-limit":
            self.need(self.charge)
            n = int(a[0])
            if not 20 <= n <= 100:
                raise ValueError(f"bad charge limit: {n}")
            path, iface = self.charge
            v = self.raw_prop(path, iface, CHARGE_PROP)
            self.set_prop(path, iface, CHARGE_PROP, GLib.Variant(v.get_type_string(), n))
        elif cmd == "winlock-mode":
            self.set_winlock_mode(a[0])
        else:
            raise ValueError(f"unknown command: {cmd}")

    def stdin_readable(self, fd, cond):
        try:
            d = os.read(fd, 65536)
        except OSError:
            d = b""
        if not d:
            # The shell closed our stdin (or went away): stand down.
            self.loop.quit()
            return False
        self.inbuf += d
        while b"\n" in self.inbuf:
            line, self.inbuf = self.inbuf.split(b"\n", 1)
            self.handle_line(line)
        if len(self.inbuf) > MAX_LINE:
            self.inbuf = b""
        return True

    def handle_line(self, line):
        if not line.strip() or len(line) > MAX_LINE:
            return
        try:
            msg = json.loads(line)
            cid = int(msg.get("id", 0))
            cmd = str(msg.get("cmd", ""))
            args = msg.get("args", [])
            if not isinstance(args, list):
                raise ValueError("args must be a list")
        except (ValueError, AttributeError) as e:
            self.send({"type": "reply", "id": 0, "ok": False, "error": f"bad request: {e}"})
            return
        try:
            self.command(cmd, args)
            ok, err = True, ""
        except (ValueError, IndexError, GLib.Error, OSError) as e:
            ok, err = False, getattr(e, "message", None) or str(e)
            log(f"{cmd} {args}: {err}")
        self.ack = max(self.ack, cid)
        self.send({"type": "reply", "id": cid, "ok": ok, "error": err})
        if cmd in ("get", "winlock-mode"):
            # Not reported back over D-Bus: re-read now.
            self.read_monitors()
            self.winlock_state = self.unit_state()
        self.emit()

    # ---- run ----
    def run(self):
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            GLib.unix_signal_add(GLib.PRIORITY_HIGH, s, lambda *_: (self.loop.quit(), False)[1])
        self.system.signal_subscribe(None, PROPS, "PropertiesChanged", None, None,
                                     Gio.DBusSignalFlags.NONE, self.props_changed)
        self.read_on_battery()
        Gio.bus_watch_name_on_connection(self.system, ASUSD, Gio.BusNameWatcherFlags.NONE,
                                         self.asusd_appeared, self.asusd_vanished)
        self.watch_files()
        self.hypr.listen()
        self.read_monitors()
        self.winlock_state = self.unit_state()
        self.apply("start")
        GLib.io_add_watch(sys.stdin.fileno(), GLib.PRIORITY_DEFAULT,
                          GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                          self.stdin_readable)
        self.emit()
        self.loop.run()


def cli(argv):
    """The power-tune commands people bind to keys; the running bridge
    notices the state file change and applies it."""
    if argv[0] == "gaming":
        set_gaming(argv[1] if len(argv) > 1 else "toggle")
        print("gaming:", "on" if gaming_on() else "off")
    elif argv[0] == "hz":
        if len(argv) > 1 and argv[1] != "get":
            set_pin(argv[1])
        pin = pinned_hz()
        print("hz override:", pin if pin else "auto")
    else:
        print("usage: g16_bridge.py [gaming on|off|toggle | hz <N>|auto|get]", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.exit(cli(sys.argv[1:]))
    Bridge().run()
