#!/bin/bash
# bin/promote-channel (#411), offline: a throwaway gpg key signs fake packages in a fake rc
# repo, gh is a stub listing the rc release, and bin/publish is a stub that records what it
# was given. Every refusal exits non-zero with nothing staged and bin/publish never run:
#   1. usage: no --from, an unknown channel, no recipe
#   2. refusals: no such recipe, a held recipe, a recipe the source db lacks, the source at
#      another version than main's recipe, a file whose bytes differ from the db's SHA-256,
#      the release serving other bytes or not serving it, a bad signature, an unreadable
#      release, a file already staged with other bytes
#   3. passing: --dry-run stages nothing; a real run hands bin/publish --channel quattro
#      exactly the recipe's packages (a split package's too) from quattro's stage dir, byte
#      for byte, and leaves out a same-base package at an older version, with a note;
#      --from quattro goes to rc
# Usage: tests/ci/promote-channel.sh [keep]   (keep: leave the temp dir for inspection)
set -u
for t in gpg bsdtar; do
    command -v "$t" >/dev/null && continue
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
cleanup() { GNUPGHOME=$S/data/gnupg gpgconf --kill all 2>/dev/null; rm -rf "$S"; }
[[ ${1:-} == keep ]] && echo "state: $S" || trap cleanup EXIT
mkdir -p "$S/bin" "$S/stubs" "$S/ws/recipes" "$S/data" "$S/tmp"
cp "$W/bin/promote-channel" "$W/bin/env.sh" "$W/bin/publish-lib.sh" "$S/bin/"
cat >"$S/bin/publish" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/published"
STUB
cat >"$S/stubs/gh" <<'STUB'
#!/bin/bash
# gh release view <tag> ...: lists $GH_FIXTURE/<tag>.tsv; GH_DOWN=1: unreadable
[[ ${GH_DOWN:-} == 1 ]] && { echo "HTTP 502" >&2; exit 1; }
[[ $1 == release && $2 == view ]] || exit 1
f=$GH_FIXTURE/$3.tsv
[[ -f $f ]] || { echo "release not found" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$S/bin/publish" "$S/stubs/gh"
mkdir -m 0700 "$S/data/gnupg"
export PATH=$S/stubs:$PATH OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data \
    GNUPGHOME=$S/data/gnupg GH_FIXTURE=$S/gh TMPDIR=$S/tmp
unset OMARCHY_ASUS_CHANNEL GH_DOWN
gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'test <test@example.invalid>' ed25519 sign never 2>/dev/null
key=$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
[[ -n $key ]] || { echo "FAIL: could not create the test key"; exit 1; }
echo "$key" >"$S/data/fingerprint"
fail=0

recipe() {  # recipe <name> <pkgver> <pkgrel>
    mkdir -p "$S/ws/recipes/$1"
    printf 'pkgname=%s\npkgver=%s\npkgrel=%s\narch=(x86_64)\n' "$1" "$2" "$3" >"$S/ws/recipes/$1/PKGBUILD"
}
# pkg <channel repo dir> <base> <name> <version>: a signed fake package and its db entry
pkg() {
    local repo=$1 base=$2 name=$3 ver=$4 f sum
    f=$name-$ver-x86_64.pkg.tar.zst
    mkdir -p "$repo" "$S/db/$name-$ver"
    printf 'fake package %s %s\n' "$name" "$ver" >"$repo/$f"
    gpg --batch --yes --detach-sign -u "$key" -o "$repo/$f.sig" "$repo/$f" 2>/dev/null
    sum=$(sha256sum "$repo/$f" | cut -d' ' -f1)
    printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%BASE%%\n%s\n\n%%VERSION%%\n%s\n\n%%SHA256SUM%%\n%s\n\n' \
        "$f" "$name" "$base" "$ver" "$sum" >"$S/db/$name-$ver/desc"
    printf '%s\t%s\tsha256:%s\n' "$f" "$(stat -c %s "$repo/$f")" "$sum" >>"$S/gh/$5.tsv"
}
RC=$S/data/repo/rc-x86_64 Q=$S/data/repo/x86_64
fixture() {
    rm -rf "$S/data/repo" "$S/data/stage" "$S/data/stage-rc" "$S/db" "$S/gh" "$S/ws/recipes" "$S/published"
    mkdir -p "$S/gh" "$S/db"
    recipe hyprland 0.56.2 4.103
    recipe keyring 20261018 102
    recipe held 1 101; echo "waits for its test" >"$S/ws/recipes/held/HOLD"
    recipe behind 2 101
    pkg "$RC" hyprland hyprland 0.56.2-4.103 rc-x86_64
    pkg "$RC" hyprland hyprpm 0.56.2-4.103 rc-x86_64
    pkg "$RC" keyring keyring 20261018-102 rc-x86_64
    pkg "$RC" keyring keyring-old 20261018-101 rc-x86_64   # an older build's leftover
    pkg "$RC" held held 1-101 rc-x86_64
    pkg "$RC" behind behind 1-101 rc-x86_64
    bsdtar -czf "$RC/omarchy-asus.db.tar.gz" -C "$S/db" .
    rm -rf "$S/db"; mkdir -p "$S/db"
    pkg "$Q" keyring keyring 20261018-102 x86_64
    bsdtar -czf "$Q/omarchy-asus.db.tar.gz" -C "$S/db" .
}
run() { "$S/bin/promote-channel" "$@" >"$S/out" 2>"$S/err"; }
# check <ok|refused|usage> <what> [args]: the exit status, and nothing staged or published on a refusal
check() {
    local want=$1 what=$2 rc; shift 2
    run "$@"; rc=$?
    local staged; staged=$(ls -A "$S/data/stage" "$S/data/stage-rc" 2>/dev/null | grep -v ':$' | grep -v '^$')
    case $want in
        ok) if ((rc == 0)); then echo "ok: $what"; else echo "FAIL: $what: exit $rc"; cat "$S/out" "$S/err"; fail=1; fi ;;
        usage) if ((rc == 2)); then echo "ok: $what"; else echo "FAIL: $what: exit $rc, want 2"; cat "$S/err"; fail=1; fi ;;
        refused)
            if ((rc == 0)); then echo "FAIL: $what: exit 0"; cat "$S/out" "$S/err"; fail=1
            elif [[ -e $S/published || -n $staged ]]; then echo "FAIL: $what: something was staged or published"; fail=1
            else echo "ok: $what ($(tail -n1 "$S/err"))"; fi ;;
    esac
}
has() { if grep -qF -- "$2" "$S/err"; then echo "ok: $1"; else echo "FAIL: $1: no '$2' in:"; cat "$S/err"; fail=1; fi; }

echo "== 1. usage"
fixture
check usage "no --from" hyprland
check refused "an unknown channel" --from stable hyprland
check usage "no recipe" --from rc

echo "== 2. refusals"
fixture; check refused "no such recipe" --from rc nope
fixture; check refused "a recipe outside recipes/" --from rc ../x
fixture; check refused "a held recipe" --from rc hyprland held
has "the hold's reason" "waits for its test"
fixture; recipe absent 1 101; check refused "a recipe the source db lacks" --from rc absent
fixture; check refused "the source at another version than main's recipe" --from rc behind
has "says both versions" "the rc channel has 1-101, main's recipe is 2-101"
fixture; printf 'tampered\n' >"$RC/hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst"
check refused "a file that is not the db's SHA-256" --from rc hyprland
fixture; sed -i 's/\tsha256:\(.\)/\tsha256:0\1/' "$S/gh/rc-x86_64.tsv"
check refused "the release serves other bytes" --from rc hyprland
fixture; sed -i '/^hyprpm/d' "$S/gh/rc-x86_64.tsv"
check refused "the release does not serve it" --from rc hyprland
fixture; cp "$RC/keyring-20261018-102-x86_64.pkg.tar.zst.sig" "$RC/hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst.sig"
check refused "a signature that does not match the file" --from rc hyprland
fixture; GH_DOWN=1 check refused "the release can't be read" --from rc hyprland
fixture; mkdir -p "$S/data/stage"; echo other >"$S/data/stage/hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst"
run --from rc hyprland; rc=$?
if ((rc != 0)) && [[ ! -e $S/published && $(cat "$S/data/stage/hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst") == other ]]; then
    echo "ok: a file already staged with other bytes is refused and kept"
else echo "FAIL: a file already staged with other bytes: exit $rc"; cat "$S/err"; fail=1; fi

echo "== 3. passing"
fixture; check ok "--dry-run" --from rc --dry-run hyprland keyring
if [[ -e $S/published || -n $(ls -A "$S/data/stage" 2>/dev/null) ]]; then
    echo "FAIL: --dry-run staged or published"; fail=1
else echo "ok: --dry-run staged and published nothing"; fi
has "--dry-run lists the files" "hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst"
fixture; check ok "a real run" --from rc hyprland recipes/keyring/
has "the older build's leftover is left out, with a note" "keyring-old 20261018-101 is not keyring's build"
want=$(printf -- '--channel\nquattro\n'; for f in hyprland-0.56.2-4.103 hyprpm-0.56.2-4.103 keyring-20261018-102; do
    echo "$S/data/stage/$f-x86_64.pkg.tar.zst"; done)
got=$(cat "$S/published" 2>/dev/null)
if [[ $(sort <<<"$got") == $(sort <<<"$want") && $(head -2 <<<"$got") == $'--channel\nquattro' ]]; then
    echo "ok: bin/publish got --channel quattro and exactly the recipes' packages, from quattro's stage dir"
else echo "FAIL: bin/publish got:"; echo "$got"; echo "want:"; echo "$want"; fail=1; fi
for f in hyprland-0.56.2-4.103 hyprpm-0.56.2-4.103 keyring-20261018-102; do
    cmp -s "$RC/$f-x86_64.pkg.tar.zst" "$S/data/stage/$f-x86_64.pkg.tar.zst" ||
        { echo "FAIL: $f staged with other bytes"; fail=1; }
done
echo "ok: the staged files are the rc repo's, byte for byte"
fixture; mkdir -p "$S/data/stage"; cp "$RC/hyprpm-0.56.2-4.103-x86_64.pkg.tar.zst" "$S/data/stage/"
check ok "a file already staged with the same bytes" --from rc hyprland
fixture; check ok "--from quattro" --from quattro keyring
if [[ $(head -2 "$S/published") == $'--channel\nrc' && $(tail -1 "$S/published") == "$S/data/stage-rc/keyring-20261018-102-x86_64.pkg.tar.zst" ]]; then
    echo "ok: --from quattro publishes to rc from rc's stage dir"
else echo "FAIL: --from quattro published:"; cat "$S/published"; fail=1; fi

((fail == 0)) || exit 1
echo "all ok"
