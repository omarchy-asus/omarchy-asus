#!/bin/bash
# bin/omarchy-asus-setup's retire_local_g16_fixes (#136), offline: the script is sourced with
# OMARCHY_ASUS_SETUP_SOURCE_ONLY=1, HOME and OMARCHY_ASUS_SETUP_ROOT are temp dirs, and pacman,
# udevadm and sudo are stubs that append their arguments to a log (sudo then runs the command).
# The fixture is a hand-made copy of what omarchy-asus-g16 ships:
# /etc/udev/rules.d/90-touchpad-wake.rules (touchpad wakeup off for i2c-ASUF1209) and
# /etc/systemd/sleep.conf.d/10-hibernate.conf (HibernateMode=shutdown).
#   1. the user says yes: the rule moved aside, udev reloaded and triggered for i2c-ASUF1209,
#      the undo command shown, the HibernateMode line reported and the drop-in left unchanged
#   2. the user says no: the rule stays, a 'kept' warning, no udevadm, the sleep line reported
#   3. --dry-run (package not installed: dry-run bypasses the gate): the rule stays, no sudo or
#      udevadm runs, [dry-run] lines
#   4. a re-run after 1: the backup unchanged, no numbered backup, no prompt, no udevadm
#   5. a backup already exists: it is kept, the new one gets a numbered name
#   6. nothing local: no output, no prompt, no sudo or udevadm calls
#   7. omarchy-asus-g16 not installed: no output, the rule stays
#   8. a rule owned by a package: not offered, it stays
#   9. ASUF1209 only in a comment, next to an unrelated active power/wakeup line: not offered
#  10. a HibernateMode other than shutdown in the drop-in is reported with a warning; a
#      commented HibernateMode in sleep.conf is not reported
# Usage: tests/ci/setup-retire-g16-local.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin"
fail=0

# Stubs: each appends "<name> <args>" to $LOG (set per case).
# pacman: `-Q omarchy-asus-g16` succeeds when $G16_INSTALLED is 1 (the default), `-Qqo <path>`
# when <path> is $OWNED; everything else fails.
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$LOG"
if [[ $* == "-Q omarchy-asus-g16" ]]; then
    [[ ${G16_INSTALLED:-1} == 1 ]]
    exit
fi
if [[ ${1:-} == -Qqo ]]; then
    [[ -n ${OWNED:-} && ${!#} == "$OWNED" ]]
    exit
fi
exit 1
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
chmod +x "$S/bin/pacman" "$S/bin/udevadm" "$S/bin/sudo"
export PATH=$S/bin:$PATH
# Nothing the host exports in the XDG base dirs reaches the script (#120).
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
export G16_INSTALLED=1 OWNED=''

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

# Per case: C (case dir, its HOME is $C/home and its ROOT $C/root), R (its udev rules dir),
# D (its sleep.conf.d), RULE (the fixture rule), DROPIN (the fixture drop-in), LOG (stub calls)
# and OUT (the function's output).
setup_case() {
    C=$S/$1 R=$S/$1/root/etc/udev/rules.d D=$S/$1/root/etc/systemd/sleep.conf.d
    RULE=$R/90-touchpad-wake.rules DROPIN=$D/10-hibernate.conf
    LOG=$C/log OUT=$C/out
    export LOG
    mkdir -p "$C/home" "$R" "$D"
    : >"$LOG"
}

# The hand-made copies of the G16 fixes; $C/rule.orig and $C/dropin.orig keep their bytes.
fixture() {
    printf '%s\n' '# Keep the touchpad from waking the G16' \
        'ACTION=="add", SUBSYSTEM=="i2c", KERNEL=="i2c-ASUF1209:*", ATTR{power/wakeup}="disabled"' >"$RULE"
    printf '%s\n' '[Sleep]' 'HibernateMode=shutdown' 'HibernateDelaySec=30min' >"$DROPIN"
    cp "$RULE" "$C/rule.orig"
    cp "$DROPIN" "$C/dropin.orig"
}

# run <confirm return code> <dry run 0|1>
run() {
    local rc=$1 dry=$2 st=0
    (
        set --
        export HOME=$C/home OMARCHY_ASUS_SETUP_ROOT=$C/root
        # shellcheck source=/dev/null
        OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$LIB"
        # shellcheck disable=SC2034 # read by the sourced functions
        DRY_RUN=$dry
        confirm() { printf 'confirm %s\n' "$1" >>"$LOG"; return "$rc"; }
        retire_local_g16_fixes
    ) >"$OUT" 2>&1 || st=$?
    check "retire_local_g16_fixes exits 0" [ "$st" -eq 0 ]
}

echo "== 1. the user says yes"
setup_case c1
fixture
run 0 0
check "rule moved away" [ ! -e "$RULE" ]
check "rule backup" [ -f "$RULE.before-omarchy-asus" ]
check "asked once" [ "$(grep -c '^confirm ' "$LOG")" -eq 1 ]
check "moved with sudo mv" grep -q '^sudo mv .*90-touchpad-wake\.rules' "$LOG"
check "udev reloaded" grep -qx 'udevadm control --reload' "$LOG"
check "udev triggered for i2c-ASUF1209" grep -q '^udevadm trigger .*--subsystem-match=i2c.*i2c-ASUF1209' "$LOG"
check "undo for the rule" grep -qxF \
    "      $RULE -> 90-touchpad-wake.rules.before-omarchy-asus; undo: sudo mv $RULE.before-omarchy-asus $RULE && sudo udevadm control --reload" "$OUT"
check "reports the HibernateMode line" grep -qF '10-hibernate.conf:2: HibernateMode=shutdown' "$OUT"
check "no 'other than shutdown' warning" not grep -qF 'other than shutdown' "$OUT"
check "drop-in unchanged" cmp -s "$C/dropin.orig" "$DROPIN"

echo "== 2. the user says no"
setup_case c2
fixture
run 1 0
check "rule stays" cmp -s "$C/rule.orig" "$RULE"
check "no backups" none "$R"/*.before-omarchy-asus*
check "'kept' warning" grep -qF 'kept:' "$OUT"
check "no udevadm runs" not grep -q '^udevadm ' "$LOG"
check "no sudo mv" not grep -q '^sudo mv ' "$LOG"
check "reports the HibernateMode line" grep -qF '10-hibernate.conf:2: HibernateMode=shutdown' "$OUT"
check "drop-in unchanged" cmp -s "$C/dropin.orig" "$DROPIN"

echo "== 3. --dry-run (package not installed)"
setup_case c3
fixture
export G16_INSTALLED=0
run 0 1
export G16_INSTALLED=1
check "rule stays" cmp -s "$C/rule.orig" "$RULE"
check "no backups" none "$R"/*.before-omarchy-asus*
check "no sudo runs" not grep -q '^sudo ' "$LOG"
check "no udevadm runs" not grep -q '^udevadm ' "$LOG"
check "[dry-run] sudo mv" grep -qF '[dry-run] sudo mv' "$OUT"
check "[dry-run] would move aside" grep -qF '[dry-run] would move aside:' "$OUT"
check "drop-in unchanged" cmp -s "$C/dropin.orig" "$DROPIN"

echo "== 4. a re-run after the rule was moved aside"
setup_case c4
fixture
run 0 0
check "first run: rule backup" [ -f "$RULE.before-omarchy-asus" ]
: >"$LOG"
run 0 0
check "backup unchanged" cmp -s "$C/rule.orig" "$RULE.before-omarchy-asus"
check "no numbered backup" [ ! -e "$RULE.before-omarchy-asus.1" ]
check "no udevadm runs" not grep -q '^udevadm ' "$LOG"
check "no prompt" not grep -q '^confirm ' "$LOG"
check "drop-in unchanged" cmp -s "$C/dropin.orig" "$DROPIN"

echo "== 5. a backup already exists"
setup_case c5
fixture
printf '# an older hand-made rule\n' >"$RULE.before-omarchy-asus"
cp "$RULE.before-omarchy-asus" "$C/older.orig"
run 0 0
check "rule moved away" [ ! -e "$RULE" ]
check "earlier backup kept" cmp -s "$C/older.orig" "$RULE.before-omarchy-asus"
check "new backup numbered" cmp -s "$C/rule.orig" "$RULE.before-omarchy-asus.1"
check "undo names the numbered backup" grep -qxF \
    "      $RULE -> 90-touchpad-wake.rules.before-omarchy-asus.1; undo: sudo mv $RULE.before-omarchy-asus.1 $RULE && sudo udevadm control --reload" "$OUT"

echo "== 6. nothing local"
setup_case c6
run 0 0
check "no output" [ ! -s "$OUT" ]
check "no prompt" not grep -q '^confirm ' "$LOG"
check "no sudo/udevadm calls" not grep -qE '^(sudo|udevadm) ' "$LOG"

echo "== 7. omarchy-asus-g16 not installed"
setup_case c7
fixture
export G16_INSTALLED=0
run 0 0
export G16_INSTALLED=1
check "no output" [ ! -s "$OUT" ]
check "rule stays" cmp -s "$C/rule.orig" "$RULE"
check "no prompt" not grep -q '^confirm ' "$LOG"
check "no sudo/udevadm calls" not grep -qE '^(sudo|udevadm) ' "$LOG"

echo "== 8. a rule owned by a package"
setup_case c8
fixture
# pacman gets the real path, not the ROOT-prefixed one.
export OWNED=/etc/udev/rules.d/90-touchpad-wake.rules
run 0 0
export OWNED=''
check "pacman asked about the real path" grep -qxF 'pacman -Qqo /etc/udev/rules.d/90-touchpad-wake.rules' "$LOG"
check "no prompt" not grep -q '^confirm ' "$LOG"
check "rule stays" cmp -s "$C/rule.orig" "$RULE"
check "no backups" none "$R"/*.before-omarchy-asus*
check "no sudo/udevadm calls" not grep -qE '^(sudo|udevadm) ' "$LOG"

echo "== 9. ASUF1209 only in a comment"
setup_case c9
printf '%s\n' '# was: KERNEL=="i2c-ASUF1209:*", ATTR{power/wakeup}="disabled"' \
    'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/wakeup}="enabled"' >"$R/91-usb-wake.rules"
cp "$R/91-usb-wake.rules" "$C/usb.orig"
run 0 0
check "no prompt" not grep -q '^confirm ' "$LOG"
check "rule stays" cmp -s "$C/usb.orig" "$R/91-usb-wake.rules"
check "no backups" none "$R"/*.before-omarchy-asus*
check "not offered" not grep -qF '91-usb-wake.rules' "$OUT"
check "no sudo/udevadm calls" not grep -qE '^(sudo|udevadm) ' "$LOG"

echo "== 10. a HibernateMode other than shutdown"
setup_case c10
printf '%s\n' '#HibernateMode=platform' >"$C/root/etc/systemd/sleep.conf"
printf '%s\n' '[Sleep]' 'HibernateMode=platform' >"$DROPIN"
cp "$C/root/etc/systemd/sleep.conf" "$C/sleep.orig"
cp "$DROPIN" "$C/dropin.orig"
run 0 0
check "reports the drop-in line" grep -qF '10-hibernate.conf:2: HibernateMode=platform' "$OUT"
check "'other than shutdown' warning" grep -qF 'other than shutdown' "$OUT"
check "commented sleep.conf line not reported" not grep -qE 'sleep\.conf:[0-9]+:' "$OUT"
check "commented line text not reported" not grep -qF '#HibernateMode' "$OUT"
check "sleep.conf unchanged" cmp -s "$C/sleep.orig" "$C/root/etc/systemd/sleep.conf"
check "drop-in unchanged" cmp -s "$C/dropin.orig" "$DROPIN"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
