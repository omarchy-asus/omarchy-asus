#!/bin/bash
# omarchy-asus-g16's touchpad palm detection (#390), offline. Against the ASUF1209 touchpad's
# report descriptor as the G16 reports it (tests/channel/fixtures/asuf1209-touchpad-rdesc.hex):
#   1. the HID-BPF program's descriptor checks (size, Report ID 4, the five finger End
#      Collections, the five 16-bit vendor fields) all hold on the fixture;
#   2. its rewrite, replayed here, gives a descriptor whose report 4 keeps its 49-byte payload,
#      has no vendor 0x02-0x06 fields left, and in which every finger collection ends with an
#      8-bit Tip Pressure and 4-bit Width and Height (Digitizers 0x30, 0x48, 0x49, Data);
#   3. its report repack, with the offsets read from the C source, puts every field of a report
#      where the rewritten descriptor says it is: each finger's Tip Pressure is that slot's
#      strength byte (bits 0-7 of vendor usage 0x02 + slot), its Width bits 8-11, its Height
#      bits 12-15, and every other field keeps its value;
#   4. package() installs the object where udev-hid-bpf looks, the hwdb names that object for
#      I2C 2808:0219 only, and the libinput quirk matches the same device, turns pressure-based
#      touch detection off and sets a palm pressure threshold.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/omarchy-asus-g16
C=$R/0010-FocalTech__ASUF1209.bpf.c
F=$W/tests/channel/fixtures/asuf1209-touchpad-rdesc.hex
[[ -f $C && -f $F ]] || { echo "FAIL: missing $C or $F"; exit 1; }
fails=0

python3 -I - "$C" "$F" <<'EOF' || fails=$((fails + 1))
import random
import re
import sys

src = open(sys.argv[1]).read()
orig = bytes.fromhex(open(sys.argv[2]).read())
fails = 0


def ok(m):
    print("ok:", m)


def bad(m):
    global fails
    print("FAIL:", m)
    fails += 1


def define(name):
    m = re.search(r"#define " + name + r"\s+(\d+)", src)
    return int(m.group(1))


def macro(name):
    m = re.search(r"#define " + name + r"\(n\)\s+\((\d+) \+ \(n\) \* (\d+)\)", src)
    base, step = int(m.group(1)), int(m.group(2))
    return lambda n: base + n * step


RDESC_SIZE, REPORT_ID, SLOTS = define("RDESC_SIZE"), define("REPORT_ID"), define("SLOTS")
SLOT_IN, SLOT_OUT, REPACKED = define("SLOT_IN"), define("SLOT_OUT"), define("REPACKED")
ID_OFFSET = define("REPORT4_ID_OFFSET")
FINGER_END, VENDOR_FIELD = macro("FINGER_END"), macro("VENDOR_FIELD")
VENDOR_LEN = define("VENDOR_LEN")
body = re.search(r"#define CONTACT_FIELDS \\\n(.*?)\n\n", src, re.S).group(1)
body = re.sub(r"/\*.*?\*/", "", body)
FIELDS = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", body))
CUT_FROM, CUT_TO = VENDOR_FIELD(0), VENDOR_FIELD(SLOTS)

# 1. the program's checks (is_asuf1209_rdesc) on the fixture
checks = len(orig) == RDESC_SIZE and orig[ID_OFFSET:ID_OFFSET + 2] == bytes([0x85, REPORT_ID])
for n in range(SLOTS):
    e, v = FINGER_END(n), VENDOR_FIELD(n)
    checks &= orig[e - 2:e + 1] == bytes([0x81, 0x02, 0xc0])
    checks &= orig[v:v + VENDOR_LEN] == bytes([0x09, 0x02 + n, 0x75, 0x10, 0x95, 0x01, 0x81, 0x03])
checks &= orig[CUT_TO:CUT_TO + 4] == bytes([0x09, 0x20, 0x75, 0x20])
ok("the fixture passes the program's descriptor checks") if checks else bad("the fixture fails the program's descriptor checks")

# 2. the rewrite, as asuf1209_fix_rdesc does it
want_size = RDESC_SIZE - (CUT_TO - CUT_FROM) + SLOTS * len(FIELDS)
fixed = bytearray(orig) + bytearray(max(0, want_size - RDESC_SIZE))
for i in range(RDESC_SIZE - 1, -1, -1):
    if CUT_FROM <= i < CUT_TO:
        continue
    shift = (-(CUT_TO - CUT_FROM) if i >= CUT_TO else 0) + sum(len(FIELDS) for n in range(SLOTS) if i >= FINGER_END(n))
    fixed[i + shift] = fixed[i]
for n in range(SLOTS):
    at = FINGER_END(n) + n * len(FIELDS)
    fixed[at:at + len(FIELDS)] = FIELDS
fixed = bytes(fixed[:want_size])


def parse(rd):
    """Input fields of report REPORT_ID: (page, usage, bit offset, bits, data?, finger index)."""
    fields, g, local, stack, finger, nfinger, bits = [], {}, [], [], None, 0, 0
    i = 0
    while i < len(rd):
        b = rd[i]
        size = (0, 1, 2, 4)[b & 3]
        data = rd[i + 1:i + 1 + size]
        val = int.from_bytes(data, "little") if size else 0
        tag, typ = b >> 4, (b >> 2) & 3
        i += 1 + size
        if typ == 1:                                     # global
            g[tag] = val
        elif typ == 2 and tag == 0:                      # usage
            local.append(val if size == 4 else (g.get(0, 0) << 16) | val)
        elif typ == 0:                                   # main
            if tag == 0xA:                               # collection
                usage = local[0] if local else 0
                stack.append(usage)
                if usage == 0x000D0022 and g.get(8) == REPORT_ID:
                    finger, nfinger = nfinger, nfinger + 1
            elif tag == 0xC:
                if stack and stack.pop() == 0x000D0022:
                    finger = None
            elif tag == 0x8 and g.get(8) == REPORT_ID:   # input
                rs, rc = g.get(7, 0), g.get(9, 0)
                for k in range(rc):
                    u = local[min(k, len(local) - 1)] if local else 0
                    fields.append((u >> 16, u & 0xFFFF, bits, rs, not (val & 1), finger))
                    bits += rs
            local = []
    return fields, bits


old, old_bits = parse(orig)
new, new_bits = parse(fixed)
ok("rewritten descriptor is %d bytes" % len(fixed)) if len(fixed) == want_size else bad("size %d" % len(fixed))
ok("report 4 keeps its %d-byte payload" % (new_bits // 8)) if old_bits == new_bits == 49 * 8 else bad("report 4 bits: %d -> %d" % (old_bits, new_bits))
for usage, bits, name in ((0x30, 8, "Tip Pressure"), (0x48, 4, "Width"), (0x49, 4, "Height")):
    got = [f for f in new if f[:2] == (0x0D, usage)]
    if len(got) == SLOTS and all(f[3] == bits and f[4] and f[5] == n for n, f in enumerate(got)):
        ok("each finger collection has a %d-bit %s (data) field" % (bits, name))
    else:
        bad("%s fields: %s" % (name, got))
left = [f for f in new if f[0] == 0xFF01 and 0x02 <= f[1] <= 0x06]
ok("the vendor 0x02-0x06 fields are gone") if not left else bad("vendor fields left: %s" % left)

# 3. the repack, with the C source's offsets
m = re.search(r"data\[1 \+ s \* SLOT_OUT \+ SLOT_IN\] = in\[(\d+) \+ 2 \* s\]", src)
strength_at = int(m.group(1))
m = re.search(r"data\[1 \+ s \* SLOT_OUT \+ SLOT_IN \+ 1\] = in\[(\d+) \+ 2 \* s\]", src)
size_at = int(m.group(1))
m = re.search(r"__builtin_memcpy\(data \+ (\d+), in \+ (\d+), (\d+)\);", src)
mid_to, mid_from, mid_len = map(int, m.groups())


def repack(rep):
    inp, out = bytes(rep[:REPACKED]), bytearray(rep)
    for s in range(SLOTS):
        out[1 + s * SLOT_OUT:1 + s * SLOT_OUT + SLOT_IN] = inp[1 + s * SLOT_IN:1 + (s + 1) * SLOT_IN]
        out[1 + s * SLOT_OUT + SLOT_IN] = inp[strength_at + 2 * s]
        out[1 + s * SLOT_OUT + SLOT_IN + 1] = inp[size_at + 2 * s]
    out[mid_to:mid_to + mid_len] = inp[mid_from:mid_from + mid_len]
    return bytes(out)


def get(rep, f):
    v = int.from_bytes(rep[1:], "little")
    return (v >> f[2]) & ((1 << f[3]) - 1)


def source(f):
    """The field of the original layout that new field f must carry, and how."""
    page, usage, _, size, _, finger = f
    split = {0x30: lambda v: v & 0xFF, 0x48: lambda v: (v >> 8) & 0xF, 0x49: lambda v: v >> 12}
    if page == 0x0D and usage in split:
        return [o for o in old if o[:2] == (0xFF01, 0x02 + finger)][0], split[usage]
    same = [o for o in old if o[:2] == (page, usage) and o[5] == finger and o[3] == size]
    nth = [n for n in new if n[:2] == (page, usage) and n[5] == finger and n[3] == size].index(f)
    return same[nth], lambda v: v


rng = random.Random(390)
wrong = set()
for _ in range(200):
    rep = bytes([REPORT_ID]) + bytes(rng.randrange(256) for _ in range(49))
    out = repack(rep)
    for f in new:
        o, conv = source(f)
        if get(out, f) != conv(get(rep, o)):
            wrong.add(f)
ok("every field of a repacked report is where the new descriptor says, with its value") if not wrong else bad("fields moved wrongly: %s" % sorted(wrong))
sys.exit(1 if fails else 0)
EOF

# 4. package() into a scratch pkgdir, with an empty object for build()'s product
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
mkdir -p "$T/src" "$T/pkg"
cp -r "$R"/. "$T/src/"
: >"$T/src/0010-FocalTech__ASUF1209.bpf.o"
(
  cd "$T/src" || exit 1
  # shellcheck disable=SC1091
  source ./PKGBUILD
  # shellcheck disable=SC2034 # read by package()
  srcdir=$T/src pkgdir=$T/pkg
  package
) || bad "package() failed"
OBJ=$T/pkg/usr/lib/firmware/hid/bpf/0010-FocalTech__ASUF1209.bpf.o
HWDB=$T/pkg/usr/lib/udev/hwdb.d/81-hid-bpf-omarchy-asus-g16.hwdb
QUIRK=$T/pkg/usr/share/libinput/50-omarchy-asus-g16-touchpad.quirks
for f in "$OBJ" "$HWDB" "$QUIRK"; do
  [[ $(stat -c %a "$f" 2>/dev/null) == 644 ]] && ok "installed 0644: ${f#"$T"/pkg}" || bad "not installed 0644: ${f#"$T"/pkg}"
done
hw=$(grep -v '^[[:space:]]*\(#\|$\)' "$HWDB" | paste -sd'|')
[[ $hw == 'hid-bpf:hid:b0018g*v00002808p00000219|  HID_BPF_OMARCHY_ASUS_G16=0010-FocalTech__ASUF1209.bpf.o|  .HID_BPF=1' ]] &&
  ok "hwdb: I2C 2808:0219 only, names the installed object" || bad "hwdb: $hw"
q=$(grep -v '^[[:space:]]*\(#\|$\)' "$QUIRK" | grep -v '^\[' | paste -sd'|')
[[ $q =~ ^MatchBus=i2c\|MatchVendor=0x2808\|MatchProduct=0x0219\|MatchUdevType=touchpad\|AttrPressureRange=none\|AttrPalmPressureThreshold=[0-9]+$ ]] &&
  ok "quirk: the same touchpad, no pressure touch detection, a palm pressure threshold" || bad "quirk: $q"

((fails == 0)) && echo "all g16-touchpad-palm checks passed" || { echo "$fails check(s) failed"; exit 1; }
