#!/bin/bash
# omarchy-asus-g16-apply against the patched omarchy/omarchy-settings (#45), offline: the
# command runs with OMARCHY_ASUS_G16_ROOT, HOME, OMARCHY_ASUS_G16_APPLY_SHARE and
# OMARCHY_ASUS_G16_APPLY_LIB pointing at temp dirs, a hybrid GA605KM in the fake sysfs, and
# pacman, aplay, amixer, busctl, systemctl and sudo stubbed. The patched omarchy is stood in
# for by its migrations (/usr/share/omarchy/migrations/<id>.sh) and its hybrid-cursor.lua.
#   a. stock Omarchy: hdmi-cursor is missing
#   b. patched, migration 1792123636 run: hdmi-cursor and hybrid-video are present, a
#      "Patched omarchy installed" note, the rtkit row names migration 1789747667
#   c. patched, with this command's hdmi-cursor lines already in hyprland.lua: present and
#      the lines are called redundant
#   d. patched, --check --dry-run: nothing would be appended to hyprland.lua
#   e. this command's asusd drop-in next to omarchy-settings' one: present, redundant
#   f. patched, migration 1792123636 not run yet ('omarchy update' pending): hybrid-video is
#      missing and names 'omarchy update'; --dry-run pins mpv, adds nothing to hyprland.lua
#   g. patched, migration run, this command's older mpv and Chromium pins on an old node:
#      needs repair, handed over to the patched omarchy; --dry-run repins and hands over,
#      files unchanged
#   h. patched, migration run, pins already in Omarchy's marked form (even stale): present,
#      and --dry-run neither repins nor hands over (one owner: Omarchy)
# Usage: tests/ci/g16-apply-patched-omarchy.sh [keep]   (keep: leave the temp dir for inspection)
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

# Stubs. pacman -Q knows only the packages in $PACMAN_HAVE (none by default).
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
if [[ ${1:-} == -Q && -n ${2:-} && " ${PACMAN_HAVE:-} " == *" $2 "* ]]; then
    echo "$2 1.0-1"
    exit 0
fi
exit 1
STUB
for stub in aplay amixer busctl systemctl sudo; do
    printf '#!/bin/bash\nexit 0\n' >"$S/bin/$stub"
done
chmod +x "$S/lib/bin/"* "$S/bin/"*
export PATH=$S/bin:$PATH

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }
# row_is FIX STATUS: the --check row of FIX shows STATUS (and not "STATUS (local)").
row_is() { grep -qE "^  $1 +$2  " "$OUT"; }
# row_has FIX TEXT: the --check row of FIX contains TEXT.
row_has() { grep -E "^  $1 " "$OUT" | grep -qF -- "$2"; }

# Per case: C (case dir), ROOT (its test prefix), H (its HOME) and OUT (the command's output).
setup_case() {
    C=$S/$1 ROOT=$S/$1/root H=$S/$1/home OUT=$S/$1/out
    mkdir -p "$ROOT/sys/class/dmi/id" "$ROOT/sys/class/drm/card0/device" \
        "$ROOT/sys/class/drm/card1/device" "$H/.config/hypr"
    printf '%s\n' 'ASUSTeK COMPUTER INC.' >"$ROOT/sys/class/dmi/id/sys_vendor"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_family"
    printf '%s\n' 'ROG Zephyrus G16 GA605KM' >"$ROOT/sys/class/dmi/id/product_name"
    printf '0x1002\n' >"$ROOT/sys/class/drm/card0/device/vendor"
    printf '0x10de\n' >"$ROOT/sys/class/drm/card1/device/vendor"
    printf -- '-- hyprland.lua\n' >"$H/.config/hypr/hyprland.lua"
}

# The patched omarchy's files the command looks for.
patched() {
    mkdir -p "$ROOT/usr/share/omarchy/default/hypr" "$ROOT/usr/share/omarchy/migrations"
    printf -- '-- hybrid cursor\n' >"$ROOT/usr/share/omarchy/default/hypr/hybrid-cursor.lua"
    local id
    for id in 1792123636 1789747667 1792162887; do
        printf 'echo migration %s\n' "$id" >"$ROOT/usr/share/omarchy/migrations/$id.sh"
    done
}

# migration_ran ID: omarchy-migrate's per-user marker for a migration it ran.
migration_ran() {
    mkdir -p "$H/.local/state/omarchy/migrations"
    touch "$H/.local/state/omarchy/migrations/$1.sh"
}

# The comments and markers, verbatim from the command.
MPV_COMMENT='# Decode video on the integrated GPU that drives the display, so the NVIDIA GPU can stay asleep.'
OUR_MARKER='# omarchy-asus-g16-apply hybrid-video: decode on the iGPU (kept up to date by the command; delete this line and the next to undo)'
OMARCHY_MARKER='# Omarchy repins the next line if the iGPU moves. Delete this comment to keep the line as your own.'
OLD_NODE=/dev/dri/by-path/pci-0000:66:00.0-render
NODE=/dev/dri/by-path/pci-0000:65:00.0-render

# run ARGS...: the command, with its output in $OUT.
run() {
    (
        export HOME=$H OMARCHY_ASUS_G16_ROOT=$ROOT
        bash "$TOOL" "$@"
    ) >"$OUT" 2>&1
    return 0
}

echo "== a. stock Omarchy"
setup_case a
run --check
check "hdmi-cursor is missing" row_is hdmi-cursor missing
check "no patched omarchy note" not grep -qF 'Patched omarchy installed' "$OUT"

echo "== b. patched omarchy"
setup_case b
patched
migration_ran 1792123636
run --check
check "hdmi-cursor is present" row_is hdmi-cursor present
check "hybrid-video is present" row_is hybrid-video present
check "patched omarchy note" grep -qF 'Patched omarchy installed' "$OUT"
check "rtkit names migration 1789747667" row_has rtkit 1789747667
check "nothing called redundant" not grep -qF 'redundant' "$OUT"

echo "== c. patched, with this command's hdmi-cursor lines"
setup_case c
patched
printf '\n%s\n%s\n' \
    '-- omarchy-asus-g16-apply hdmi-cursor: software cursor while a monitor on the RTX is connected (delete this line and the next to undo)' \
    'do local f = "/usr/share/omarchy-asus-g16-apply/hypr/hybrid-cursor.lua"; local h = io.open(f, "r"); if h then h:close(); dofile(f) end end' \
    >>"$H/.config/hypr/hyprland.lua"
run --check
check "hdmi-cursor is present" row_is hdmi-cursor present
check "hdmi-cursor lines are redundant" row_has hdmi-cursor redundant

echo "== d. patched, --check --dry-run"
setup_case d
patched
cp "$H/.config/hypr/hyprland.lua" "$C/hyprland.lua.before"
run --check --dry-run
check "no [dry-run] append to hyprland.lua" not grep -qF '[dry-run] append to' "$OUT"
check "hyprland.lua unchanged" cmp -s "$H/.config/hypr/hyprland.lua" "$C/hyprland.lua.before"
check "the run reached the apply step" grep -qF 'Would apply' "$OUT"

echo "== e. this command's asusd drop-in next to omarchy-settings' one"
setup_case e
mkdir -p "$ROOT/usr/lib/systemd/system" "$ROOT/etc/systemd/system/asusd.service.d"
printf '[Service]\n' >"$ROOT/usr/lib/systemd/system/asusd.service"
cp "$S/share/system/asusd-power-profiles.conf" \
    "$ROOT/etc/systemd/system/asusd.service.d/20-omarchy-asus-power-profiles.conf"
cp "$S/share/system/asusd-power-profiles.conf" \
    "$ROOT/etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf"
run --check
check "asusd-power-profiles is present" row_is asusd-power-profiles present
check "this command's drop-in is redundant" row_has asusd-power-profiles redundant

echo "== f. patched, migration 1792123636 not run yet"
setup_case f
patched
mkdir -p "$H/.config/mpv"
: >"$H/.config/mpv/mpv.conf"
printf -- '--ozone-platform=wayland\n' >"$H/.config/chromium-flags.conf"
run --check
check "hybrid-video is missing" row_is hybrid-video missing
check "hybrid-video names the next omarchy update" row_has hybrid-video "omarchy update"
run --dry-run hybrid-video
check "the run reached the apply step" grep -qF 'Would apply: hybrid-video' "$OUT"
check "mpv would be pinned" grep -qF '[dry-run] prepend to ~/.config/mpv/mpv.conf' "$OUT"
check "Chromium would be pinned under Omarchy's marker" \
    grep -qF "[dry-run] append to ~/.config/chromium-flags.conf, under Omarchy's marker comment" "$OUT"
check "nothing would be appended to hyprland.lua" not grep -qE '\[dry-run\] append to .*hyprland\.lua' "$OUT"

echo "== g. patched, migration run, this command's older pins on an old node"
setup_case g
patched
migration_ran 1792123636
mkdir -p "$H/.config/mpv"
printf '%s\n%s\n%s\n' "$MPV_COMMENT" 'hwdec=vaapi' "vaapi-device=$OLD_NODE" >"$H/.config/mpv/mpv.conf"
printf '%s\n%s\n' "$OUR_MARKER" "--render-node-override=$OLD_NODE" >"$H/.config/chromium-flags.conf"
cp "$H/.config/mpv/mpv.conf" "$C/mpv.conf.before"
cp "$H/.config/chromium-flags.conf" "$C/chromium-flags.conf.before"
run --check
check "hybrid-video needs repair" row_is hybrid-video 'needs repair'
check "hybrid-video hands the pins over to the patched omarchy" row_has hybrid-video 'patched omarchy'
run --dry-run hybrid-video
check "the mpv pin would be repinned" grep -qF "[dry-run] repin to $NODE in ~/.config/mpv/mpv.conf (line 3)" "$OUT"
check "the Chromium pin would be repinned" grep -qF "[dry-run] repin to $NODE in ~/.config/chromium-flags.conf (line 2)" "$OUT"
check "the mpv pin would be handed over" \
    grep -qF '[dry-run] hand over the pin in ~/.config/mpv/mpv.conf (line 3) to the patched omarchy' "$OUT"
check "the Chromium pin would be handed over" \
    grep -qF '[dry-run] hand over the pin in ~/.config/chromium-flags.conf (line 2) to the patched omarchy' "$OUT"
check "nothing would be appended to hyprland.lua" not grep -qE '\[dry-run\] append to .*hyprland\.lua' "$OUT"
check "mpv.conf unchanged" cmp -s "$H/.config/mpv/mpv.conf" "$C/mpv.conf.before"
check "chromium-flags.conf unchanged" cmp -s "$H/.config/chromium-flags.conf" "$C/chromium-flags.conf.before"

echo "== h. patched, migration run, pins already in Omarchy's form"
setup_case h
patched
migration_ran 1792123636
mkdir -p "$H/.config/mpv"
printf '%s\n%s\n%s\n%s\n' "$MPV_COMMENT" 'hwdec=vaapi' "$OMARCHY_MARKER" "vaapi-device=$OLD_NODE" >"$H/.config/mpv/mpv.conf"
printf '%s\n%s\n' "$OMARCHY_MARKER" "--render-node-override=$OLD_NODE" >"$H/.config/chromium-flags.conf"
run --check
check "hybrid-video is present" row_is hybrid-video present
run --dry-run hybrid-video
check "no pin would be repinned" not grep -qF 'repin' "$OUT"
check "no pin would be handed over" not grep -qF 'hand over' "$OUT"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
