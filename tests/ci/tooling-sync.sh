#!/bin/bash
# ci/tooling-sync, offline, in a throwaway git repo with a main and an RC branch:
#   1. same tooling: check passes; recipes may differ
#   2. a tooling change on the RC branch fails, naming the file and the fix
#   3. a file only on the RC branch, one missing there, and a mode change fail
#   4. the excepted kit test may differ
#   5. main moved: apply makes the check pass again, deletions included
# Usage: tests/ci/tooling-sync.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0
check() {
    local name=$1; shift
    if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi
}

R=$S/repo
g() { git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$R/ci" "$R/bin" "$R/tests" "$R/recipes/k"
cp "$W/ci/tooling-sync" "$R/ci/"
printf 'a\n' >"$R/bin/tool"; printf 'p\n' >"$R/tests/test_g16_resume_probe.py"
printf 'pkgrel=1\n' >"$R/recipes/k/PKGBUILD"
g init -q -b main && g add -A && g commit -qm base
g switch -q -c rc
printf 'pkgrel=101\n' >"$R/recipes/k/PKGBUILD"; g commit -qam "rc recipe"

out() { (cd "$R" && ci/tooling-sync check main 2>&1); }
ok() { (cd "$R" && ci/tooling-sync check main >/dev/null 2>&1); }
reset() { g reset -q --hard rc; }

echo "== 1. same tooling"
check "passes with different recipes" ok

echo "== 2. a tooling change on the RC branch"
printf 'b\n' >>"$R/bin/tool"
check "fails" eval '! ok'
o=$(out)
check "names the file" grep -q 'bin/tool' <<<"$o"
check "is a CI error" grep -q '^::error title=Tooling differs from main::' <<<"$o"
check "says to move it to main" grep -q 'move that change to a PR against main' <<<"$o"
check "says how to resync" grep -q "ci/tooling-sync apply origin/main" <<<"$o"
reset

echo "== 3. added, missing, mode"
printf 'x\n' >"$R/ci/extra"; g add ci/extra; check "a file only here fails" grep -q 'ci/extra (not on main)' <<<"$(out)"; reset
rm "$R/bin/tool"; check "a missing file fails" grep -q 'bin/tool (missing here)' <<<"$(out)"; reset
chmod +x "$R/bin/tool"; check "a mode change fails" eval '! ok'; reset

echo "== 4. the excepted kit test"
printf 'rc kit\n' >>"$R/tests/test_g16_resume_probe.py"
check "may differ" ok; reset

echo "== 5. main moved"
g switch -q main
printf 'new\n' >"$R/bin/new"; g rm -q bin/tool; g add -A; g commit -qm "main tooling"
g switch -q rc
check "the RC branch is now behind" eval '! ok'
(cd "$R" && ci/tooling-sync apply main >/dev/null)
check "apply brings the new file" test -f "$R/bin/new"
check "apply removes the deleted one" test ! -e "$R/bin/tool"
check "apply leaves recipes alone" grep -qx 'pkgrel=101' "$R/recipes/k/PKGBUILD"
check "then the check passes" ok

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
