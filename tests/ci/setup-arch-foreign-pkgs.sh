#!/bin/bash
# ci/setup-arch's sync_snapshot_packages (#429), offline: source ci/setup-arch with
# SETUP_ARCH_SOURCE_ONLY=1 and stub pacman to check that foreign packages absent from
# the snapshot are removed with -Rdd after -Syy and before -Suu, and that no -Rdd runs
# when the base image has no foreign packages.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin"
fail=0

cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
printf 'pacman %s\n' "$*" >>"$LOG"
if [[ ${1:-} == -Qmq ]]; then
    if [[ -n ${STUB_FOREIGN:-} ]]; then
        printf '%s\n' $STUB_FOREIGN
        exit 0
    fi
    exit 1
fi
exit 0
STUB
chmod +x "$S/bin/pacman"
export PATH=$S/bin:$PATH

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }

run() {
    local name=$1 foreign=$2
    shift 2
    LOG=$S/$name.log OUT=$S/$name.out ST=0
    : >"$LOG"
    export LOG
    (
        set --
        export STUB_FOREIGN=$foreign
        # shellcheck source=ci/setup-arch
        SETUP_ARCH_SOURCE_ONLY=1 source "$W/ci/setup-arch"
        sync_snapshot_packages "$@"
    ) >"$OUT" 2>&1 || ST=$?
}

echo "== 1. foreign package in base image (e.g. openssl-3)"
run c1 "openssl-3"
check "sync_snapshot_packages exits 0 (got: $ST)" [ "$ST" -eq 0 ]
check "syncs databases first" grep -qxF "pacman -Syy --noconfirm --noprogressbar" <(sed -n 1p "$LOG")
check "queries foreign packages second" grep -qxF "pacman -Qmq" <(sed -n 2p "$LOG")
check "removes foreign packages with -Rdd third" grep -qxF "pacman -Rdd --noconfirm --noprogressbar openssl-3" <(sed -n 3p "$LOG")
check "runs -Suu fourth" grep -qxF "pacman -Suu --noconfirm --needed --noprogressbar omarchy-keyring base-devel devtools" <(sed -n 4p "$LOG")

echo "== 2. no foreign packages in base image, extra package passed"
LOG=$S/c2.log OUT=$S/c2.out ST=0
: >"$LOG"
export LOG
(
    export STUB_FOREIGN=""
    # shellcheck source=ci/setup-arch
    SETUP_ARCH_SOURCE_ONLY=1 source "$W/ci/setup-arch"
    sync_snapshot_packages dkms
) >"$OUT" 2>&1 || ST=$?
check "sync_snapshot_packages exits 0 (got: $ST)" [ "$ST" -eq 0 ]
check "does not run -Rdd" not grep -q -- "-Rdd" "$LOG"
check "passes extra package to -Suu" grep -qxF "pacman -Suu --noconfirm --needed --noprogressbar omarchy-keyring base-devel devtools dkms" "$LOG"

exit "$fail"
