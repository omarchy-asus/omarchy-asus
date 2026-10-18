#!/bin/bash
# ci/setup-arch's import_omarchy_key (#116), offline: the script is sourced with
# SETUP_ARCH_SOURCE_ONLY=1, GNUPGHOME is a temp dir, and pacman-key is a stub that appends
# its arguments to a log; --recv-keys succeeds only with STUB_RECV_OK=1 (else the keyserver
# is "down"). No network, no root, no real pacman-key. Needs gpg (skipped without it, but
# not when CI is set).
#   1. the committed key, keyserver down: it is added from ci/omarchy-signing-key.asc and
#      lsigned, the keyserver is never asked
#   2. key_file_fingerprint on the committed file prints exactly OMARCHY_KEY
#   3. the committed file's fingerprint is not OMARCHY_KEY, keyserver down: nothing added,
#      5 keyserver tries, an ::error:: and a non-zero status
#   4. the committed file missing, keyserver up: nothing added, one keyserver try, then lsign
#   5. key_file_fingerprint fails on an empty file
# Usage: tests/ci/setup-arch-omarchy-key.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/gnupg"
chmod 700 "$S/gnupg"
fail=0
KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571

if ! command -v gpg >/dev/null 2>&1; then
    if [[ -n ${CI:-} ]]; then
        echo "not ok - gpg missing"
        exit 1
    fi
    echo "ok # skip gpg missing"
    exit 0
fi

# Without the guard, sourcing would run the whole setup (pacman -Syyuu, useradd...).
if ! grep -q 'SETUP_ARCH_SOURCE_ONLY' "$W/ci/setup-arch"; then
    echo "not ok - ci/setup-arch has no SETUP_ARCH_SOURCE_ONLY guard; not sourcing it"
    exit 1
fi

# Stub: appends "pacman-key <args>" to $LOG (set per case).
cat >"$S/bin/pacman-key" <<'STUB'
#!/bin/bash
printf 'pacman-key %s\n' "$*" >>"$LOG"
if [[ ${1:-} == --recv-keys ]]; then
    [[ ${STUB_RECV_OK:-} == 1 ]] && exit 0
    echo 'No keyserver available' >&2
    exit 1
fi
exit 0
STUB
chmod +x "$S/bin/pacman-key"
export PATH=$S/bin:$PATH
export GNUPGHOME=$S/gnupg
unset STUB_RECV_OK

check() {
    local desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else echo "not ok - $desc"; fail=1; fi
}
not() { ! "$@"; }

# run <case> <OMARCHY_KEY override or ''> <OMARCHY_KEY_FILE override or ''> <STUB_RECV_OK>
# Sets C (case dir), LOG (stub calls), OUT (the function's output) and ST (its status).
run() {
    local key=$2 file=$3 recv=$4
    C=$S/$1 LOG=$S/$1/log OUT=$S/$1/out ST=0
    mkdir -p "$C"
    : >"$LOG"
    export LOG
    (
        set --
        export STUB_RECV_OK=$recv
        # shellcheck source=ci/setup-arch
        SETUP_ARCH_SOURCE_ONLY=1 source "$W/ci/setup-arch"
        # shellcheck disable=SC2034 # read by the sourced functions
        KEYSERVER_RETRY_DELAY=0
        if [[ -n $key ]]; then OMARCHY_KEY=$key; fi
        if [[ -n $file ]]; then OMARCHY_KEY_FILE=$file; fi
        import_omarchy_key
    ) >"$OUT" 2>&1 || ST=$?
}
recv_count() { grep -c '^pacman-key --recv-keys ' "$LOG"; }

echo "== 1. the committed key, keyserver down"
run c1 '' '' 0
check "import_omarchy_key exits 0 (got: $ST)" [ "$ST" -eq 0 ]
check "the committed key is added" grep -qxF "pacman-key --add $W/ci/omarchy-signing-key.asc" "$LOG"
check "the key is lsigned" grep -qxF "pacman-key --lsign-key $KEY" "$LOG"
check "the keyserver is not asked" not grep -q -- '--recv-keys' "$LOG"
check "no warning" not grep -q '::warning::' "$OUT"

echo "== 2. key_file_fingerprint on the committed file"
ST=0
got=$(
    set --
    # shellcheck source=ci/setup-arch
    SETUP_ARCH_SOURCE_ONLY=1 source "$W/ci/setup-arch"
    printf 'want=%s\n' "$OMARCHY_KEY"
    key_file_fingerprint "$OMARCHY_KEY_FILE"
) || ST=$?
want=$(sed -n 's/^want=//p' <<<"$got")
fpr=$(sed '1d' <<<"$got")
check "key_file_fingerprint exits 0 (got: $ST)" [ "$ST" -eq 0 ]
check "OMARCHY_KEY in ci/setup-arch is $KEY (got: $want)" [ "$want" = "$KEY" ]
check "prints exactly OMARCHY_KEY (got: $fpr)" [ "$fpr" = "$want" ]

echo "== 3. fingerprint mismatch, keyserver down"
run c3 0000000000000000000000000000000000000000 '' 0
check "import_omarchy_key fails" [ "$ST" -ne 0 ]
check "nothing added" not grep -q -- '--add' "$LOG"
check "5 keyserver tries (got: $(recv_count))" [ "$(recv_count)" -eq 5 ]
check "no lsign" not grep -q -- '--lsign-key' "$LOG"
check "falls back with a warning" grep -q '::warning::committed Omarchy key' "$OUT"
check "an ::error::" grep -q '::error::' "$OUT"

echo "== 4. the committed file missing, keyserver up"
run c4 '' "$S/none.asc" 1
check "import_omarchy_key exits 0 (got: $ST)" [ "$ST" -eq 0 ]
check "nothing added" not grep -q -- '--add' "$LOG"
check "one keyserver try (got: $(recv_count))" [ "$(recv_count)" -eq 1 ]
check "the try asks for OMARCHY_KEY" grep -qF "pacman-key --recv-keys $KEY --keyserver" "$LOG"
check "then the key is lsigned" [ "$(tail -n1 "$LOG")" = "pacman-key --lsign-key $KEY" ]
check "falls back with a warning" grep -q '::warning::committed Omarchy key' "$OUT"

echo "== 5. key_file_fingerprint on an empty file"
: >"$S/empty.asc"
ST=0
got=$(
    set --
    # shellcheck source=ci/setup-arch
    SETUP_ARCH_SOURCE_ONLY=1 source "$W/ci/setup-arch"
    key_file_fingerprint "$S/empty.asc"
) || ST=$?
check "key_file_fingerprint fails (got: $ST)" [ "$ST" -ne 0 ]
check "prints nothing (got: $got)" [ -z "$got" ]

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
