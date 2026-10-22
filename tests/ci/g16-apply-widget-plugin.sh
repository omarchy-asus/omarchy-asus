#!/bin/bash
# omarchy-asus-g16-apply's g16-widget fix with the widget as an Omarchy plugin (#183),
# offline: HOME, OMARCHY_ASUS_G16_ROOT and the share/lib dirs are temp dirs, a GA605KM in
# the fake sysfs, and omarchy-plugin-add is a stub that records its arguments and clones a
# fake .git.
#   a. the old packaged widget is linked (/usr/share/...): missing, "it is a plugin now";
#      --dry-run would remove the link and run omarchy-plugin-add, and changes nothing
#   b. applying it: the link is removed, omarchy-plugin-add runs with the repo URL,
#      --enable --yes; --check then reports applied
#   c. the plugin already cloned: applied
#   d. a hand-made G16 widget (g16ctl) under another id: local, left alone
#   e. something else at ~/.config/omarchy/plugins/omarchy-asus.g16: local, left alone,
#      and applying it doesn't touch it
# Usage: tests/ci/g16-apply-widget-plugin.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0

if ((EUID == 0)); then
    echo "ok # skip running as root (omarchy-asus-g16-apply refuses root)"
    exit 0
fi

RECIPE=$W/recipes/omarchy-asus-g16-apply
TOOL=$RECIPE/omarchy-asus-g16-apply
URL=https://github.com/omarchy-asus/g16-control
# The package's share and lib dirs, laid out as package() installs them.
export OMARCHY_ASUS_G16_APPLY_SHARE=$S/share OMARCHY_ASUS_G16_APPLY_LIB=$S/lib
mkdir -p "$S/share/fork" "$S/share/hypr" "$S/share/system" "$S/lib/bin" "$S/bin"
cp "$RECIPE/hybrid-video-decode.sh" "$S/share/fork/hybrid-video-decode.sh"
cp "$RECIPE/hybrid-video-env.lua" "$RECIPE/hybrid-cursor.lua" "$S/share/hypr/"
cp "$RECIPE/asusd-10-omarchy-power-profiles.conf" "$S/share/system/asusd-power-profiles.conf"
printf '#!/bin/bash\nexit 1\n' >"$S/lib/bin/omarchy-hw-igpu-render-node"
printf '#!/bin/bash\nexit 1\n' >"$S/lib/bin/omarchy-hw-nvidia-only-display"
chmod +x "$S/lib/bin/"*
for stub in pacman aplay amixer busctl systemctl; do
    printf '#!/bin/bash\nexit 1\n' >"$S/bin/$stub"
done
printf '#!/bin/bash\nexit 0\n' >"$S/bin/sudo"
# omarchy-plugin-add URL --enable --yes: record the call and clone a fake plugin.
cat >"$S/bin/omarchy-plugin-add" <<'STUB'
#!/bin/bash
echo "omarchy-plugin-add $*" >>"$PLUGIN_LOG"
mkdir -p "$HOME/.config/omarchy/plugins/omarchy-asus.g16/.git"
STUB
chmod +x "$S/bin/"*
export PATH=$S/bin:$PATH

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }
# row_is FIX STATUS / row_has FIX TEXT: the --check row of FIX.
row_is() { grep -qE "^  $1 +$2  " "$OUT"; }
row_has() { grep -E "^  $1 " "$OUT" | grep -qF -- "$2"; }

# Per case: C (case dir), ROOT (its test prefix), H (its HOME), OUT (the output).
setup_case() {
    C=$S/$1 ROOT=$S/$1/root H=$S/$1/home OUT=$S/$1/out
    mkdir -p "$ROOT/sys/class/dmi/id" "$H/.config/omarchy/plugins" "$H/.config/hypr"
    printf '%s\n' 'ASUSTeK COMPUTER INC.' >"$ROOT/sys/class/dmi/id/sys_vendor"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_family"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_name"
    printf -- '-- hyprland.lua\n' >"$H/.config/hypr/hyprland.lua"
    export PLUGIN_LOG=$C/plugin-add.log
    : >"$PLUGIN_LOG"
}

# run ARGS...: the command, with its output in $OUT.
run() {
    (
        export HOME=$H OMARCHY_ASUS_G16_ROOT=$ROOT
        unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
        bash "$TOOL" "$@"
    ) >"$OUT" 2>&1
    return 0
}
# apply FIX: applying refuses a test prefix, so this runs with no OMARCHY_ASUS_G16_ROOT,
# the case's HOME, the stubs on PATH and --force (this host isn't a GA605KM). Only the
# named fix runs; it touches nothing outside HOME.
apply() {
    (
        export HOME=$H
        unset OMARCHY_ASUS_G16_ROOT XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
        bash "$TOOL" "$1" --yes --force
    ) >"$OUT" 2>&1
    return 0
}
P() { echo "$H/.config/omarchy/plugins/$1"; }

echo "== a. the old packaged widget is linked"
setup_case a
ln -s /usr/share/omarchy/plugins/omarchy-asus.g16 "$(P omarchy-asus.g16)"
run --check
check "missing" row_is g16-widget 'missing \(opt-in\)'
check "says it is a plugin now" row_has g16-widget "plugin now"
run --dry-run g16-widget
check "dry run removes the link" grep -qF "rm $(P omarchy-asus.g16)" "$OUT"
check "dry run adds the plugin" grep -qF "omarchy-plugin-add $URL --enable --yes" "$OUT"
check "dry run changes nothing" [ -L "$(P omarchy-asus.g16)" ]
check "dry run calls nothing" [ ! -s "$PLUGIN_LOG" ]

echo "== b. applying it"
apply g16-widget
check "the old link is gone" not [ -L "$(P omarchy-asus.g16)" ]
check "omarchy-plugin-add ran with the repo" grep -qxF "omarchy-plugin-add $URL --enable --yes" "$PLUGIN_LOG"
run --check
check "applied afterwards" row_is g16-widget applied

echo "== c. the plugin already cloned"
setup_case c
mkdir -p "$(P omarchy-asus.g16)/.git"
run --check
check "applied" row_is g16-widget applied

echo "== d. a hand-made G16 widget"
setup_case d
mkdir -p "$(P my.g16)"
touch "$(P my.g16)/g16ctl"
run --check
check "local" row_is g16-widget 'present \(local\)'
check "names it" row_has g16-widget "my.g16"

echo "== e. something else at the plugin's path"
setup_case e
mkdir -p "$(P omarchy-asus.g16)"
touch "$(P omarchy-asus.g16)/mine"
run --check
check "local" row_is g16-widget 'present \(local\)'
apply g16-widget
check "left alone" [ -f "$(P omarchy-asus.g16)/mine" ]
check "omarchy-plugin-add not run" [ ! -s "$PLUGIN_LOG" ]

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
