#!/bin/bash
# recipes/linux-omarchy 9909 (#249): hid-asus declares only the Caps Lock LED of the GA605KM's
# built-in keyboard. Offline, against the keyboard's report descriptor as the G16 reports it
# (tests/channel/fixtures/ga605km-nkey-keyboard-rdesc.hex, from sysfs, so hid-asus's existing
# 0x5a Report Count fixup is already in it; 9909 doesn't touch those bytes):
#   1. the patch's size and offset constants match the fixture, and its "before" bytes are
#      exactly the fixture's at that offset;
#   2. the "after" bytes have the same length, and with them, parsed the way the HID core
#      does, report 1's output declares only LED usage 0x02 (Caps Lock) at bit 1, and every
#      input, output and feature report keeps its size;
#   3. the quirk is set on the 0b05:19b6 entry only, and the fixup also needs the GA605KM
#      board name.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
P=$W/recipes/linux-omarchy/9909-EXPERIMENTAL-hid-asus-ga605km-keyboard-caps-lock-led-only.patch
F=$W/tests/channel/fixtures/ga605km-nkey-keyboard-rdesc.hex
[[ -f $P && -f $F ]] || { echo "FAIL: missing $P or $F"; exit 1; }
python3 -I - "$P" "$F" <<'EOF'
import re
import sys

patch = open(sys.argv[1]).read()
fixture = bytes.fromhex(open(sys.argv[2]).read())
fails = 0


def ok(m):
    print("ok:", m)


def bad(m):
    global fails
    print("FAIL:", m)
    fails += 1


added = "\n".join(l[1:] for l in patch.splitlines() if l.startswith("+") and not l.startswith("+++"))


def array(name):
    m = re.search(r"static const __u8 " + name + r"\[\] = \{(.*?)\};", added, re.S)
    if not m:
        return None
    body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", body))


def const(name):
    m = re.search(r"#define " + name + r"\s+(\d+)", added)
    return int(m.group(1)) if m else None


before = array("asus_ga605km_kbd_leds_rdesc")
after = array("asus_ga605km_kbd_leds_fixed_rdesc")
size = const("ASUS_GA605KM_KBD_RDESC_SIZE")
offs = const("ASUS_GA605KM_KBD_LEDS_OFFSET")
if None in (before, after, size, offs):
    bad("could not read the arrays and constants from the patch")
    sys.exit(1)

# 1.
(ok if len(fixture) == size else bad)(f"fixture is {len(fixture)} bytes, the patch matches {size}")
(ok if fixture[offs:offs + len(before)] == before else bad)(f"the patch's 'before' bytes are the fixture's at offset {offs}")
(ok if fixture.count(before) == 1 else bad)("those bytes occur once in the descriptor")


def parse(d):
    """Main items per (type, report id): list of (bit offset, bits, const, usages)."""
    g = {"page": 0, "size": 0, "count": 0, "id": 0}
    stack, usages, umin = [], [], None
    reports, sizes = {}, {}
    i = 0
    while i < len(d):
        b = d[i]
        n = (0, 1, 2, 4)[b & 3]
        v = int.from_bytes(d[i + 1:i + 1 + n], "little")
        tag = b & 0xFC
        i += 1 + n
        if tag == 0x04: g["page"] = v
        elif tag == 0x74: g["size"] = v
        elif tag == 0x94: g["count"] = v
        elif tag == 0x84: g["id"] = v
        elif tag == 0xA4: stack.append(dict(g))
        elif tag == 0xB4: g = stack.pop()
        elif tag == 0x08: usages.append(v if n == 4 else (g["page"] << 16) | v)
        elif tag == 0x18: umin = (g["page"] << 16) | v if n < 4 else v
        elif tag == 0x28:
            umax = (g["page"] << 16) | v if n < 4 else v
            usages.extend(range(umin, umax + 1))
        elif tag in (0x80, 0x90, 0xB0):
            key = (tag, g["id"])
            off = sizes.get(key, 0)
            bits = g["size"] * g["count"]
            sizes[key] = off + bits
            reports.setdefault(key, []).append((off, bits, bool(v & 1), tuple(usages)))
            usages = []
        elif tag in (0xA0, 0xC0):
            usages = []
    return reports, sizes


# 2.
(ok if len(after) == len(before) else bad)(f"'after' is {len(after)} bytes, 'before' {len(before)} (rewritten in place)")
fixed = fixture[:offs] + after + fixture[offs + len(before):]
r0, s0 = parse(fixture)
r1, s1 = parse(fixed)
(ok if s0 == s1 else bad)("every input, output and feature report keeps its size")
out0 = r0.get((0x90, 1), [])
out1 = r1.get((0x90, 1), [])
leds0 = [u & 0xFF for f in out0 for u in f[3] if u >> 16 == 0x08]
(ok if leds0 == [1, 2, 3, 4, 5] else bad)(f"before: report 1 declares LEDs {leds0} (Num, Caps, Scroll, Compose, Kana)")
data1 = [f for f in out1 if not f[2]]
(ok if data1 == [(1, 1, False, (0x80002,))] else bad)(f"after: report 1's only data output is Caps Lock at bit 1: {data1}")
(ok if [f for k, v in r0.items() if k != (0x90, 1) for f in v] == [f for k, v in r1.items() if k != (0x90, 1) for f in v]
 else bad)("every other report is unchanged")

# 3.
m = re.search(r"USB_DEVICE_ID_ASUSTEK_ROG_NKEY_KEYBOARD2\),\n(?:.*\n){0,3}?.*QUIRK_ROG_NKEY_CAPS_LED_ONLY \}", patch)
(ok if m and patch.count("QUIRK_ROG_NKEY_CAPS_LED_ONLY }") == 1 else bad)("the quirk is on the 0b05:19b6 entry only")
(ok if 'dmi_match(DMI_BOARD_NAME, "GA605KM")' in added else bad)("the fixup also needs DMI board name GA605KM")

print("all 9909 rdesc checks passed" if not fails else f"{fails} check(s) failed")
sys.exit(1 if fails else 0)
EOF
