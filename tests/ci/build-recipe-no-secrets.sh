#!/bin/bash
# ci/build-recipe runs `makepkg -s` on recipe code outside bin/recipe-sandbox (#79, #89):
# that is only safe while the CI build step holds no secrets. This keeps the reasons
# in the ci/build-recipe header true, for every workflow that runs it (build-pr.yml, the
# PR check, and release.yml, the release build): never
# pull_request_target, no -e/--env/--privileged/docker socket/seccomp on the
# `docker run ... ci/build-recipe` lines, checkout without persisted credentials, no
# secrets.* reference, no token in the build steps' env, nor in the steps that take the build
# host's kernel lock (ci/kernel-lock starts the process that holds it through the build), and
# ci/build-recipe itself refusing to run with a token in its environment. release.yml's kernel
# job holds a token that can cancel and re-run (actions: write) for ci/kernel-preempt only;
# tests/ci/release-workflow.sh checks it is in no other step. Offline: plain grep/awk on the
# workflow, and ci/build-recipe on a recipe that does not exist (it stops at the
# guard or at the PKGBUILD check, before ci/setup-arch touches anything).
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
TOKENS=(GITHUB_TOKEN GH_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN)
unset_tokens=()
for v in "${TOKENS[@]}"; do unset_tokens+=(-u "$v"); done

# check_workflow <file> <docker runs/steps of ci/build-recipe> <steps of ci/kernel-lock>
check_workflow() {
local WF=$W/.github/workflows/$1 want=$2 want_lock=$3 n=$1 runs checkouts nsteps nbad
echo "== $n"

# a. never pull_request_target (fork PRs would get secrets and a write token)
expect "a: no pull_request_target in $n" \
    "$(grep -c 'pull_request_target' "$WF")" 0

# b. the docker run lines that start ci/build-recipe, backslash continuations joined,
# YAML/shell comment lines skipped
runs=$(awk '/^[[:space:]]*#/ { next }
    { line = acc $0
      if (line ~ /\\$/) { sub(/\\$/, "", line); acc = line " "; next }
      acc = ""; print line }' "$WF" | grep 'docker run' | grep 'ci/build-recipe')
expect "b: $want docker run line(s) start ci/build-recipe in $n" \
    "$(printf '%s\n' "$runs" | grep -c 'ci/build-recipe')" "$want"
expect "b: those docker runs pass no env, privilege, docker socket or seccomp change" \
    "$(printf '%s\n' "$runs" | grep -c -F -e ' -e ' -e '--env' -e '--privileged' -e 'docker.sock' -e 'seccomp')" 0
if [[ $n == build-pr.yml ]]; then
    expect "b: the kernel run's continuation was joined (its image and script are on one line)" \
        "$(printf '%s\n' "$runs" | grep -c 'docker run.*"\$DIR/work:/build".*ci/build-recipe --channel "\$CHANNEL" linux-omarchy')" 1
fi
# The channel reaches the container as an argument, not through its environment (#168).
expect "b: every docker run passes the channel to ci/build-recipe" \
    "$(printf '%s\n' "$runs" | grep -c 'ci/build-recipe --channel "\$CHANNEL" ')" "$want"

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
expect "d: no secrets. reference in $n" \
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
expect "e: $want step(s) run ci/build-recipe" "$nsteps" "$want"
expect "e: no GH_TOKEN/GITHUB_TOKEN/github.token in those steps" "$nbad" 0

# g. the same for the steps that run ci/kernel-lock
read -r nsteps nbad < <(awk '
    function flush() {
        if (blk ~ /ci\/kernel-lock/) { n++; if (blk ~ /GH_TOKEN|GITHUB_TOKEN|github\.token/) bad++ }
        blk = ""
    }
    /^[[:space:]]*#/ { next }
    /^      - / || /^[^ ]/ || /^  [^ ]/ { flush() }
    { blk = blk "\n" $0 }
    END { flush(); print n + 0, bad + 0 }' "$WF")
expect "g: $want_lock step(s) run ci/kernel-lock" "$nsteps" "$want_lock"
expect "g: no GH_TOKEN/GITHUB_TOKEN/github.token in those steps" "$nbad" 0
}
check_workflow build-pr.yml 2 2
check_workflow release.yml 2 3
# A new workflow that runs ci/build-recipe has to be added above.
expect "every workflow that runs ci/build-recipe is checked here" \
    "$(cd "$W/.github/workflows" && grep -l -E '^[^#]*ci/build-recipe' -- *.yml | tr '\n' ' ')" "build-pr.yml release.yml "

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
