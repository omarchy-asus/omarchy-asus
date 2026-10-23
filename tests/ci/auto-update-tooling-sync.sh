#!/bin/bash
# bin/auto-update keeps the RC branch's tooling main's (ci/tooling-sync, #201). The real
# bin/auto-update, bin/env.sh and bin/auto-update-state make full --channel rc runs as this
# user against a local origin (main and next/omarchy-4.5), a stub check-upstream (nothing to
# do), a stub PII scan and a fake gh that logs what it is asked (and, like gh on a branch
# without required checks, fails "pr checks --required"):
#   1. the RC branch matches main: no PR
#   2. main's tooling moves: one "Tooling from main <sha>" PR with main's tooling and the
#      RC recipes as they were
#   3. its checks pending: it waits (no push, no merge)
#   4. its checks failing: attention, it stays open
#   5. its checks green: merged at its head commit
#   6. main moves again: the branch is rebuilt and the PR retitled
#   7. the RC branch caught up some other way: the open PR is closed
# Offline: no network, no sudo, no bwrap.
set -u
for t in jq python3 flock column git; do
    command -v "$t" >/dev/null && continue
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(realpath "$(mktemp -d)")
trap 'rm -rf "$T"' EXIT
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected '$3', got '$2'"; fails=1; fi
}

L=$T/lib/bin D=$T/data CONF=$T/auto-update.conf O=$T/origin.git S=$T/seed FB=$T/fakebin
mkdir -p "$L" "$D" "$FB"
cp "$W/bin/auto-update" "$W/bin/env.sh" "$W/bin/auto-update-state" "$L/"
cat >"$L/recipe-sandbox" <<'STUB'
#!/bin/bash
while (($#)) && [[ $1 != -- ]]; do shift; done
shift; exec "$@"
STUB
printf '#!/bin/bash\necho %s\n' "'{\"packages\": [], \"prs\": []}'" >"$L/check-upstream"
printf '#!/bin/bash\n[[ $1 == --pii-scan-text ]] && exit 0\nexit 1\n' >"$L/sync-release"
# gh: "pr list" prints the open PR's url ($T/pr), "pr checks" exits $T/checks-rc
cat >"$FB/gh" <<STUB
#!/bin/bash
echo "\$*" >>"$T/gh.log"
case "\$1 \$2" in
    "pr list") cat "$T/pr" 2>/dev/null; true ;;
    "pr create") echo https://github.test/pr/1 | tee "$T/pr" ;;
    "pr checks")
        # as gh does on a branch without required checks (the RC branch)
        [[ " \$* " == *" --required "* ]] && { echo "no required checks reported" >&2; exit 1; }
        exit "\$(cat "$T/checks-rc" 2>/dev/null || echo 8)" ;;
    "pr close"|"pr merge") rm -f "$T/pr" ;;
    "auth git-credential") exit 1 ;;
esac
STUB
chmod +x "$L"/* "$FB/gh"
export PATH=$FB:$PATH OMARCHY_ASUS_DATA=$D
printf 'GIT_URL=%s\nBUILD_USER=%s\n' "$O" "$(id -un)" >"$CONF"

sg() { git -C "$S" -c user.name=t -c user.email=t@t "$@"; }
git init -q --bare "$O"
mkdir -p "$S/ci" "$S/bin" "$S/recipes/k"
cp "$W/ci/tooling-sync" "$S/ci/"
printf 'v1\n' >"$S/bin/tool"; printf 'pkgrel=1\n' >"$S/recipes/k/PKGBUILD"
git -C "$S" init -q -b main && sg add -A && sg commit -qm base && sg remote add origin "$O"
sg push -q origin main
sg switch -q -c next/omarchy-4.5; printf 'pkgrel=101\n' >"$S/recipes/k/PKGBUILD"; sg commit -qam rc
sg push -q origin next/omarchy-4.5
BR=auto-update-rc/tooling-from-main

run() {  # one full RC run; its output in $T/out
    : >"$T/gh.log"
    "$L/auto-update" --channel rc --config "$CONF" >"$T/out" 2>&1; echo $? >"$T/rc"
}
main_moves() { sg switch -q main; printf '%s\n' "$1" >"$S/bin/tool"; sg commit -qam "main $1"; sg push -q origin main; }
on_origin() { git --git-dir="$O" show "$1" 2>/dev/null; }
has() { if grep -qF -- "$1" "$2"; then echo yes; else echo no; fi; }

echo "== 1. matching"
run
expect "1. says it matches" "$(has "next/omarchy-4.5's tooling matches main" "$T/out")" yes
expect "1. no PR" "$(has "pr create" "$T/gh.log")" no

echo "== 2. main moves"
main_moves v2; M=$(git -C "$S" rev-parse --short main)
run
expect "2. one PR opened" "$(grep -c "^pr create" "$T/gh.log")" 1
expect "2. titled with main's sha" "$(has "--title Tooling from main $M" "$T/gh.log")" yes
expect "2. against the RC branch" "$(has "--base next/omarchy-4.5 --head $BR" "$T/gh.log")" yes
expect "2. the branch carries main's tooling" "$(on_origin "$BR:bin/tool")" v2
expect "2. and the RC recipe as it was" "$(on_origin "$BR:recipes/k/PKGBUILD")" pkgrel=101
expect "2. the RC branch itself untouched" "$(on_origin "next/omarchy-4.5:bin/tool")" v1
H=$(git --git-dir="$O" rev-parse "$BR")

echo "== 3. checks pending"
echo 8 >"$T/checks-rc"; run
expect "3. waits" "$(has "waits for its checks" "$T/out")" yes
expect "3. no merge" "$(has "pr merge" "$T/gh.log")" no
expect "3. no new push" "$(git --git-dir="$O" rev-parse "$BR")" "$H"

echo "== 4. checks failing"
echo 1 >"$T/checks-rc"; run
expect "4. attention" "$(has "has failing checks" "$T/out")" yes
expect "4. no merge" "$(has "pr merge" "$T/gh.log")" no

echo "== 5. checks green"
echo 0 >"$T/checks-rc"; run
expect "5. merged at its head" "$(has "pr merge https://github.test/pr/1 -R omarchy-asus/omarchy-asus --squash --delete-branch --admin --match-head-commit $H" "$T/gh.log")" yes

echo "== 6. main moves again under an open PR"
echo https://github.test/pr/1 >"$T/pr"; echo 8 >"$T/checks-rc"
main_moves v3; M=$(git -C "$S" rev-parse --short main)
run
expect "6. rebuilt with v3" "$(on_origin "$BR:bin/tool")" v3
expect "6. retitled" "$(has "pr edit https://github.test/pr/1 -R omarchy-asus/omarchy-asus --title Tooling from main $M" "$T/gh.log")" yes
expect "6. no second PR" "$(has "pr create" "$T/gh.log")" no

echo "== 7. the RC branch caught up"
sg switch -q next/omarchy-4.5; git -C "$S" checkout -q main -- bin/tool; sg commit -qm sync; sg push -q origin next/omarchy-4.5
run
expect "7. the open PR closed" "$(has "pr close https://github.test/pr/1" "$T/gh.log")" yes

((fails)) && { echo "FAILED"; cat "$T/out"; exit 1; }
echo "all passed"
