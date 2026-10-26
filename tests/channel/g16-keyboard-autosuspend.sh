#!/bin/bash
# omarchy-asus-g16's keyboard autosuspend rule (#249), offline:
#   1. package() installs the rule under udev's vendor rules.d, mode 0644;
#   2. its one rule matches only the USB device (not its interfaces) 0b05:19b6 on add,
#      and sets autosuspend_delay_ms=2000 before power/control=auto;
#   3. udevadm verify accepts it, when udevadm is there.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/omarchy-asus-g16
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# 1. package() into a scratch pkgdir
mkdir -p "$T/src" "$T/pkg"
cp -r "$R"/. "$T/src/"
(
  cd "$T/src" || exit 1
  # shellcheck disable=SC1091
  source ./PKGBUILD
  # shellcheck disable=SC2034 # read by package()
  srcdir=$T/src pkgdir=$T/pkg
  package
) || bad "package() failed"
RULE=$T/pkg/usr/lib/udev/rules.d/99-omarchy-asus-g16-keyboard-autosuspend.rules
[[ -f $RULE ]] && ok "rule installed" || bad "missing: $(cd "$T/pkg" && find . -type f)"
[[ $(stat -c %a "$RULE" 2>/dev/null) == 644 ]] && ok "rule is 0644" || bad "rule not 0644"

# 2. the rule
lines=$(grep -v '^[[:space:]]*\(#\|$\)' "$RULE")
want='ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0b05", ATTR{idProduct}=="19b6", ATTR{power/autosuspend_delay_ms}="2000", ATTR{power/control}="auto"'
[[ $lines == "$want" ]] && ok "one rule: add, usb_device 0b05:19b6, delay 2000 then control auto" || bad "rule: $lines"

# 3. udev's own check
if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
  if udevadm verify "$RULE" >/dev/null 2>&1; then
    ok "udevadm verify accepts it"
  else
    bad "udevadm verify: $(udevadm verify "$RULE" 2>&1)"
  fi
else
  echo "skip: no udevadm verify"
fi

((fails == 0)) && echo "all g16-keyboard-autosuspend checks passed" || { echo "$fails check(s) failed"; exit 1; }
