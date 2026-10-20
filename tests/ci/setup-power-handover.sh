#!/bin/bash
# bin/omarchy-asus-setup's prepare_power_owner (#135), offline: the script is sourced with
# OMARCHY_ASUS_SETUP_SOURCE_ONLY=1, HOME and the /etc unit dirs are temp dirs, and systemctl
# and sudo are stubs that append their arguments to a log (sudo then runs the command).
# power_owner_choice is replaced by one that answers keep, omarchy or nothing. The fixture is
# a hand-made rog-power unit whose ExecStart is /usr/local/bin/rog-power-daemon.
#   0. sourcing works, own_power_manager finds the user unit (see rog-power-xdg.sh)
#   1. keep, no toggle: the toggle is set, the unit stays, nothing disabled
#   2. keep, toggle already set: it stays, nothing disabled, 'already set' shown
#   3. omarchy, user unit, toggle set: disable --now runs before the move, the unit and the
#      toggle are moved aside, the source monitor is checked and shown enabled, the undo
#      commands shown, the daemon in /usr/local/bin and the sudoers rule that names rog-power
#      listed as left in place (the rule untouched, an unrelated sudoers file not listed)
#   4. omarchy, toggle not set: the unit is moved aside, no toggle or toggle backup appears
#   5. a re-run after 4: no output, no systemctl calls
#   6. --dry-run: nothing changes, no disable and no sudo runs, a [dry-run] line per step
#   7. a backup already exists: it is kept, the new one gets a numbered name
#   8. no choice: nothing changes, a warning
#   9. the source monitor is not enabled: a warning and the enable command, never run
#  10. the source monitor unit is missing: not checked, the upgrade installs it
#  11. a system unit in /etc/systemd/system: disabled and moved aside with sudo
# All cases run with the XDG base-dir variables unset, whatever the host exports.
# Usage: tests/ci/setup-power-handover.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin"
fail=0

# Stubs: each appends "<name> <args>" to $LOG (set per case).
cat >"$S/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$LOG"
if [[ $* == "--user is-enabled omarchy-powerprofiles-source-monitor.service" ]]; then
    exit "${MONITOR_ENABLED:-0}"
fi
if [[ $* == "--user disable --now rog-power.service" ]]; then
    if [[ -e ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/rog-power.service ]]; then
        echo unit-present-at-disable=yes >>"$LOG"
    else
        echo unit-present-at-disable=no >>"$LOG"
    fi
fi
exit 0
STUB
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$LOG"
exec "$@"
STUB
chmod +x "$S/bin/systemctl" "$S/bin/sudo"
export PATH=$S/bin:$PATH
# The user unit dir follows XDG_CONFIG_HOME, and the toggle lives under HOME: unset every XDG
# base dir so nothing the host exports reaches the script (#120).
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

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

# Per case: C (case dir), H (its HOME), U (its user unit dir), E (its /etc), T (the toggle),
# M (the source monitor unit), LOG (stub calls) and OUT (the function's output).
setup_case() {
    C=$S/$1 H=$S/$1/home U=$S/$1/home/.config/systemd/user E=$S/$1/etc
    T=$H/.local/state/omarchy/toggles/powerprofiles-autoswitch-off
    M=$C/usr-lib/omarchy-powerprofiles-source-monitor.service
    LOG=$C/log OUT=$C/out
    MONITOR_ENABLED=0
    export LOG MONITOR_ENABLED
    mkdir -p "$U" "$E/systemd/user" "$E/systemd/system" "$E/sudoers.d" "${M%/*}"
    printf '[Unit]\nDescription=Omarchy power source monitor\n' >"$M"
    : >"$LOG"
}

# fixture <dir>: a hand-made rog-power unit in DIR.
fixture() {
    printf '[Unit]\nDescription=rog-power\n[Service]\nExecStart=/usr/local/bin/rog-power-daemon\n' >"$1/rog-power.service"
}

set_toggle() { mkdir -p "${T%/*}" && touch "$T"; }

# run <choice> <dry run 0|1>
run() {
    local choice=$1 dry=$2 st=0
    (
        set --
        export HOME=$H
        # shellcheck source=/dev/null
        OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB"
        # shellcheck disable=SC2034 # read by the sourced functions
        DRY_RUN=$dry POWER_ETC_USER_DIR=$E/systemd/user POWER_ETC_SYSTEM_DIR=$E/systemd/system POWER_MONITOR_UNIT=$M
        # shellcheck disable=SC2034 # read by the sourced functions
        POWER_SUDOERS_DIR=$E/sudoers.d
        power_owner_choice() { echo "$choice"; }
        prepare_power_owner
    ) >"$OUT" 2>&1 || st=$?
    check "prepare_power_owner exits 0" [ "$st" -eq 0 ]
}

echo "== 0. sourcing the script, own_power_manager finds the user unit"
setup_case c0
fixture "$U"
st=0
found=$(
    set --
    export HOME=$H
    # shellcheck source=/dev/null
    OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB" >/dev/null 2>&1
    # shellcheck disable=SC2034 # read by the sourced functions
    POWER_ETC_USER_DIR=$E/systemd/user POWER_ETC_SYSTEM_DIR=$E/systemd/system
    printf 'toggle=%s\n' "$POWER_TOGGLE"
    own_power_manager
) || st=$?
check "own_power_manager exits 0" [ "$st" -eq 0 ]
check "own_power_manager finds the user unit (got: $found)" grep -qxF "$U/rog-power.service" <<<"$found"
check "POWER_TOGGLE follows HOME" grep -qxF "toggle=$T" <<<"$found"

echo "== 1. keep, no toggle"
setup_case c1
fixture "$U"
run keep 0
check "toggle set" [ -e "$T" ]
check "unit stays" [ -f "$U/rog-power.service" ]
check "no unit backup" none "$U"/rog-power.service.before-omarchy-asus*
check "no disable" not grep -qF 'systemctl --user disable' "$LOG"

echo "== 2. keep, toggle already set"
setup_case c2
fixture "$U"
set_toggle
run keep 0
check "toggle stays" [ -e "$T" ]
check "unit stays" [ -f "$U/rog-power.service" ]
check "no disable" not grep -qF 'systemctl --user disable' "$LOG"
check "says the toggle is already set" grep -qF 'already set' "$OUT"

echo "== 3. omarchy, user unit, toggle set"
setup_case c3
fixture "$U"
set_toggle
printf '%%wheel ALL=(root) NOPASSWD: /usr/local/bin/rog-power-daemon\n' >"$E/sudoers.d/50-rog-power"
cp "$E/sudoers.d/50-rog-power" "$C/sudoers-before"
printf 'Defaults editor=/usr/bin/nvim\n' >"$E/sudoers.d/10-editor"
run omarchy 0
check "disable --now ran" grep -qxF 'systemctl --user disable --now rog-power.service' "$LOG"
check "disable ran before the move" grep -qxF 'unit-present-at-disable=yes' "$LOG"
check "unit moved away" [ ! -e "$U/rog-power.service" ]
check "unit backup" [ -f "$U/rog-power.service.before-omarchy-asus" ]
check "toggle moved away" [ ! -e "$T" ]
check "toggle backup" [ -e "$T.before-omarchy-asus" ]
check "source monitor checked" grep -qxF 'systemctl --user is-enabled omarchy-powerprofiles-source-monitor.service' "$LOG"
check "says the source monitor is enabled" grep -qE 'omarchy-powerprofiles-source-monitor.*enabled' "$OUT"
check "no source monitor warning" not grep -qE 'warning:.*source-monitor' "$OUT"
check "undo for the unit" grep -qE 'undo:.*rog-power\.service' "$OUT"
check "undo for the toggle" grep -qE 'undo:.*powerprofiles-autoswitch-off' "$OUT"
check "lists the daemon as left in place" grep -qF '/usr/local/bin/rog-power-daemon: left in place' "$OUT"
check "lists the sudoers rule as left in place" grep -qF "$E/sudoers.d/50-rog-power: left in place" "$OUT"
check "sudoers rule untouched" cmp -s "$C/sudoers-before" "$E/sudoers.d/50-rog-power"
check "unrelated sudoers file not listed" not grep -qF '10-editor' "$OUT"
check "no sudo runs for a readable sudoers dir" not grep -q '^sudo ' "$LOG"

echo "== 4. omarchy, toggle not set"
setup_case c4
fixture "$U"
run omarchy 0
check "unit moved away" [ ! -e "$U/rog-power.service" ]
check "unit backup" [ -f "$U/rog-power.service.before-omarchy-asus" ]
check "no toggle and no toggle backup" none "$T" "$T".before-omarchy-asus*

echo "== 5. a re-run after 4 does nothing"
# Same HOME, unit dirs and log as case 4.
OUT=$C/out5
before=$(grep -c '^systemctl ' "$LOG")
run omarchy 0
check "no output" [ ! -s "$OUT" ]
check "no new systemctl calls" [ "$(grep -c '^systemctl ' "$LOG")" -eq "$before" ]
check "no second unit backup" none "$U"/rog-power.service.before-omarchy-asus.*

echo "== 6. --dry-run"
setup_case c6
fixture "$U"
set_toggle
run omarchy 1
check "unit stays" [ -f "$U/rog-power.service" ]
check "toggle stays" [ -e "$T" ]
check "no backups" none "$U"/rog-power.service.before-omarchy-asus* "$T".before-omarchy-asus*
check "no disable" not grep -qF 'systemctl --user disable' "$LOG"
check "no sudo runs" not grep -q '^sudo ' "$LOG"
check "[dry-run] disable" grep -qF '[dry-run] would run: systemctl --user disable --now rog-power.service' "$OUT"
check "[dry-run] move" grep -qF '[dry-run] would run: mv' "$OUT"

echo "== 7. a backup already exists"
setup_case c7
fixture "$U"
printf '[Unit]\nDescription=an older backup\n' >"$U/rog-power.service.before-omarchy-asus"
cp "$U/rog-power.service.before-omarchy-asus" "$C/older"
run omarchy 0
check "earlier backup kept unchanged" cmp -s "$C/older" "$U/rog-power.service.before-omarchy-asus"
check "new backup numbered" [ -f "$U/rog-power.service.before-omarchy-asus.1" ]
check "unit moved away" [ ! -e "$U/rog-power.service" ]

echo "== 8. no choice"
setup_case c8
fixture "$U"
run '' 0
check "unit stays" [ -f "$U/rog-power.service" ]
check "no backups" none "$U"/rog-power.service.before-omarchy-asus*
check "no toggle" [ ! -e "$T" ]
check "no disable" not grep -qF 'systemctl --user disable' "$LOG"
check "a warning" grep -q 'warning:' "$OUT"

echo "== 9. the source monitor is not enabled"
setup_case c9
fixture "$U"
MONITOR_ENABLED=1
run omarchy 0
check "source monitor checked" grep -qxF 'systemctl --user is-enabled omarchy-powerprofiles-source-monitor.service' "$LOG"
check "a warning" grep -q 'warning:' "$OUT"
check "shows the enable command" grep -qF 'systemctl --user enable --now omarchy-powerprofiles-source-monitor.service' "$OUT"
check "never enables it" not grep -qE '^systemctl --user enable( |$)' "$LOG"

echo "== 10. the source monitor unit is missing"
setup_case c10
fixture "$U"
M=$C/usr-lib/no-such-monitor.service
run omarchy 0
check "no is-enabled call" not grep -qF 'is-enabled' "$LOG"
check "says the upgrade installs it" grep -qi 'upgrade' "$OUT"
check "unit moved away" [ ! -e "$U/rog-power.service" ]

echo "== 11. a system unit in /etc/systemd/system"
setup_case c11
fixture "$E/systemd/system"
run omarchy 0
check "sudo disable --now ran" grep -qxF 'sudo systemctl disable --now rog-power.service' "$LOG"
check "sudo mv to the backup" grep -qE \
    '^sudo mv .*/systemd/system/rog-power\.service .*/systemd/system/rog-power\.service\.before-omarchy-asus$' "$LOG"
check "unit moved away" [ ! -e "$E/systemd/system/rog-power.service" ]
check "unit backup" [ -f "$E/systemd/system/rog-power.service.before-omarchy-asus" ]
check "no user disable" not grep -qF 'systemctl --user disable' "$LOG"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
