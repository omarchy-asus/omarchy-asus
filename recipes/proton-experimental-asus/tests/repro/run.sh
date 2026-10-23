#!/bin/bash
# Reproduce #266 without a game: emulated exclusive fullscreen on display 1 while the
# compositor keeps the window on another output.
#   tests/repro/run.sh <output to focus> <Proton files dir> -- <fsrepro.exe args>
# e.g. tests/repro/run.sh HEADLESS-2 ~/.local/share/Steam/steamapps/common/"Proton - Experimental"/files -- 0 2560 1440 8 bc
# Starts a private headless sway (two outputs, sway.conf) on its own socket, with its own
# HOME and a throwaway Wine prefix, focuses an output, runs fsrepro.exe under that Proton's
# wine, then moves a virtual pointer (vptr) to three spots on the focused output and clicks.
# Needs sway, grim, python3, and fsrepro.exe + vptr built next to this script (README.md).
# Prints the run directory: repro.log (what Win32 saw), tree.log (where sway put the
# window), wine.log, shot.png. Nothing outside it is touched; delete it when done.
set -u
here=$(cd "$(dirname "$0")" && pwd)
focus=${1:?output to focus (HEADLESS-1 panel, HEADLESS-2 HDMI)} dist=${2:?Proton files dir}
shift 3
run=$(mktemp -d "${TMPDIR:-/tmp}/fsrepro.XXXX")
export HOME=$run/home XDG_RUNTIME_DIR=$run/run
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=2
unset WAYLAND_DISPLAY DISPLAY SWAYSOCK
sway -c "$here/sway.conf" >"$run/sway.log" 2>&1 &
sway_pid=$!
for _ in $(seq 50); do compgen -G "$XDG_RUNTIME_DIR/sway-ipc.*" >/dev/null && break; sleep 0.1; done
SWAYSOCK=$(compgen -G "$XDG_RUNTIME_DIR/sway-ipc.*" | head -1)
export SWAYSOCK WAYLAND_DISPLAY=wayland-1
sleep 1
# XWayland's DISPLAY is in sway's environment: have sway write it out
swaymsg -q exec "echo \$DISPLAY > $run/display"
for _ in $(seq 50); do [[ -s $run/display ]] && break; sleep 0.1; done
DISPLAY=$(cat "$run/display")
export DISPLAY
swaymsg -q focus output "$focus"

export WINEPREFIX=$run/pfx WINEDEBUG=${WINEDEBUG:--all} WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree=d;mshtml=d"
export LD_LIBRARY_PATH=$dist/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} WINEDLLPATH=$dist/lib/wine
"$dist/bin/wine" wineboot -u >/dev/null 2>&1
"$dist/bin/wineserver" -w
"$dist/bin/wine" "$here/fsrepro.exe" "$@" >"$run/repro.log" 2>"$run/wine.log" &
wine_pid=$!
sleep 6
swaymsg -t get_tree | python3 -c 'import json, sys
def walk(n):
    if n.get("type") == "output": print("output", n["name"])
    if n.get("shell") == "xwayland": print("  window", n.get("name"), n["rect"], "fullscreen", n.get("fullscreen_mode"))
    for c in n.get("nodes", []) + n.get("floating_nodes", []): walk(c)
walk(json.load(sys.stdin))' >"$run/tree.log"

# three spots on the focused output, in layout coordinates (sway.conf: HDMI at 2560,0)
x0=0; [[ $focus == HEADLESS-2 ]] && x0=2560
for xy in "400 400" "1280 720" "2000 1300"; do
    read -r x y <<<"$xy"
    echo "pointer -> output $x,$y" >>"$run/repro.log"
    printf 'abs %s %s 5120 1600\nsleep 600\nclick\nsleep 900\n' "$((x0 + x))" "$y"
done | "$here/vptr"
grim -o "$focus" "$run/shot.png" 2>/dev/null
wait "$wine_pid"
"$dist/bin/wineserver" -k 2>/dev/null
kill "$sway_pid" 2>/dev/null; wait "$sway_pid" 2>/dev/null
echo "$run"
