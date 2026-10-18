#!/bin/bash
# Offline test of bin/recipe-sandbox (the bubblewrap jail recipe code is evaluated in):
#   1. without bwrap on PATH it refuses to run the command at all (exit 125)
#   2. a PKGBUILD sourced inside cannot read the signing key or GH_TOKEN, and cannot
#      write outside its binds
#   3. --rw binds are writable, --ro binds are not; CMD's exit status passes through
#   4. binds of /, the home, the data dir and its gnupg, and credential --setenv names
#      are refused (exit 64), as is bad usage
#   5. OMARCHY_ASUS_SANDBOX_HIDE covers a file even under a bound parent
#   6. without --net the network namespace has only loopback
# Hermetic: HOME and OMARCHY_ASUS_DATA point into a temp dir. Where bwrap is missing or
# cannot create namespaces (AppArmor-restricted user namespaces on Ubuntu), only 1 runs
# and the rest is skipped.
# Usage: tests/ci/recipe-sandbox.sh
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
SB=$W/bin/recipe-sandbox
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (exit $1, want $2)"; fail=1; fi; }

echo "== 1. no bwrap"
PATH=/nonexistent-dir /bin/bash "$SB" -- /usr/bin/true 2>/dev/null
expect $? 125 "missing bwrap refuses to run the command"

if ! type -P bwrap >/dev/null || ! bwrap --ro-bind / / true 2>/dev/null; then
    echo "skip: bwrap unavailable"
    # On CI the skip passes, but as an annotation on the run rather than in silence
    [[ -n ${CI:-} ]] && echo "::warning file=tests/ci/recipe-sandbox.sh::bwrap unavailable on this runner: sandbox cases 2-6 skipped"
    exit $fail
fi

S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
export HOME=$S/home OMARCHY_ASUS_DATA=$S/home/.local/share/omarchy-asus
unset OMARCHY_ASUS_SANDBOX_HIDE GNUPGHOME
mkdir -p "$OMARCHY_ASUS_DATA/gnupg" "$OMARCHY_ASUS_DATA/verify-gnupg/sandbox-test" \
    "$S/recipe" "$S/out" "$S/ro" "$S/etc"
echo SIGNKEY >"$OMARCHY_ASUS_DATA/gnupg/secret"
secret=$(realpath "$OMARCHY_ASUS_DATA/gnupg/secret")
marker=$S/outside-marker

echo "== 2. PKGBUILD in the sandbox"
cat >"$S/recipe/PKGBUILD" <<EOF
pkgname=sandbox-test
echo "home=\$(cat "\$OMARCHY_ASUS_DATA/gnupg/secret" 2>/dev/null)"
echo "abs=\$(cat "$secret" 2>/dev/null)"
echo "tok=\$GH_TOKEN"
touch "$marker" 2>/dev/null
echo "end of PKGBUILD"
EOF
out=$(GH_TOKEN=ghtok "$SB" --ro "$S/recipe" --chdir "$S/recipe" -- bash -c 'source ./PKGBUILD' 2>&1)
expect $? 0 "PKGBUILD sources in the sandbox"
echo "$out"
[[ $out == *"end of PKGBUILD"* ]] && r=0 || r=1; expect $r 0 "PKGBUILD ran to the end"
[[ $out != *SIGNKEY* ]] && r=0 || r=1; expect $r 0 "signing key not readable"
[[ $out != *ghtok* ]] && r=0 || r=1; expect $r 0 "GH_TOKEN not passed in"
[[ ! -e $marker ]] && r=0 || r=1; expect $r 0 "no write outside the binds"

echo "== 3. binds and exit status"
"$SB" --rw "$S/out" -- touch "$S/out/x"; expect $? 0 "--rw bind: touch succeeds"
[[ -e $S/out/x ]] && r=0 || r=1; expect $r 0 "--rw bind: the file exists outside"
"$SB" --ro "$S/ro" -- touch "$S/ro/y" 2>/dev/null; rc=$?
[[ $rc -ne 0 && ! -e $S/ro/y ]] && r=0 || r=1; expect $r 0 "--ro bind is not writable (touch exit $rc)"
"$SB" -- bash -c 'exit 7'; expect $? 7 "CMD's exit status passes through"
"$SB" --ro "$OMARCHY_ASUS_DATA/verify-gnupg/sandbox-test" \
    --setenv GNUPGHOME "$OMARCHY_ASUS_DATA/verify-gnupg/sandbox-test" -- /usr/bin/true
expect $? 0 "a per-recipe keyring under the data dir and GNUPGHOME are allowed"
out=$("$SB" --setenv FOO bar -- bash -c 'echo "$FOO $HOME"')
[[ $out == "bar /tmp/home" ]] && r=0 || r=1; expect $r 0 "--setenv and HOME=/tmp/home (got: $out)"

echo "== 4. refusals"
refuse() {  # refuse <what> <recipe-sandbox options...>
    local what=$1; shift
    "$SB" "$@" -- /usr/bin/true 2>/dev/null; expect $? 64 "refused: $what"
}
refuse "--rw HOME" --rw "$HOME"
refuse "--ro parent of HOME" --ro "$S"
refuse "--ro data dir" --ro "$OMARCHY_ASUS_DATA"
refuse "--ro data dir gnupg" --ro "$OMARCHY_ASUS_DATA/gnupg"
refuse "--ro a file in gnupg" --ro "$secret"
refuse "--ro /" --ro /
refuse "--ro missing path" --ro "$S/missing"
refuse "--setenv GH_TOKEN" --setenv GH_TOKEN x
refuse "--setenv GITHUB_TOKEN" --setenv GITHUB_TOKEN x
refuse "--setenv SSH_AUTH_SOCK" --setenv SSH_AUTH_SOCK x
refuse "--setenv OPENROUTER_API_KEY" --setenv OPENROUTER_API_KEY x
refuse "unknown option" --bogus
"$SB" /usr/bin/true 2>/dev/null; expect $? 64 "usage: no --"
"$SB" -- 2>/dev/null; expect $? 64 "usage: no CMD"

echo "== 5. OMARCHY_ASUS_SANDBOX_HIDE"
echo TOKFILE >"$S/etc/tokenfile"
out=$("$SB" --ro "$S/etc" -- cat "$S/etc/tokenfile" 2>&1)
[[ $out == TOKFILE ]] && r=0 || r=1; expect $r 0 "control: the bound file is visible without the hide list"
out=$(OMARCHY_ASUS_SANDBOX_HIDE="$S/missing::$S/etc/tokenfile" \
    "$SB" --ro "$S/etc" -- cat "$S/etc/tokenfile" 2>&1)
[[ $out != *TOKFILE* ]] && r=0 || r=1; expect $r 0 "hidden file reads empty (got: $out)"

echo "== 6. network"
out=$("$SB" -- cat /proc/net/dev); expect $? 0 "read /proc/net/dev"
ifs=$(awk -F: 'NR > 2 { gsub(/[[:space:]]/, "", $1); if ($1 != "lo") print $1 }' <<<"$out")
[[ -z $ifs ]] && r=0 || r=1; expect $r 0 "no interface but lo without --net (others: ${ifs:-none})"

exit $fail
