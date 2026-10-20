#!/usr/bin/python3 -I
"""Fake asusd and UPower (on the bus in DBUS_SYSTEM_BUS_ADDRESS) and a fake
systemd user manager (on DBUS_SESSION_BUS_ADDRESS) for tests/bridge_test.py.

Shaped after asusd 6.x as the G16 widget uses it: the Aura and Slash
interfaces on one object, the charge limit on the platform object, and
asus-armoury attributes one object each. Every Set and method call is
appended to $FAKE_LOG as a JSON line. Commands arrive on stdin as JSON lines:
  {"set": [path, iface, prop, signature, value]}  change a value, emit PropertiesChanged
  {"asusd": false}                                 drop the asusd name (true: own it again)
Prints "ready" once every name is owned.
"""
import json
import os
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

LOG = os.environ["FAKE_LOG"]
AURA_PATH = "/xyz/ljones/aura/19b6_3_4"

ASUSD_XML = """
<node>
  <interface name="xyz.ljones.Aura">
    <property name="Brightness" type="u" access="readwrite"/>
    <property name="LedModeData" type="(uu(yyy)(yyy)ss)" access="readwrite"/>
    <property name="LedPower" type="(a(ubbbb))" access="readwrite"/>
  </interface>
  <interface name="xyz.ljones.Slash">
    <property name="Enabled" type="b" access="readwrite"/>
    <property name="Brightness" type="y" access="readwrite"/>
    <property name="Interval" type="y" access="readwrite"/>
    <property name="ShowOnBoot" type="b" access="readwrite"/>
    <property name="ShowOnShutdown" type="b" access="readwrite"/>
    <property name="ShowOnSleep" type="b" access="readwrite"/>
    <property name="ShowOnBattery" type="b" access="readwrite"/>
    <property name="ShowBatteryWarning" type="b" access="readwrite"/>
    <property name="ShowOnLidClosed" type="b" access="readwrite"/>
  </interface>
  <interface name="xyz.ljones.Platform">
    <property name="ChargeControlEndThreshold" type="y" access="readwrite"/>
  </interface>
  <interface name="xyz.ljones.AsusArmoury">
    <property name="Name" type="s" access="read"/>
    <property name="CurrentValue" type="i" access="readwrite"/>
  </interface>
</node>"""

UPOWER_XML = """
<node><interface name="org.freedesktop.UPower">
  <property name="OnBattery" type="b" access="read"/>
</interface></node>"""

SYSTEMD_XML = """
<node>
  <interface name="org.freedesktop.systemd1.Manager">
    <method name="GetUnit"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
    <method name="Reload"/>
    <method name="EnableUnitFiles">
      <arg type="as" direction="in"/><arg type="b" direction="in"/><arg type="b" direction="in"/>
      <arg type="b" direction="out"/><arg type="a(sss)" direction="out"/>
    </method>
    <method name="RestartUnit">
      <arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.systemd1.Unit">
    <property name="ActiveState" type="s" access="read"/>
  </interface>
</node>"""

# (path, iface) -> {prop: GLib.Variant}
values = {
    (AURA_PATH, "xyz.ljones.Aura"): {
        "Brightness": GLib.Variant("u", 1),
        "LedModeData": GLib.Variant("(uu(yyy)(yyy)ss)", (0, 0, (0, 255, 136), (0, 0, 0), "Med", "Right")),
        "LedPower": GLib.Variant("(a(ubbbb))", ([(1, True, True, False, True)],)),
    },
    (AURA_PATH, "xyz.ljones.Slash"): {
        "Enabled": GLib.Variant("b", True), "Brightness": GLib.Variant("y", 100),
        "Interval": GLib.Variant("y", 2), "ShowOnBoot": GLib.Variant("b", True),
        "ShowOnShutdown": GLib.Variant("b", False), "ShowOnSleep": GLib.Variant("b", False),
        "ShowOnBattery": GLib.Variant("b", False), "ShowBatteryWarning": GLib.Variant("b", True),
        "ShowOnLidClosed": GLib.Variant("b", False),
    },
    ("/xyz/ljones", "xyz.ljones.Platform"): {"ChargeControlEndThreshold": GLib.Variant("y", 80)},
    ("/xyz/ljones/asus_armoury/panel_overdrive", "xyz.ljones.AsusArmoury"): {
        "Name": GLib.Variant("s", "panel_overdrive"), "CurrentValue": GLib.Variant("i", 0)},
    ("/org/freedesktop/UPower", "org.freedesktop.UPower"): {"OnBattery": GLib.Variant("b", False)},
    ("/org/freedesktop/systemd1/unit/g16_2dwinlock_2eservice", "org.freedesktop.systemd1.Unit"): {
        "ActiveState": GLib.Variant("s", "active")},
}


def log(entry):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def changed(conn, path, iface, prop):
    conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (iface, {prop: values[(path, iface)][prop]}, [])))


def get_property(conn, sender, path, iface, prop):
    return values[(path, iface)][prop]


def set_property(conn, sender, path, iface, prop, value):
    log({"set": [path, iface, prop, value.get_type_string(), value.unpack()]})
    values[(path, iface)][prop] = value
    changed(conn, path, iface, prop)
    return True


def method_call(conn, sender, path, iface, method, params, invocation):
    log({"call": [path, iface, method, params.unpack() if params else None]})
    if method == "GetUnit":
        invocation.return_value(GLib.Variant("(o)", ("/org/freedesktop/systemd1/unit/g16_2dwinlock_2eservice",)))
    elif method == "EnableUnitFiles":
        invocation.return_value(GLib.Variant("(ba(sss))", (False, [])))
    elif method == "RestartUnit":
        invocation.return_value(GLib.Variant("(o)", ("/org/freedesktop/systemd1/job/1",)))
    else:
        invocation.return_value(None)


def register(conn, xml, objects):
    node = Gio.DBusNodeInfo.new_for_xml(xml)
    ids = []
    for path, ifaces in objects:
        for iface in node.interfaces:
            if iface.name in ifaces:
                ids.append(conn.register_object(path, iface, method_call, get_property, set_property))
    return ids


system = Gio.bus_get_sync(Gio.BusType.SYSTEM)
session = Gio.bus_get_sync(Gio.BusType.SESSION)
asusd_objects = [(AURA_PATH, ["xyz.ljones.Aura", "xyz.ljones.Slash"]),
                 ("/xyz/ljones", ["xyz.ljones.Platform"]),
                 ("/xyz/ljones/asus_armoury/panel_overdrive", ["xyz.ljones.AsusArmoury"])]
asusd_ids = register(system, ASUSD_XML, asusd_objects)
register(system, UPOWER_XML, [("/org/freedesktop/UPower", ["org.freedesktop.UPower"])])
register(session, SYSTEMD_XML, [("/org/freedesktop/systemd1", ["org.freedesktop.systemd1.Manager"]),
                                ("/org/freedesktop/systemd1/unit/g16_2dwinlock_2eservice",
                                 ["org.freedesktop.systemd1.Unit"])])


def own(conn, name):
    r = conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "RequestName", GLib.Variant("(su)", (name, 4)), None, 0, -1, None)
    assert r.unpack()[0] == 1, name


def release(conn, name):
    conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                   "ReleaseName", GLib.Variant("(s)", (name,)), None, 0, -1, None)


own(system, "org.freedesktop.UPower")
own(session, "org.freedesktop.systemd1")
if os.environ.get("FAKE_NO_ASUSD") != "1":
    own(system, "xyz.ljones.Asusd")
print("ready", flush=True)

buf = b""


def stdin_cb(fd, cond):
    global buf
    d = os.read(fd, 65536)
    if not d:
        loop.quit()
        return False
    buf += d
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        msg = json.loads(line)
        if "set" in msg:
            path, iface, prop, sig, val = msg["set"]
            if sig.startswith("("):
                val = tuple(val)
            values[(path, iface)][prop] = GLib.Variant(sig, val)
            changed(system, path, iface, prop)
        elif "asusd" in msg:
            (own if msg["asusd"] else release)(system, "xyz.ljones.Asusd")
        print("done", flush=True)
    return True


loop = GLib.MainLoop()
GLib.io_add_watch(sys.stdin.fileno(), GLib.PRIORITY_DEFAULT, GLib.IOCondition.IN | GLib.IOCondition.HUP, stdin_cb)
loop.run()
