#!/bin/bash
# The release build (.github/workflows/release.yml) and its guards, offline:
#   1. ci/release-plan, in a throwaway repo: main only, rc only (Quattro frozen, #309),
#      no linux-omarchy, no held recipe, no unknown or missing recipe; the plan it prints
#   2. the workflow: dispatch only; every job after the plan skipped off main; the build
#      step holds no token (tests/ci/build-recipe-no-secrets.sh has the rest); id-token and
#      attestations only in the attest job, which runs no recipe code; the attest action
#      pinned by commit; nothing signs, publishes or uploads to a release
#   3. ci/release-check on fake packages, with gh stubbed: manifest, pkgrel range, release
#      cohorts, one file per name
# Usage: tests/ci/release-workflow.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
WF=$W/.github/workflows/release.yml
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0
check() {
    local name=$1; shift
    if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi
}
has() { grep -qF -- "$1" <<<"$2"; }

echo "== 1. ci/release-plan"
R=$S/repo
mkdir -p "$R/ci" "$R/bin" "$R/build"
cp "$W/ci/release-plan" "$R/ci/"; cp "$W/bin/release-cohort" "$R/bin/"
: >"$R/build/cohorts.conf"
for r in a b linux-omarchy nvidia-open-dkms held; do
    mkdir -p "$R/recipes/$r"; printf 'pkgname=%s\npkgver=1\npkgrel=101\n' "$r" >"$R/recipes/$r/PKGBUILD"
done
printf '# why\nwaits for upstream fix\n' >"$R/recipes/held/HOLD"
mkdir -p "$R/recipes/docs-only"
plan() { "$R/ci/release-plan" "$@" 2>&1; }

out=$(plan refs/heads/main rc "b a recipes/a/"); rc=$?
check "main, rc, two recipes: exit 0" test "$rc" = 0
check "recipes sorted and de-duplicated" grep -qx 'recipes=\["a", "b"\]' <<<"$out"
check "channel=rc" grep -qx 'channel=rc' <<<"$out"
check "nvidia=false" grep -qx 'nvidia=false' <<<"$out"
check "nvidia-open-dkms: nvidia=true" grep -qx 'nvidia=true' <<<"$(plan refs/heads/main rc nvidia-open-dkms)"

out=$(plan refs/heads/feature rc a); rc=$?
check "another branch: refused" test "$rc" = 1
check "another branch: says main only" has "release builds run from main only, not refs/heads/feature" "$out"
check "another branch: no plan printed" bash -c '! grep -q "^recipes=" <<<"$1"' _ "$out"
out=$(plan refs/tags/x rc a); rc=$?
check "a tag: refused" test "$rc" = 1
out=$(plan refs/heads/main quattro a); rc=$?
check "quattro: refused" test "$rc" = 1
check "quattro: says frozen (#309)" has "Quattro channel is frozen (#309)" "$out"
out=$(plan refs/heads/main stable a); rc=$?
check "unknown channel: refused" test "$rc" = 1
out=$(plan refs/heads/main rc "a linux-omarchy"); rc=$?
check "kernel: refused, even next to another recipe" test "$rc" = 1
check "kernel: says the build host's runner" has "linux-omarchy does not build here" "$out"
out=$(plan refs/heads/main rc held); rc=$?
check "held recipe: refused" test "$rc" = 1
check "held recipe: gives the hold's reason" has "recipes/held is held: waits for upstream fix" "$out"
out=$(plan refs/heads/main rc docs-only); rc=$?
check "no PKGBUILD: refused" test "$rc" = 1
check "no PKGBUILD: says no such recipe" has "no such recipe: docs-only" "$out"
out=$(plan refs/heads/main rc "../a"); rc=$?
check "a path outside recipes/: refused" test "$rc" = 1
out=$(plan refs/heads/main rc ""); rc=$?
check "no recipe: refused" test "$rc" = 1
check "no recipe: says so" has "no recipe to build" "$out"

echo "== 2. the workflow"
code=$(grep -v -E '^[[:space:]]*#' "$WF")
# top-level keys of on:
triggers=$(awk '/^on:/ { on = 1; next } on && /^[^ ]/ { on = 0 } on && /^  [a-z_]+:/ { sub(/:.*/, ""); sub(/^ +/, ""); print }' "$WF")
check "triggered by workflow_dispatch only" test "$triggers" = workflow_dispatch
check "no default permissions" grep -qx 'permissions: {}' "$WF"
# job name -> its block
jobs=$(awk '/^jobs:/ { j = 1; next } j && /^  [a-z][a-z0-9_-]*:$/ { sub(/:$/, ""); sub(/^ +/, ""); print }' "$WF")
job() { awk -v j="$1" '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z][a-z0-9_-]*:$/ { cur = $1; sub(/:$/, "", cur) } in_jobs && cur == j' "$WF"; }
check "jobs: plan build check nvidia-compat attest result" \
    test "$(tr '\n' ' ' <<<"$jobs")" = "plan build check nvidia-compat attest result "
for j in $jobs; do
    [[ $j == plan || $j == result ]] && continue
    check "$j: skipped off main (job-level if)" \
        grep -qE "^    if: github\.ref == 'refs/heads/main'( &&|$)" <<<"$(job "$j")"
    check "$j: needs plan" grep -qE '^    needs: (plan|\[plan,)' <<<"$(job "$j")"
done
check "plan: ci/release-plan gets github.ref" \
    bash -c 'grep -q "REF: \${{ github.ref }}" <<<"$1" && grep -q "ci/release-plan \"\$REF\" \"\$CHANNEL\"" <<<"$1"' _ "$(job plan)"
check "result: fails unless plan, build, check and attest passed" \
    grep -qF 'for r in "$PLAN" "$BUILD" "$CHECK" "$ATTEST"' <<<"$(job result)"
check "build: runs on ubuntu-24.04" grep -q 'runs-on: ubuntu-24.04' <<<"$(job build)"
check "build: no token in the job (no github.token, no actions: read)" \
    bash -c '! grep -qE "github\.token|GH_TOKEN|actions: read" <<<"$1"' _ "$(job build)"
check "build: a release build (--release: the release chroot's packager)" \
    grep -qF '/repo/ci/build-recipe --channel "$CHANNEL" --release "$RECIPE"' <<<"$(job build)"
check "ci/build-recipe reads the packager from bin/env.sh" \
    test "$(sed -n "s/^PACKAGER_LINE='\\(PACKAGER=.*\\)'$/\\1/p" "$W/bin/env.sh")" = 'PACKAGER="omarchy-asus"'
check "ci/build-recipe: an unknown option is a usage error" \
    bash -c 'env -u GITHUB_TOKEN -u GH_TOKEN -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_TOKEN bash "$1" --nope x >/dev/null 2>&1; test $? = 2' _ "$W/ci/build-recipe"
check "build: uploads SHA256SUMS with the packages" grep -q 'out/SHA256SUMS' <<<"$(job build)"
check "build: -debug packages left out before the manifest" grep -qF 'out/*-debug-*.pkg.tar.zst' <<<"$(job build)"
for p in 'id-token:' 'attestations:'; do
    check "$p only in the attest job" \
        test "$(for j in $jobs; do grep -q "$p" <<<"$(job "$j")" && echo "$j"; done | tr '\n' ' ')" = "attest "
done
a=$(job attest | grep -v -E '^[[:space:]]*#')
check "attest: no checkout, container or recipe code" \
    bash -c '! grep -qE "actions/checkout|docker|build-recipe|makepkg|nvidia-compat|recipes/" <<<"$1"' _ "$a"
check "attest: attest-build-provenance pinned by commit" \
    grep -qE 'uses: actions/attest-build-provenance@[0-9a-f]{40} # v' <<<"$a"
check "every action pinned by commit" \
    bash -c '! grep -E "uses: " <<<"$1" | grep -vqE "uses: [^@ ]+@[0-9a-f]{40}( |$)"' _ "$code"
check "no secrets" bash -c '! grep -qE "(^|[^-A-Za-z0-9_])secrets[.[]" <<<"$1"' _ "$code"
check "nothing signs, publishes or uploads to a release" \
    bash -c '! grep -qE "gh release|bin/publish|bin/sync-release|bin/build-pkg|gpg|repo-add|--sign|contents: write|packages: write" <<<"$1"' _ "$code"

echo "== 3. ci/release-check"
if ! bsdtar --version >/dev/null 2>&1 || ! (cd "$S" && printf 'x' >z && bsdtar --zstd -cf z.tar.zst z 2>/dev/null); then
    if [[ -n ${CI:-} ]]; then echo "not ok - bsdtar with zstd is needed"; exit 1; fi
    echo "skip - no bsdtar with zstd here"
    ((fail)) && { echo "FAILED"; exit 1; }
    echo "all passed"; exit 0
fi
P=$S/pkgs STUB=$S/stub
mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/bin/bash
# gh release view <tag> -R <repo> --json assets --jq ...: the stub's <tag>.tsv
[[ $1 == release && $2 == view ]] || exit 1
f=$GH_STUB/$3.tsv
[[ -f $f ]] || { echo "release not found" >&2; exit 1; }
cat "$f"
EOF
chmod +x "$STUB/gh"
mkpkg() { # dir name ver-rel
    local d=$P/$1 t; t=$(mktemp -d)
    mkdir -p "$d"
    printf 'pkgname = %s\npkgver = %s\n' "$2" "$3" >"$t/.PKGINFO"
    (cd "$t" && bsdtar --zstd -cf "$d/$2-$3-any.pkg.tar.zst" .PKGINFO)
    rm -rf "$t"
}
manifest() { (cd "$P/$1" && sha256sum -- *.pkg.tar.zst >SHA256SUMS); }
db() { # name-ver-rel...: a repo db holding those entries
    local t; t=$(mktemp -d)
    for e; do mkdir -p "$t/$e"; printf '%%NAME%%\n%s\n' "${e%-*-*}" >"$t/$e/desc"; done
    (cd "$t" && bsdtar -czf "$S/db.tar.gz" --exclude . -- * 2>/dev/null || bsdtar -czf "$S/db.tar.gz" -T /dev/null)
    rm -rf "$t"
}
cp "$W/build/cohorts.conf" "$S/cohorts.conf"
rcheck() {
    PATH=$STUB:$PATH GH_STUB=$STUB RELEASE_CHECK_DB=$S/db.tar.gz \
        "$W/ci/release-check" --channel rc "$P" 2>&1
}
reset() { rm -rf "$P" "$STUB"/*.tsv; mkdir -p "$P"; db; }

reset; mkpkg release-rc-a a 1-101; manifest release-rc-a
out=$(rcheck); rc=$?
check "rc pkgrel, no release has it: passes" test "$rc" = 0
check "says all passed" has "all release checks passed" "$out"

reset; mkpkg release-rc-a a 1-1; manifest release-rc-a
out=$(rcheck); rc=$?
check "Quattro pkgrel on rc: fails" test "$rc" = 1
check "Quattro pkgrel: says why" has "in Quattro's range" "$out"

reset; mkpkg release-rc-a a 1-101; manifest release-rc-a; mkpkg release-rc-a a2 1-101
out=$(rcheck); rc=$?
check "a package missing from SHA256SUMS: fails" test "$rc" = 1
reset; mkpkg release-rc-a a 1-101; manifest release-rc-a; printf 'x' >>"$P/release-rc-a/a-1-101-any.pkg.tar.zst"
out=$(rcheck); rc=$?
check "a package that changed after the manifest: fails" test "$rc" = 1
reset; mkpkg release-rc-a a 1-101
out=$(rcheck); rc=$?
check "no SHA256SUMS: fails" test "$rc" = 1

reset; mkpkg release-rc-a a 1-101; manifest release-rc-a
printf 'a-1-101-any.pkg.tar.zst\t10\tsha256:%064d\n' 0 >"$STUB/rc-x86_64.tsv"
out=$(rcheck); rc=$?
check "the rc release has other bytes by that name: fails" test "$rc" = 1
check "other bytes: says bump pkgrel" has "already serves a different file by this name: bump pkgrel" "$out"
reset; mkpkg release-rc-a a 1-101; manifest release-rc-a
printf 'a-1-101-any.pkg.tar.zst\t10\t\n' >"$STUB/x86_64.tsv"
out=$(rcheck); rc=$?
check "the Quattro release has it with no digest: fails" test "$rc" = 1
reset; mkpkg release-rc-a a 1-101; manifest release-rc-a
printf 'a-1-101-any.pkg.tar.zst\t10\tsha256:%s\n' "$(sha256sum "$P/release-rc-a/a-1-101-any.pkg.tar.zst" | cut -d' ' -f1)" >"$STUB/rc-x86_64.tsv"
out=$(rcheck); rc=$?
check "the release has the same bytes: passes" test "$rc" = 0

reset; mkpkg release-rc-omarchy omarchy 3-101; manifest release-rc-omarchy
out=$(rcheck); rc=$?
check "omarchy without omarchy-settings: fails (release cohort)" test "$rc" = 1
check "cohort: says so" has "release cohort member would ship without its partner" "$out"
reset; db omarchy-settings-3-101; mkpkg release-rc-omarchy omarchy 3-101; manifest release-rc-omarchy
out=$(rcheck); rc=$?
check "omarchy next to the published omarchy-settings at its version: passes" test "$rc" = 0
reset; mkpkg release-rc-omarchy omarchy 3-101; manifest release-rc-omarchy
mkpkg release-rc-omarchy-settings omarchy-settings 3-101; manifest release-rc-omarchy-settings
out=$(rcheck); rc=$?
check "omarchy and omarchy-settings built together: passes" test "$rc" = 0

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
