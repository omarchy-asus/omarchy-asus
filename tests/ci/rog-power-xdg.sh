#!/bin/bash
# The rog-power unit lookup follows XDG_CONFIG_HOME (#116), offline, in both scripts that do
# it: bin/omarchy-asus-setup's own_power_manager (sourced with OMARCHY_ASUS_SETUP_SOURCE_ONLY=1,
# HOME a temp dir) and omarchy-asus-g16-apply's power_owner, through the asusd-power-profiles
# row of --check (run with OMARCHY_ASUS_G16_ROOT, HOME, OMARCHY_ASUS_G16_APPLY_SHARE and
# OMARCHY_ASUS_G16_APPLY_LIB pointing at temp dirs, a GA605KM in the fake DMI, and pacman,
# aplay, amixer, busctl, systemctl and sudo stubbed). systemd reads user units from
# ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user.
#   1. setup, XDG_CONFIG_HOME unset, the unit in ~/.config/systemd/user: found there
#   2. setup, XDG_CONFIG_HOME outside HOME, the unit in its systemd/user: found there
#   3. setup, XDG_CONFIG_HOME set (no unit there), the unit only in ~/.config/systemd/user:
#      not found (skipped when the host has /etc/systemd/{user,system}/rog-power.service)
#   4. g16-apply --check, XDG_CONFIG_HOME outside HOME with the unit in its systemd/user:
#      asusd-power-profiles is present (local), owned by rog-power
#   5. g16-apply --check, XDG_CONFIG_HOME unset, the unit in ~/.config/systemd/user: the same
# The cases run with XDG_CONFIG_HOME unset, whatever the host exports, unless they set it.
# Usage: tests/ci/rog-power-xdg.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0

if ((EUID == 0)); then
    echo "ok # skip running as root (omarchy-asus-g16-apply refuses root)"
    exit 0
fi

# The user unit dir follows XDG_CONFIG_HOME: only the cases that set X export it.
unset XDG_CONFIG_HOME

RECIPE=$W/recipes/omarchy-asus-g16-apply
TOOL=$RECIPE/omarchy-asus-g16-apply

# The package's share and lib dirs, laid out as package() installs them.
export OMARCHY_ASUS_G16_APPLY_SHARE=$S/share OMARCHY_ASUS_G16_APPLY_LIB=$S/lib
mkdir -p "$S/share/fork" "$S/share/hypr" "$S/share/system" "$S/lib/bin" "$S/bin"
cp "$RECIPE/hybrid-video-decode.sh" "$S/share/fork/hybrid-video-decode.sh"
cp "$RECIPE/hybrid-video-env.lua" "$RECIPE/hybrid-cursor.lua" "$S/share/hypr/"
cp "$RECIPE/asusd-10-omarchy-power-profiles.conf" "$S/share/system/asusd-power-profiles.conf"
cat >"$S/lib/bin/omarchy-hw-igpu-render-node" <<'STUB'
#!/bin/bash
echo /dev/dri/by-path/pci-0000:65:00.0-render
STUB
cat >"$S/lib/bin/omarchy-hw-nvidia-only-display" <<'STUB'
#!/bin/bash
exit 1
STUB

# Stubs. pacman -Q knows no package.
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
exit 1
STUB
for stub in aplay amixer busctl systemctl sudo; do
    printf '#!/bin/bash\nexit 0\n' >"$S/bin/$stub"
done
chmod +x "$S/lib/bin/"* "$S/bin/"*
export PATH=$S/bin:$PATH

# Never run the installer itself: without the guard, load only the functions.
LIB=$W/bin/omarchy-asus-setup
if ! grep -q 'OMARCHY_ASUS_SETUP_SOURCE_ONLY' "$LIB"; then
    echo "not ok - bin/omarchy-asus-setup has no OMARCHY_ASUS_SETUP_SOURCE_ONLY guard; loading only its functions"
    fail=1
    sed '/^((DRY_RUN)) && printf/,$d' "$LIB" >"$S/lib.sh"
    LIB=$S/lib.sh
fi

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }
# row_is FIX STATUS: the --check row of FIX shows STATUS (an ERE).
row_is() { grep -qE "^  $1 +$2  " "$OUT"; }
# row_has FIX TEXT: the --check row of FIX contains TEXT.
row_has() { grep -E "^  $1 " "$OUT" | grep -qF -- "$2"; }

# Per case: ROOT (its test prefix), H (its HOME), X (its XDG_CONFIG_HOME, empty for unset)
# and OUT (the output).
setup_case() {
    ROOT=$S/$1/root H=$S/$1/home X='' OUT=$S/$1/out
    mkdir -p "$ROOT/sys/class/dmi/id" "$H/.config/hypr"
    printf '%s\n' 'ASUSTeK COMPUTER INC.' >"$ROOT/sys/class/dmi/id/sys_vendor"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_family"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_name"
    printf -- '-- hyprland.lua\n' >"$H/.config/hypr/hyprland.lua"
}

# unit DIR: a rog-power.service in DIR.
unit() {
    mkdir -p "$1"
    printf '[Unit]\nDescription=rog-power\n' >"$1/rog-power.service"
}

# setup_owner: own_power_manager's output in $OUT; returns its exit code.
setup_owner() {
    local st=0
    (
        set --
        export HOME=$H
        if [[ -n $X ]]; then export XDG_CONFIG_HOME=$X; fi
        # shellcheck source=/dev/null
        OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB" >/dev/null 2>&1
        own_power_manager
    ) >"$OUT" 2>/dev/null || st=$?
    return "$st"
}

# apply ARGS...: the g16-apply command, with its output in $OUT.
apply() {
    (
        export HOME=$H OMARCHY_ASUS_G16_ROOT=$ROOT
        if [[ -n $X ]]; then export XDG_CONFIG_HOME=$X; fi
        bash "$TOOL" "$@"
    ) >"$OUT" 2>&1
    return 0
}

echo "== 1. setup, XDG_CONFIG_HOME unset"
setup_case c1
unit "$H/.config/systemd/user"
check "own_power_manager finds the unit" setup_owner
check "it prints ~/.config/systemd/user/rog-power.service" \
    grep -qx "$H/.config/systemd/user/rog-power.service" "$OUT"

echo "== 2. setup, XDG_CONFIG_HOME outside HOME"
setup_case c2
X=$S/xdg
unit "$X/systemd/user"
check "own_power_manager finds the unit" setup_owner
check "it prints \$XDG_CONFIG_HOME/systemd/user/rog-power.service" \
    grep -qx "$S/xdg/systemd/user/rog-power.service" "$OUT"

echo "== 3. setup, XDG_CONFIG_HOME set, the unit only in ~/.config/systemd/user"
if [[ -e /etc/systemd/user/rog-power.service || -e /etc/systemd/system/rog-power.service ]]; then
    echo "ok # skip this host has a rog-power.service under /etc/systemd"
else
    setup_case c3
    X=$S/xdg2
    mkdir -p "$X"
    unit "$H/.config/systemd/user"
    check "own_power_manager finds nothing" not setup_owner
    check "it prints nothing" not [ -s "$OUT" ]
fi

echo "== 4. g16-apply --check, XDG_CONFIG_HOME outside HOME"
setup_case c4
mkdir -p "$ROOT/usr/lib/systemd/system"
: >"$ROOT/usr/lib/systemd/system/asusd.service"
X=$S/xdg3
unit "$X/systemd/user"
apply --check
check "asusd-power-profiles is present (local)" row_is asusd-power-profiles 'present \(local\)'
check "asusd-power-profiles is owned by rog-power" row_has asusd-power-profiles 'rog-power'

echo "== 5. g16-apply --check, XDG_CONFIG_HOME unset"
setup_case c5
mkdir -p "$ROOT/usr/lib/systemd/system"
: >"$ROOT/usr/lib/systemd/system/asusd.service"
unit "$H/.config/systemd/user"
apply --check
check "asusd-power-profiles is present (local)" row_is asusd-power-profiles 'present \(local\)'
check "asusd-power-profiles is owned by rog-power" row_has asusd-power-profiles 'rog-power'

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
