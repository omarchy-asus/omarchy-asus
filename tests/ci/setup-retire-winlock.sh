#!/bin/bash
# bin/omarchy-asus-setup's retire_local_winlock (#88), offline: the script is sourced with
# OMARCHY_ASUS_SETUP_SOURCE_ONLY=1, HOME and the udev rules dir are temp dirs, and pacman, systemctl,
# udevadm and sudo are stubs that append their arguments to a log (sudo then runs the command).
# The fixture is a hand-made setup: the unit, its drop-in mode.conf, a default.target.wants
# link, /etc/udev/rules.d/99-g16-winlock-hidraw.rules and ~/.local/bin/g16-winlock.
#   1. full retire: unit, drop-in and rule moved aside, the link removed, disable runs before
#      the move, udev reloaded and triggered, the settings, a ~/.local/bin warning and the undo
#      commands shown, ~/.local/bin/g16-winlock left alone
#   2. rerun after an older version moved only the unit: the leftovers are still retired
#   3. --dry-run: nothing changes, no systemctl/udevadm/sudo runs, a [dry-run] line per step
#   4. a backup already exists: it is kept, the new one gets a numbered name
#   5. nothing local: no output, no systemctl/udevadm calls
#   6. the user says no: everything stays, a 'kept' warning
#   7. only a drop-in for the packaged unit (as the G16 Control widget writes): left alone
#   8. a new widget drop-in after an earlier full retire: left alone
#   9. only ~/.local/bin/g16-winlock: the warning, no list, no prompt, nothing moved
#  10. an older run moved only the unit, and the drop-in holds g16ctl's mode.conf: it stays
#  11. an older run moved only the unit, and the hand-made drop-in changed since: it stays
#  12. a hand-made unit, and a drop-in with g16ctl's mode.conf and a hand override: both
#      are moved aside, and g16ctl's mode.conf is put back
#  13. an older run moved only the unit (no links left), and the hand-made drop-in predates
#      that move: it is retired
# Before the cases: sourcing the script leaves the caller's B R Y G N alone.
# Usage: tests/ci/setup-retire-winlock.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin"
fail=0

# Stubs: each appends "<name> <args>" to $LOG (set per case).
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$LOG"
[[ $* == "-Q asus-rog-nkey-winlock" ]]
STUB
cat >"$S/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$LOG"
if [[ ${1:-} == --user && ${2:-} == disable ]]; then
    if [[ -e $HOME/.config/systemd/user/g16-winlock.service ]]; then
        echo unit-present-at-disable=yes >>"$LOG"
    else
        echo unit-present-at-disable=no >>"$LOG"
    fi
fi
exit 0
STUB
cat >"$S/bin/udevadm" <<'STUB'
#!/bin/bash
printf 'udevadm %s\n' "$*" >>"$LOG"
STUB
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$LOG"
exec "$@"
STUB
chmod +x "$S/bin/pacman" "$S/bin/systemctl" "$S/bin/udevadm" "$S/bin/sudo"
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
none() { # true when none of the paths exists (unmatched globs stay literal and don't)
    local p
    for p in "$@"; do [[ -e $p || -L $p ]] && return 1; done
    return 0
}

# Per case: C (case dir), H (its HOME), U (its user unit dir), R (its udev rules dir),
# LOG (stub calls) and OUT (the function's output).
setup_case() {
    C=$S/$1 H=$S/$1/home U=$S/$1/home/.config/systemd/user R=$S/$1/etc/udev/rules.d
    LOG=$C/log OUT=$C/out
    export LOG
    mkdir -p "$U" "$R"
    : >"$LOG"
}

fixture() {
    mkdir -p "$U/g16-winlock.service.d" "$U/default.target.wants" "$H/.local/bin"
    printf '%s\n' '[Unit]' 'Description=G16 Win-lock' '[Service]' \
        'ExecStart=%h/.local/bin/g16-winlock' '[Install]' 'WantedBy=default.target' >"$U/g16-winlock.service"
    printf '# set by hand\n[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
    ln -s ../g16-winlock.service "$U/default.target.wants/g16-winlock.service"
    printf 'SUBSYSTEM=="hidraw", MODE="0660"\n' >"$R/99-g16-winlock-hidraw.rules"
    printf '#!/bin/bash\n' >"$H/.local/bin/g16-winlock"
    chmod +x "$H/.local/bin/g16-winlock"
}

# run <confirm return code> <dry run 0|1>
run() {
    local rc=$1 dry=$2 st=0
    (
        set --
        export HOME=$H
        # shellcheck source=/dev/null
        OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB"
        # shellcheck disable=SC2034 # read by the sourced functions
        WINLOCK_UDEV_DIR=$R WINLOCK_LOCAL_BIN=$HOME/.local/bin/g16-winlock DRY_RUN=$dry
        confirm() { return "$rc"; }
        retire_local_winlock
    ) >"$OUT" 2>&1 || st=$?
    check "retire_local_winlock exits 0" [ "$st" -eq 0 ]
}

echo "== 0. sourcing the script keeps the caller's one-letter variables"
mkdir -p "$S/c0/home"
colours=$(
    set --
    B=keep-b R=keep-r Y=keep-y G=keep-g N=keep-n
    export HOME=$S/c0/home
    # shellcheck source=/dev/null
    OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB" >/dev/null 2>&1
    printf '%s ' "$B" "$R" "$Y" "$G" "$N"
)
check "B R Y G N unchanged (got: $colours)" [ "$colours" = "keep-b keep-r keep-y keep-g keep-n " ]

echo "== 1. full retire"
setup_case c1
fixture
run 0 0
check "unit moved away" [ ! -e "$U/g16-winlock.service" ]
check "drop-in moved away" [ ! -e "$U/g16-winlock.service.d" ]
check "wants link removed" not [ -L "$U/default.target.wants/g16-winlock.service" ]
check "udev rule moved away" [ ! -e "$R/99-g16-winlock-hidraw.rules" ]
check "unit backup" [ -f "$U/g16-winlock.service.before-omarchy-asus" ]
check "drop-in backup" [ -f "$U/g16-winlock.service.d.before-omarchy-asus/mode.conf" ]
check "udev rule backup" [ -f "$R/99-g16-winlock-hidraw.rules.before-omarchy-asus" ]
check "disable ran" grep -qx 'systemctl --user disable g16-winlock.service' "$LOG"
check "disable ran before the move" grep -qx 'unit-present-at-disable=yes' "$LOG"
check "udev reloaded" grep -qx 'udevadm control --reload' "$LOG"
check "udev triggered for hidraw" grep -q '^udevadm trigger .*--subsystem-match=hidraw' "$LOG"
check "shows the drop-in setting" grep -qF 'Environment=G16_WINLOCK_MODE=unlock' "$OUT"
check "warns about ~/.local/bin/g16-winlock" grep -q 'warning:.*~/.local/bin/g16-winlock' "$OUT"
check "undo for the unit" grep -qF \
    'undo: mv ~/.config/systemd/user/g16-winlock.service.before-omarchy-asus ~/.config/systemd/user/g16-winlock.service' "$OUT"
check "undo for the drop-in" grep -qF \
    'undo: mv ~/.config/systemd/user/g16-winlock.service.d.before-omarchy-asus ~/.config/systemd/user/g16-winlock.service.d' "$OUT"
check "undo for the wants link" grep -qF 'undo: systemctl --user enable g16-winlock.service' "$OUT"
check "undo for the udev rule" grep -qF \
    "undo: sudo mv $R/99-g16-winlock-hidraw.rules.before-omarchy-asus $R/99-g16-winlock-hidraw.rules" "$OUT"
check "the local bin/g16-winlock left in place" [ -x "$H/.local/bin/g16-winlock" ]

echo "== 2. rerun after the unit alone was moved"
setup_case c2
fixture
mv "$U/g16-winlock.service" "$U/g16-winlock.service.before-omarchy-asus"
run 0 0
check "drop-in moved away" [ ! -e "$U/g16-winlock.service.d" ]
check "drop-in backup" [ -f "$U/g16-winlock.service.d.before-omarchy-asus/mode.conf" ]
check "dangling wants link removed" not [ -L "$U/default.target.wants/g16-winlock.service" ]
check "udev rule moved away" [ ! -e "$R/99-g16-winlock-hidraw.rules" ]
check "udev rule backup" [ -f "$R/99-g16-winlock-hidraw.rules.before-omarchy-asus" ]
check "earlier unit backup untouched" [ -f "$U/g16-winlock.service.before-omarchy-asus" ]
check "no second unit backup" [ ! -e "$U/g16-winlock.service.before-omarchy-asus.1" ]
check "udev reloaded" grep -qx 'udevadm control --reload' "$LOG"

echo "== 3. --dry-run"
setup_case c3
fixture
run 0 1
check "unit stays" [ -f "$U/g16-winlock.service" ]
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "wants link stays" [ -L "$U/default.target.wants/g16-winlock.service" ]
check "udev rule stays" [ -f "$R/99-g16-winlock-hidraw.rules" ]
check "no backups" none "$U"/*.before-omarchy-asus* "$R"/*.before-omarchy-asus*
check "no systemctl/udevadm/sudo runs" not grep -qE '^(systemctl|udevadm|sudo) ' "$LOG"
check "[dry-run] disable" grep -qF '[dry-run] would run: systemctl --user disable g16-winlock.service' "$OUT"
check "[dry-run] unit move" grep -qF \
    '[dry-run] would run: mv ~/.config/systemd/user/g16-winlock.service ~/.config/systemd/user/g16-winlock.service.before-omarchy-asus' "$OUT"
check "[dry-run] drop-in move" grep -qF \
    '[dry-run] would run: mv ~/.config/systemd/user/g16-winlock.service.d ~/.config/systemd/user/g16-winlock.service.d.before-omarchy-asus' "$OUT"
check "[dry-run] wants link" grep -qF \
    '[dry-run] would run: rm ~/.config/systemd/user/default.target.wants/g16-winlock.service' "$OUT"
check "[dry-run] daemon-reload" grep -qF '[dry-run] would run: systemctl --user daemon-reload' "$OUT"
check "[dry-run] udev rule move" grep -q '\[dry-run\] sudo mv .*99-g16-winlock-hidraw\.rules' "$OUT"
check "[dry-run] udev reload" grep -qF '[dry-run] sudo udevadm control --reload' "$OUT"
check "[dry-run] udev trigger" grep -qF '[dry-run] sudo udevadm trigger --subsystem-match=hidraw' "$OUT"

echo "== 4. a backup already exists"
setup_case c4
fixture
mkdir -p "$U/g16-winlock.service.d.before-omarchy-asus"
printf '[Service]\n' >"$U/g16-winlock.service.d.before-omarchy-asus/old.conf"
run 0 0
check "earlier backup kept" [ -f "$U/g16-winlock.service.d.before-omarchy-asus/old.conf" ]
check "earlier backup not merged into" [ ! -e "$U/g16-winlock.service.d.before-omarchy-asus/mode.conf" ]
check "new backup numbered" [ -f "$U/g16-winlock.service.d.before-omarchy-asus.1/mode.conf" ]
check "drop-in moved away" [ ! -e "$U/g16-winlock.service.d" ]

echo "== 5. nothing local"
setup_case c5
run 0 0
check "no output" [ ! -s "$OUT" ]
check "no systemctl/udevadm calls" not grep -qE '^(systemctl|udevadm|sudo) ' "$LOG"

echo "== 6. the user says no"
setup_case c6
fixture
run 1 0
check "unit stays" [ -f "$U/g16-winlock.service" ]
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "wants link stays" [ -L "$U/default.target.wants/g16-winlock.service" ]
check "udev rule stays" [ -f "$R/99-g16-winlock-hidraw.rules" ]
check "no backups" none "$U"/*.before-omarchy-asus* "$R"/*.before-omarchy-asus*
check "no systemctl/udevadm/sudo runs" not grep -qE '^(systemctl|udevadm|sudo) ' "$LOG"
check "'kept' warning" grep -q 'warning:.*kept' "$OUT"

echo "== 7. a drop-in written for the packaged unit (G16 Control widget) stays"
setup_case c7
mkdir -p "$U/g16-winlock.service.d" "$U/graphical-session.target.wants"
printf '[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
# Stands in for /usr/lib/systemd/user/g16-winlock.service (the CI host has no package).
printf '[Service]\n' >"$C/packaged.service"
ln -s "$C/packaged.service" "$U/graphical-session.target.wants/g16-winlock.service"
run 0 0
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "link to the packaged unit stays" [ -L "$U/graphical-session.target.wants/g16-winlock.service" ]
check "no backups" none "$U"/*.before-omarchy-asus*
check "no output" [ ! -s "$OUT" ]

echo "== 8. a new widget drop-in after an earlier full retire stays"
setup_case c8
mkdir -p "$U/g16-winlock.service.d" "$U/g16-winlock.service.d.before-omarchy-asus"
printf '[Service]\n' >"$U/g16-winlock.service.before-omarchy-asus"
printf '[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
run 0 0
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "no numbered backup" none "$U"/*.before-omarchy-asus.1

echo "== 9. only ~/.local/bin/g16-winlock"
setup_case c9
mkdir -p "$H/.local/bin"
printf '#!/bin/bash\n' >"$H/.local/bin/g16-winlock"
chmod +x "$H/.local/bin/g16-winlock"
run 1 0 # a 'no' would print a 'kept' warning if anything asked
check "warns about ~/.local/bin/g16-winlock" grep -q 'warning:.*~/.local/bin/g16-winlock' "$OUT"
check "no list of local pieces" not grep -q 'These shadow or duplicate' "$OUT"
check "no prompt" not grep -q 'warning:.*kept' "$OUT"
check "the local bin/g16-winlock stays executable" [ -x "$H/.local/bin/g16-winlock" ]
check "no backups" none "$U"/*.before-omarchy-asus* "$R"/*.before-omarchy-asus* "$H"/.local/bin/*.before-omarchy-asus*
check "no systemctl/udevadm/sudo runs" not grep -qE '^(systemctl|udevadm|sudo) ' "$LOG"

echo "== 10. g16ctl's mode.conf after an older run moved only the unit stays"
setup_case c10
mkdir -p "$U/g16-winlock.service.d"
printf '[Service]\n' >"$U/g16-winlock.service.before-omarchy-asus"
printf '[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
run 0 0
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "no drop-in backup" none "$U"/g16-winlock.service.d.before-omarchy-asus*
check "no second unit backup" none "$U"/g16-winlock.service.before-omarchy-asus.*
check "no output" [ ! -s "$OUT" ]

echo "== 11. a hand-made drop-in changed after an older run moved the unit stays"
setup_case c11
printf '[Service]\n' >"$U/g16-winlock.service.before-omarchy-asus"
mkdir -p "$U/g16-winlock.service.d"
printf '# set by hand\n[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
touch -d '+1 hour' "$U/g16-winlock.service.d/mode.conf"
run 0 0
check "drop-in stays" [ -f "$U/g16-winlock.service.d/mode.conf" ]
check "no drop-in backup" none "$U"/g16-winlock.service.d.before-omarchy-asus*

echo "== 12. g16ctl's mode.conf in a retired hand-made drop-in is put back"
setup_case c12
mkdir -p "$U/g16-winlock.service.d"
printf '%s\n' '[Unit]' 'Description=G16 Win-lock' '[Service]' \
    'ExecStart=%h/.local/bin/g16-winlock' >"$U/g16-winlock.service"
printf '[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
printf '# set by hand\n[Service]\nRestart=always\n' >"$U/g16-winlock.service.d/override.conf"
cp "$U/g16-winlock.service.d/mode.conf" "$C/mode.conf"
run 0 0
check "unit moved away" [ ! -e "$U/g16-winlock.service" ]
check "unit backup" [ -f "$U/g16-winlock.service.before-omarchy-asus" ]
check "drop-in backup has override.conf" [ -f "$U/g16-winlock.service.d.before-omarchy-asus/override.conf" ]
check "override.conf not put back" [ ! -e "$U/g16-winlock.service.d/override.conf" ]
check "g16ctl's mode.conf put back unchanged" cmp -s "$C/mode.conf" "$U/g16-winlock.service.d/mode.conf"
check "says the G16 Control mode was kept" grep -qF 'kept the Win-lock mode set in G16 Control' "$OUT"

echo "== 13. a hand-made drop-in older than the unit an older run moved is retired"
setup_case c13
mkdir -p "$U/g16-winlock.service.d"
printf '# set by hand\n[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n' >"$U/g16-winlock.service.d/mode.conf"
touch -d '-1 hour' "$U/g16-winlock.service.d/mode.conf" "$U/g16-winlock.service.d"
printf '[Service]\n' >"$U/g16-winlock.service.before-omarchy-asus"
run 0 0
check "drop-in moved away" [ ! -e "$U/g16-winlock.service.d" ]
check "drop-in backup" [ -f "$U/g16-winlock.service.d.before-omarchy-asus/mode.conf" ]
check "earlier unit backup untouched" [ -f "$U/g16-winlock.service.before-omarchy-asus" ]

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
