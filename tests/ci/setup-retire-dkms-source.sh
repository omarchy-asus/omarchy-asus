#!/bin/bash
# bin/omarchy-asus-setup retires an unowned hid-asus DKMS source (#134), offline: the script is
# sourced with OMARCHY_ASUS_SETUP_SOURCE_ONLY=1, the DKMS source root and the backup dir are temp
# dirs, and uname, pacman, dkms, sudo, last and snapper are stubs driven by state files that append
# their arguments to a log (sudo then runs the command). The fixture is
# <src>/hid-asus-winlock-1 with a dkms.conf (PACKAGE_NAME hid-asus-winlock, PACKAGE_VERSION 1)
# and a hid-asus.c, as a build of recipes/hid-asus-winlock-dkms-reference leaves it.
#   1. a kernel that carries 0568 (7.2.8-9.1-omarchy), no owner, registered with DKMS, the user
#      says yes: dkms remove runs before the move, the source is moved to the backup dir, the
#      undo is shown; a second run does nothing
#   2. same, a backup of that name already exists: it is untouched, the new one gets a
#      .before-omarchy-asus name
#   3. same, not registered with DKMS: no dkms remove, the source is still moved
#   4. dkms remove fails: the source stays, nothing goes to the backup dir
#   5. the user says no: nothing moves, no dkms remove, a 'kept' warning and the manual commands
#   6. the stock kernel (7.2.8-9-omarchy): no prompt, nothing changes, today's warning
#   7. a fallback kernel (7.2.8-arch1-1): the same as 6
#   8. a source a package owns, on a kernel that carries 0568: no prompt, nothing moves, the
#      advice to remove the package
#   9. --dry-run: a [dry-run] line for dkms remove and for the move, nothing changes, no sudo runs
#  10. a dkms.conf without PACKAGE_NAME/PACKAGE_VERSION in hid_asus-2.0: the name and version
#      come from the directory name
# Usage: tests/ci/setup-retire-dkms-source.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
export STUB_STATE=$S
fail=0

# Without the source guard, sourcing the script would run the whole setup.
grep -q OMARCHY_ASUS_SETUP_SOURCE_ONLY "$W/bin/omarchy-asus-setup" ||
    { echo "not ok - bin/omarchy-asus-setup has no OMARCHY_ASUS_SETUP_SOURCE_ONLY guard"; exit 1; }

mkdir -p "$S/bin"
# krel: what uname -r prints.
cat >"$S/bin/uname" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf 'uname %s\n' "$*" >>"$S/log"
[[ ${1:-} == -r ]] || exit 1
cat "$S/krel"
STUB
# installed: one package name per line; files.<pkg>: its pacman -Qlq; owner: what pacman -Qqo
# prints for any path (missing: no package owns it).
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf 'pacman %s\n' "$*" >>"$S/log"
case $1 in
    -Q) grep -qxF "$2" "$S/installed" 2>/dev/null || exit 1; echo "$2 1-1" ;;
    -Qlq) cat "$S/files.$2" 2>/dev/null || exit 1 ;;
    -Qqo) [[ -f $S/owner ]] || exit 1; cat "$S/owner" ;;
    -Qu) exit 0 ;;
    *) exit 1 ;;
esac
STUB
# dkms-status: what dkms status prints; dkms-remove-rc: the exit status of dkms remove.
cat >"$S/bin/dkms" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf 'dkms %s\n' "$*" >>"$S/log"
case ${1:-} in
    status) cat "$S/dkms-status" 2>/dev/null; exit 0 ;;
    remove) exit "$(cat "$S/dkms-remove-rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
STUB
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$STUB_STATE/log"
[[ ${1:-} == -n ]] && shift
exec "$@"
STUB
cat >"$S/bin/last" <<'STUB'
#!/bin/bash
printf 'last %s\n' "$*" >>"$STUB_STATE/log"
cat "$STUB_STATE/last" 2>/dev/null
exit 0
STUB
cat >"$S/bin/snapper" <<'STUB'
#!/bin/bash
printf 'snapper %s\n' "$*" >>"$STUB_STATE/log"
exit 0
STUB
chmod +x "$S"/bin/*
export PATH=$S/bin:$PATH
export OMARCHY_ASUS_LIMINE_CONF=$S/limine.conf OMARCHY_ASUS_SNAPPER_CONFIG=$S/snapper-root \
    OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_SETUP_TTY=$S/tty \
    OMARCHY_ASUS_DKMS_SRC_ROOT=$S/src OMARCHY_ASUS_DKMS_DISABLED_DIR=$S/disabled
OUT=$S/out
SRC=$S/src/hid-asus-winlock-1

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }
has() { grep -qF -- "$1" "$2"; }
none() { # true when none of the paths exists (unmatched globs stay literal and don't)
    local p
    for p in "$@"; do [[ -e $p || -L $p ]] && return 1; done
    return 0
}
# before A B FILE: the first line of FILE holding A comes before the first one holding B.
before() {
    local a b
    a=$(grep -nF -- "$1" "$3" | head -n1 | cut -d: -f1)
    b=$(grep -nF -- "$2" "$3" | head -n1 | cut -d: -f1)
    [[ -n $a && -n $b ]] && ((a < b))
}

# A quiet fallback kernel (linux at 7.2.8-arch1-1 with headers, a boot entry and an earlier
# boot), so preflight_warnings only has the DKMS source to talk about. No nvidia-open-dkms, so
# the fallback check never asks dkms.
reset() {
    rm -rf "$S/src" "$S/disabled"
    rm -f "$S"/log "$S"/out "$S"/tty "$S"/owner "$S"/krel "$S"/dkms-status "$S"/dkms-remove-rc \
        "$S"/installed "$S"/files.* "$S"/last "$S"/limine.conf "$S"/snapper-root
    printf '[options]\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$S/pacman.conf"
    printf '%s\n' linux linux-headers >"$S/installed"
    printf '/usr/lib/modules/7.2.8-arch1-1/\n/usr/lib/modules/7.2.8-arch1-1/vmlinuz\n' >"$S/files.linux"
    printf '/Arch Linux\n    kernel_path: boot():/abc/linux/vmlinuz-linux\n' >"$S/limine.conf"
    echo 'reboot   system boot  7.2.8-arch1-1    Sat Oct 17 09:00   still running' >"$S/last"
    mkdir -p "$SRC"
    printf '%s\n' 'PACKAGE_NAME="hid-asus-winlock"' 'PACKAGE_VERSION="1"' \
        'BUILT_MODULE_NAME[0]="hid-asus"' 'DEST_MODULE_LOCATION[0]="/updates/dkms"' >"$SRC/dkms.conf"
    printf '// hid-asus with the Win-lock pass-through\n' >"$SRC/hid-asus.c"
    : >"$S/log"
}

# run_fn <dry run 0|1> <force 0|1> <function> [args...]: source the script in a subshell,
# set DRY_RUN and FORCE, call the function; output in $OUT, status in rc.
run_fn() {
    local dry=$1 force=$2
    shift 2
    (
        fn=("$@")
        set --
        # shellcheck source=/dev/null
        OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 source "$W/bin/omarchy-asus-setup"
        # shellcheck disable=SC2034 # read by the sourced functions
        DRY_RUN=$dry FORCE=$force
        "${fn[@]}"
    ) </dev/null >"$OUT" 2>&1
    rc=$?
}

echo "== 1. a kernel that carries 0568: the unowned source is retired"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
echo y >"$S/tty"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "dkms remove ran" has 'dkms remove hid-asus-winlock/1 --all' "$S/log"
check "dkms remove ran before the move" before 'dkms remove hid-asus-winlock/1 --all' 'sudo mv' "$S/log"
check "source moved out of the source root" [ ! -e "$SRC" ]
check "source in the backup dir" [ -f "$S/disabled/hid-asus-winlock-1/dkms.conf" ]
check "source files kept" [ -f "$S/disabled/hid-asus-winlock-1/hid-asus.c" ]
check "shows the undo" has 'undo:' "$OUT"
check "the undo moves it back with sudo mv" has 'sudo mv' "$OUT"
: >"$S/log"
run_fn 0 0 preflight_warnings
check "second run exits 0" [ "$rc" -eq 0 ]
check "second run: no dkms remove" not has 'dkms remove' "$S/log"
check "second run: no sudo" not grep -q '^sudo ' "$S/log"
check "second run: backup untouched" [ -f "$S/disabled/hid-asus-winlock-1/dkms.conf" ]
check "second run: no numbered backup" none "$S"/disabled/*.before-omarchy-asus*

echo "== 2. a backup of that name already exists"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
echo y >"$S/tty"
mkdir -p "$S/disabled/hid-asus-winlock-1"
printf 'older backup\n' >"$S/disabled/hid-asus-winlock-1/old.txt"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "earlier backup kept" [ -f "$S/disabled/hid-asus-winlock-1/old.txt" ]
check "earlier backup not merged into" [ ! -e "$S/disabled/hid-asus-winlock-1/dkms.conf" ]
check "earlier backup holds no nested copy" [ ! -e "$S/disabled/hid-asus-winlock-1/hid-asus-winlock-1" ]
check "source moved to the .before-omarchy-asus name" \
    [ -f "$S/disabled/hid-asus-winlock-1.before-omarchy-asus/dkms.conf" ]
check "source moved out of the source root" [ ! -e "$SRC" ]

echo "== 3. not registered with DKMS"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
: >"$S/dkms-status"
echo y >"$S/tty"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "no dkms remove" not has 'dkms remove' "$S/log"
check "source moved out of the source root" [ ! -e "$SRC" ]
check "source in the backup dir" [ -f "$S/disabled/hid-asus-winlock-1/dkms.conf" ]

echo "== 4. dkms remove fails"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
echo 1 >"$S/dkms-remove-rc"
echo y >"$S/tty"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "dkms remove was tried" has 'dkms remove hid-asus-winlock/1 --all' "$S/log"
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "no sudo mv" not grep -q '^sudo mv ' "$S/log"

echo "== 5. the user says no"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
echo n >"$S/tty"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "no dkms remove" not has 'dkms remove' "$S/log"
check "no sudo runs" not grep -q '^sudo ' "$S/log"
check "'kept' warning" has 'kept' "$OUT"
check "the manual commands" has 'sudo mkdir -p' "$OUT"

echo "== 6. the stock kernel"
reset
echo 7.2.8-9-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0 (no prompt)" [ "$rc" -eq 0 ]
check "no dkms remove" not grep -q '^dkms remove' "$S/log"
check "no sudo runs" not grep -q '^sudo ' "$S/log"
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "today's warning" has 'no package owns' "$OUT"
check "today's dkms remove advice" has 'dkms remove' "$OUT"

echo "== 7. a fallback kernel"
reset
echo 7.2.8-arch1-1 >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0 (no prompt)" [ "$rc" -eq 0 ]
check "no dkms remove" not grep -q '^dkms remove' "$S/log"
check "no sudo runs" not grep -q '^sudo ' "$S/log"
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "today's warning" has 'no package owns' "$OUT"
check "today's dkms remove advice" has 'dkms remove' "$OUT"

echo "== 8. a source a package owns"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
echo hid-asus-winlock-dkms >"$S/owner"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0 (no prompt)" [ "$rc" -eq 0 ]
check "no dkms remove" not grep -q '^dkms remove' "$S/log"
check "no sudo runs" not grep -q '^sudo ' "$S/log"
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "advice to remove the package" has 'pacman -Rns hid-asus-winlock-dkms' "$OUT"

echo "== 9. --dry-run"
reset
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid-asus-winlock/1: added' >"$S/dkms-status"
run_fn 1 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "[dry-run] dkms remove" has '[dry-run] sudo dkms remove hid-asus-winlock/1 --all' "$OUT"
check "[dry-run] move" has '[dry-run] sudo mv' "$OUT"
check "source stays" [ -f "$SRC/dkms.conf" ]
check "nothing in the backup dir" none "$S"/disabled/*
check "no dkms remove ran" not grep -q '^dkms remove' "$S/log"
check "no sudo runs" not grep -q '^sudo ' "$S/log"

echo "== 10. name and version from the directory name"
reset
rm -rf "$SRC"
mkdir -p "$S/src/hid_asus-2.0"
printf '%s\n' 'BUILT_MODULE_NAME[0]="hid-asus"' 'DEST_MODULE_LOCATION[0]="/updates/dkms"' \
    >"$S/src/hid_asus-2.0/dkms.conf"
printf '// hid-asus\n' >"$S/src/hid_asus-2.0/hid-asus.c"
echo 7.2.8-9.1-omarchy >"$S/krel"
echo 'hid_asus/2.0: added' >"$S/dkms-status"
echo y >"$S/tty"
run_fn 0 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "dkms remove hid_asus/2.0" has 'dkms remove hid_asus/2.0 --all' "$S/log"
check "source moved out of the source root" [ ! -e "$S/src/hid_asus-2.0" ]
check "source in the backup dir" [ -f "$S/disabled/hid_asus-2.0/dkms.conf" ]

((fail)) && { echo "FAILED"; cat "$OUT"; exit 1; }
echo "all passed"
exit "$fail"
