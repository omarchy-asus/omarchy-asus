#!/bin/bash
# bin/sync-release checks its arguments before it syncs anything (#296), offline: the data
# dir and workspace are temp dirs, gh is a stub that records it ran. Each refused case
# asserts exit 2, the usage on stderr, that gh never ran and that the data dir stays empty
# (no lock, journal or prune list: nothing past the argument check):
#   1. -h and --help: the usage on stdout, exit 0
#   2. --nonsense, a --scan-only meant as --pii-scan, a mistyped --chanel rc, --channel
#      with no value, an empty one ("") or an unknown one, --dry-run followed by a stray
#      word: exit 2
#   3. a bare word (a file without --pii-scan): exit 2
#   4. --pii-scan or --pii-scan-text with no files, or with --dry-run: exit 2
#   5. --channel rc --pii-scan FILE still scans (exit 0 on a clean file, gh not run)
# Usage: tests/ci/sync-release-args.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/data" "$S/ws/build"
cat >"$S/bin/gh" <<STUB
#!/bin/bash
: >"$S/ran"
exit 1
STUB
chmod +x "$S/bin/gh"
printf 'nothing to see here\n' >"$S/clean.txt"
printf '# test denylist\nzorbleplex\n' >"$S/denylist"
export PATH=$S/bin:$PATH OMARCHY_ASUS_DATA=$S/data OMARCHY_ASUS_WORKSPACE=$S/ws PII_DENYLIST=$S/denylist
unset OMARCHY_ASUS_CHANNEL PII_SCAN SYNC_ADOPT_REMOTE
fail=0
# run <want exit> <what> [sync-release args]: exit code, usage shown, nothing run or created
run() {
    local want=$1 what=$2 rc; shift 2
    rm -f "$S/ran"
    "$W/bin/sync-release" "$@" >"$S/out" 2>"$S/err"; rc=$?
    local shown=$S/err; ((want == 0)) && shown=$S/out
    if [[ $rc -ne $want ]]; then
        printf 'FAIL: %s: exit %s, want %s\n' "$what" "$rc" "$want"; cat "$S/out" "$S/err"; fail=1
    elif ! grep -q '^Usage: bin/sync-release ' "$shown"; then
        echo "FAIL: $what: no usage on $( ((want == 0)) && echo stdout || echo stderr)"; cat "$S/out" "$S/err"; fail=1
    elif [[ -n $(ls -A "$S/data") || -e $S/ran ]]; then
        echo "FAIL: $what: it went on past the argument check:"; ls -A "$S/data"; fail=1
    else
        echo "ok: $what"
    fi
}

echo "== 1. help"
run 0 "-h prints the usage" -h
run 0 "--help prints the usage" --help
run 0 "--help after --channel rc prints the usage" --channel rc --help

echo "== 2. unknown options"
run 2 "--nonsense is an error" --nonsense
run 2 "--scan-only FILE is an error" --scan-only "$S/clean.txt"
run 2 "a mistyped --chanel rc is an error" --chanel rc
run 2 "--channel with no value is an error" --channel
run 2 "--channel with an empty value is an error" --channel ""
run 2 "--channel with an unknown value is an error" --channel beta
run 2 "--dry-run with a stray word is an error" --dry-run now
run 2 "--channel rc --nonsense is an error" --channel rc --nonsense
grep -q 'unknown option: --nonsense' <("$W/bin/sync-release" --nonsense 2>&1); [[ $? -eq 0 ]] && echo "ok: names the option" || { echo "FAIL: doesn't name the option"; fail=1; }

echo "== 3. a bare argument"
run 2 "a file without --pii-scan is an error" "$S/clean.txt"

echo "== 4. scan mode without files, or with --dry-run"
run 2 "--pii-scan with no files is an error" --pii-scan
run 2 "--pii-scan-text with no files is an error" --pii-scan-text
run 2 "--dry-run --pii-scan is an error" --dry-run --pii-scan "$S/clean.txt"

echo "== 5. a valid scan still runs"
rm -f "$S/ran"
if "$W/bin/sync-release" --channel rc --pii-scan-text "$S/clean.txt" >"$S/out" 2>&1 && [[ ! -e $S/ran ]]; then
    echo "ok: --channel rc --pii-scan-text scans"
else
    echo "FAIL: --channel rc --pii-scan-text did not scan cleanly"; cat "$S/out"; fail=1
fi

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
