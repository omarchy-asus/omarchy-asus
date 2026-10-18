#!/bin/bash
# bin/omarchy-asus-setup checks the way back (#85), offline: the script is sourced with
# OMARCHY_ASUS_SETUP_SOURCE_ONLY=1, the boot menu and the snapper config are temp files, and
# pacman, dkms, last, sudo, snapper, omarchy and omarchy-update are stubs driven by state files.
#   1. a fallback kernel with no headers, no NVIDIA DKMS build, no Limine entry and no boot
#      record: preflight_warnings warns about each
#   2. a fallback kernel with all four: no warning; for linux-lts the vmlinuz-linux entry
#      does not count
#   3. --dry-run, no snapper config: offer_upgrade refuses, omarchy update is not run
#   4. same with --force: a warning, and the upgrade goes on
#   5. --dry-run with a snapper config: the snapshot command is shown, the upgrade goes on
#   6. a real run: the new snapshot is missing from snapper list, so the upgrade is refused;
#      once it is listed, omarchy update runs
# Usage: tests/ci/setup-way-back.sh [keep]   (keep: leave the temp dir for inspection)
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
# installed: one package name per line; files.<pkg>: its pacman -Qlq; updates: pacman -Qu.
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf 'pacman %s\n' "$*" >>"$S/log"
case $1 in
    -Q) grep -qxF "$2" "$S/installed" 2>/dev/null || exit 1; echo "$2 1-1" ;;
    -Qlq) cat "$S/files.$2" 2>/dev/null || exit 1 ;;
    -Qu) cat "$S/updates" 2>/dev/null; exit 0 ;;
    -Slq) exit 0 ;;
    *) exit 1 ;;
esac
STUB
cat >"$S/bin/dkms" <<'STUB'
#!/bin/bash
cat "$STUB_STATE/dkms-status" 2>/dev/null
exit 0
STUB
cat >"$S/bin/last" <<'STUB'
#!/bin/bash
cat "$STUB_STATE/last" 2>/dev/null
exit 0
STUB
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$STUB_STATE/log"
[[ ${1:-} == -n ]] && shift
exec "$@"
STUB
# snap-num: what create prints (missing: create fails); snap-listed: the number list shows.
cat >"$S/bin/snapper" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf 'snapper %s\n' "$*" >>"$S/log"
case " $* " in
    *" create "*) [[ -f $S/snap-num ]] || exit 1; cat "$S/snap-num" ;;
    *" list "*)
        # The script asks for --csvout --columns number; anything else gets the table,
        # which the script must not try to parse.
        if [[ " $* " == *" --csvout "* && " $* " == *" --columns number "* ]]; then
            printf '%s\n' number 0 142
            [[ -f $S/snap-listed ]] && cat "$S/snap-listed"
        else
            echo ' # │ Type   │ Pre # │ Date                     │ Description'
            echo '───┼────────┼───────┼──────────────────────────┼────────────'
            echo '0  │ single │       │                          │ current'
            [[ -f $S/snap-listed ]] && printf '%s  │ single │       │ Sun 18 Oct 2026 10:05:00 │ before omarchy-asus\n' "$(cat "$S/snap-listed")"
        fi
        ;;
esac
exit 0
STUB
cat >"$S/bin/omarchy-update" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$S/bin/omarchy" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_STATE/omarchy.log"
exit 0
STUB
chmod +x "$S"/bin/*
export PATH=$S/bin:$PATH
export OMARCHY_ASUS_LIMINE_CONF=$S/limine.conf OMARCHY_ASUS_SNAPPER_CONFIG=$S/snapper-root \
    OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_SETUP_TTY=$S/tty
OUT=$S/out

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }
has() { grep -qF -- "$1" "$2"; }

reset() {
    rm -f "$S"/log "$S"/omarchy.log "$S"/installed "$S"/files.* "$S"/updates "$S"/dkms-status "$S"/last \
        "$S"/limine.conf "$S"/snapper-root "$S"/snap-num "$S"/snap-listed "$S"/tty
    printf '[options]\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$S/pacman.conf"
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

# A linux kernel package at release 7.2.8-arch1-1, and linux-lts at 6.12.50-1-lts.
kernel_files() {
    printf '/usr/lib/modules/7.2.8-arch1-1/\n/usr/lib/modules/7.2.8-arch1-1/vmlinuz\n' >"$S/files.linux"
    printf '/usr/lib/modules/6.12.50-1-lts/\n/usr/lib/modules/6.12.50-1-lts/vmlinuz\n' >"$S/files.linux-lts"
}

echo "== 1. a fallback kernel that is no way back"
reset
kernel_files
printf '%s\n' linux nvidia-open-dkms >"$S/installed"
echo 'nvidia/615.78.08, 7.1.0-arch1-1, x86_64: installed' >"$S/dkms-status"
printf '/Arch Linux\n    kernel_path: boot():/abc/linux-omarchy/vmlinuz-linux-omarchy\n' >"$S/limine.conf"
: >"$S/last"
run_fn 1 0 preflight_warnings
check "preflight_warnings exits 0" [ "$rc" -eq 0 ]
check "mentions linux-headers" grep -q 'warning:.*linux-headers is not installed' "$OUT"
check "mentions the DKMS nvidia build" grep -q 'warning:.*no DKMS nvidia build is installed for linux (7\.2\.8-arch1-1)' "$OUT"
check "mentions the Limine entry" grep -q 'warning:.*Limine has no entry for linux ' "$OUT"
check "mentions that it never booted" grep -q 'warning:.*linux (7\.2\.8-arch1-1) has never booted' "$OUT"
check "no all-good line" not has 'earlier boot found' "$OUT"

echo "== 2. a fallback kernel that is a way back"
reset
kernel_files
printf '%s\n' linux linux-headers linux-lts linux-lts-headers nvidia-open-dkms >"$S/installed"
printf '%s\n' 'nvidia/615.78.08, 7.2.8-arch1-1, x86_64: installed' \
    'nvidia/615.78.08, 6.12.50-1-lts, x86_64: installed' >"$S/dkms-status"
printf '/Arch Linux\n    kernel_path: boot():/abc/linux/vmlinuz-linux\n' >"$S/limine.conf"
printf '%s\n' 'reboot   system boot  7.2.8-arch1-1    Sat Oct 17 09:00   still running' \
    'reboot   system boot  6.12.50-1-lts    Fri Oct 16 09:00 - 10:00  (01:00)' >"$S/last"
run_fn 1 0 check_fallback_kernel linux
check "check_fallback_kernel exits 0" [ "$rc" -eq 0 ]
check "no warnings for linux" not has 'warning:' "$OUT"
check "all-good line for linux" has 'linux 7.2.8-arch1-1: headers, NVIDIA DKMS build, boot entry and an earlier boot found' "$OUT"
run_fn 1 0 check_fallback_kernel linux-lts
check "linux-lts: vmlinuz-linux is not its entry" grep -q 'warning:.*Limine has no entry for linux-lts ' "$OUT"
check "linux-lts: no other warning" [ "$(grep -c 'warning:' "$OUT")" -eq 1 ]
check "linux-lts: no all-good line" not has 'earlier boot found' "$OUT"
# The boot menu readable only through sudo -n (the sudo stub serves it from elsewhere).
mv "$S/limine.conf" "$S/limine.real"
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$STUB_STATE/log"
[[ ${1:-} == -n ]] && shift
if [[ $1 == cat && $2 == "$STUB_STATE/limine.conf" ]]; then exec cat "$STUB_STATE/limine.real"; fi
exec "$@"
STUB
run_fn 1 0 check_fallback_kernel linux
check "unreadable boot menu read with sudo -n" grep -qF "sudo -n cat $S/limine.conf" "$S/log"
check "no warnings through sudo -n" not has 'warning:' "$OUT"
mv "$S/limine.real" "$S/limine.conf"

echo "== 3. --dry-run, no snapper config"
reset
run_fn 1 0 offer_upgrade
check "offer_upgrade exits 0" [ "$rc" -eq 0 ]
check "says no snapshot can be taken" grep -q 'warning:.*snapper has no root config' "$OUT"
check "says not upgraded" grep -q 'warning:.*not upgraded: without a snapshot' "$OUT"
check "no [dry-run] omarchy update" not has '[dry-run] omarchy update' "$OUT"

echo "== 4. --dry-run --force, no snapper config"
reset
run_fn 1 1 offer_upgrade
check "offer_upgrade exits 0" [ "$rc" -eq 0 ]
check "the --force warning" grep -q 'warning:.*upgrading anyway because of --force' "$OUT"
check "[dry-run] omarchy update" has '[dry-run] omarchy update' "$OUT"

echo "== 5. --dry-run with a snapper config"
reset
: >"$S/snapper-root"
run_fn 1 0 offer_upgrade
check "offer_upgrade exits 0" [ "$rc" -eq 0 ]
check "[dry-run] snapper create" has "[dry-run] sudo snapper -c root create -c number -d 'before omarchy-asus' --print-number" "$OUT"
check "[dry-run] omarchy update" has '[dry-run] omarchy update' "$OUT"
check "snapper did not run" not grep -q '^snapper ' "$S/log"

echo "== 6. a real run"
reset
: >"$S/snapper-root"
echo 'linux-omarchy 7.2.8-1 -> 7.2.8-2' >"$S/updates"
echo y >"$S/tty"
echo 42 >"$S/snap-num"
run_fn 0 0 offer_upgrade
check "offer_upgrade exits 0" [ "$rc" -eq 0 ]
check "snapper create ran through sudo" grep -q '^sudo snapper -c root create' "$S/log"
check "says the snapshot is missing" grep -q 'warning:.*snapshot 42 does not appear in snapper list' "$OUT"
check "says not upgraded" grep -q 'warning:.*not upgraded: without a snapshot' "$OUT"
check "omarchy update never ran" [ ! -e "$S/omarchy.log" ]
echo 42 >"$S/snap-listed"
: >"$S/log"
run_fn 0 0 offer_upgrade
check "offer_upgrade exits 0" [ "$rc" -eq 0 ]
check "says the snapshot was taken" has 'snapshot 42 taken (before omarchy-asus)' "$OUT"
check "no refusal" not has 'not upgraded' "$OUT"
check "omarchy update ran" grep -qx update "$S/omarchy.log"
# snapper create fails outright.
rm -f "$S/snap-num" "$S/omarchy.log"
run_fn 0 0 offer_upgrade
check "create fails: says not upgraded" grep -q 'warning:.*not upgraded: without a snapshot' "$OUT"
check "create fails: omarchy update never ran" [ ! -e "$S/omarchy.log" ]

((fail)) && { echo "FAILED"; cat "$OUT"; exit 1; }
echo "all passed"
