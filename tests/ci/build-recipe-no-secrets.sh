#!/bin/bash
# ci/build-recipe runs `makepkg -s` on recipe code outside bin/recipe-sandbox (#79, #89):
# that is only safe while the CI build step holds no secrets. This keeps the reasons
# in the ci/build-recipe header true: a pull_request workflow (never
# pull_request_target), no -e/--env/--privileged/docker socket/seccomp on the
# `docker run ... ci/build-recipe` lines, checkout without persisted credentials, no
# secrets.* reference, no token in the build steps' env, and ci/build-recipe itself
# refusing to run with a token in its environment. Offline: plain grep/awk on the
# workflow, and ci/build-recipe on a recipe that does not exist (it stops at the
# guard or at the PKGBUILD check, before ci/setup-arch touches anything).
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
WF=$W/.github/workflows/build-pr.yml
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
TOKENS=(GITHUB_TOKEN GH_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN)
unset_tokens=()
for v in "${TOKENS[@]}"; do unset_tokens+=(-u "$v"); done

# a. never pull_request_target (fork PRs would get secrets and a write token)
expect "a: no pull_request_target in build-pr.yml" \
    "$(grep -c 'pull_request_target' "$WF")" 0

# b. the docker run lines that start ci/build-recipe, backslash continuations joined,
# YAML/shell comment lines skipped
runs=$(awk '/^[[:space:]]*#/ { next }
    { line = acc $0
      if (line ~ /\\$/) { sub(/\\$/, "", line); acc = line " "; next }
      acc = ""; print line }' "$WF" | grep 'docker run' | grep 'ci/build-recipe')
expect "b: two docker run lines start ci/build-recipe (build and kernel jobs)" \
    "$(printf '%s\n' "$runs" | grep -c 'ci/build-recipe')" 2
expect "b: those docker runs pass no env, privilege, docker socket or seccomp change" \
    "$(printf '%s\n' "$runs" | grep -c -F -e ' -e ' -e '--env' -e '--privileged' -e 'docker.sock' -e 'seccomp')" 0
expect "b: the kernel run's continuation was joined (its image and script are on one line)" \
    "$(printf '%s\n' "$runs" | grep -c 'docker run.*"\$DIR/work:/build".*ci/build-recipe --channel "\$CHANNEL" linux-omarchy')" 1
# The channel reaches the container as an argument, not through its environment (#168).
expect "b: both docker runs pass the PR's channel to ci/build-recipe" \
    "$(printf '%s\n' "$runs" | grep -c 'ci/build-recipe --channel "\$CHANNEL" ')" 2

# c. checkout never persists credentials
expect "c: every persist-credentials value is false" \
    "$(grep -E '^[[:space:]]*persist-credentials:' "$WF" | grep -c -v -E 'persist-credentials:[[:space:]]*false[[:space:]]*$')" 0
checkouts=$(grep -c 'uses: actions/checkout' "$WF")
expect "c: the workflow has checkouts to check" "$(( checkouts > 0 ))" 1
expect "c: every actions/checkout has persist-credentials: false within 3 lines" \
    "$(awk '/uses: actions\/checkout/ { pending = 1; left = 3; next }
        pending && /persist-credentials:[[:space:]]*false[[:space:]]*$/ { pending = 0; next }
        pending { if (--left == 0) { bad++; pending = 0 } }
        END { if (pending) bad++; print bad + 0 }' "$WF")" 0

# d. no secrets at all
# (YAML comment lines skipped: they name tests/ci/build-recipe-no-secrets.sh)
expect "d: no secrets. reference in build-pr.yml" \
    "$(grep -v -E '^[[:space:]]*#' "$WF" | grep -c -E '(^|[^-A-Za-z0-9_])secrets[.[]')" 0

# e. the steps that run ci/build-recipe carry no token in their own env. A step block
# starts at "      - " (step indentation) and ends at the next step or job/top-level key.
read -r nsteps nbad < <(awk '
    function flush() {
        if (blk ~ /ci\/build-recipe/) { n++; if (blk ~ /GH_TOKEN|GITHUB_TOKEN|github\.token/) bad++ }
        blk = ""
    }
    /^[[:space:]]*#/ { next }
    /^      - / || /^[^ ]/ || /^  [^ ]/ { flush() }
    { blk = blk "\n" $0 }
    END { flush(); print n + 0, bad + 0 }' "$WF")
expect "e: two steps run ci/build-recipe" "$nsteps" 2
expect "e: no GH_TOKEN/GITHUB_TOKEN/github.token in those steps" "$nbad" 0

# f. ci/build-recipe refuses a token in its environment, before the PKGBUILD check
for v in "${TOKENS[@]}"; do
    out=$(env "${unset_tokens[@]}" "$v=x" bash "$W/ci/build-recipe" no-such-recipe 2>&1); rc=$?
    expect "f: $v set: exits 1" "$rc" 1
    expect "f: $v set: says credentials in the environment" \
        "$(grep -c "credentials in the environment ($v)" <<<"$out")" 1
    expect "f: $v set: stops before the PKGBUILD check" "$(grep -c 'PKGBUILD not found' <<<"$out")" 0
done
out=$(env "${unset_tokens[@]}" bash "$W/ci/build-recipe" no-such-recipe 2>&1); rc=$?
expect "f: no token: exits 1 at the PKGBUILD check" "$rc" 1
expect "f: no token: gets past the guard to the PKGBUILD check" "$(grep -c 'PKGBUILD not found' <<<"$out")" 1
expect "f: no token: no credentials message" "$(grep -c 'credentials in the environment' <<<"$out")" 0
out=$(env "${unset_tokens[@]}" GITHUB_TOKEN= bash "$W/ci/build-recipe" no-such-recipe 2>&1)
expect "f: empty GITHUB_TOKEN: not a credential, gets to the PKGBUILD check" \
    "$(grep -c 'PKGBUILD not found' <<<"$out")" 1
exit $fails
