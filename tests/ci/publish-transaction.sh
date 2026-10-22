#!/bin/bash
# bin/publish and bin/unpublish are one locked, verified transaction (#80): a failed
# signature or a busy lock leaves the live repo byte-for-byte as it was.
#   a. a good publish: exit 0, the db names the package, its signature verifies, the
#      change is journaled in $DATA/sync-pending
#   b. repo-add exits 0 but leaves the old db signature (the GPG failure it hides):
#      refused, repo unchanged, no staging dir left
#   c. the db signed by another key: refused, repo unchanged
#   d. the lock held elsewhere (PUBLISH_LOCK_WAIT=1): exit 75, repo unchanged
#   e. unpublish with a stale db signature: refused, repo unchanged
#   f. a good unpublish: the package's files are gone
#   g. a swap killed between its two renames ($REPO_DIR only as .prev): recovered
#   h. no build/cohorts.conf in the workspace: refused, repo unchanged (#89)
#   i. --channel rc: the package goes to repo/rc-x86_64, journaled in channel-rc/sync-pending;
#      the x86_64 repo and its journal are untouched (#167)
#   j. a package from the rc stage dir is refused by a quattro publish, and one from the
#      quattro stage dir by an rc publish; neither repo changes
#   k. a filename the other channel already has with other bytes (its local repo, or its
#      release, read live, with a different or no digest) is refused and names the recipe
#      to bump; the same bytes, or a name it lacks, publish (#201)
#   l. the other release can't be read: with no listing of it, refused; with a previous
#      listing (release-assets.tsv), checked against that
# Throwaway gpg keys, stub repo-add/repo-remove (no pacman) and a fake gh whose release
# <tag> lists $S/release-<tag>.tsv (none: "release not found"; FAKE_GH_DOWN=1: unreadable);
# no network, no sudo.
# Usage: tests/ci/publish-transaction.sh [keep]   (keep: leave the temp dir for inspection)
set -u
for t in gpg bsdtar flock; do
    command -v "$t" >/dev/null && continue
    # CI installs every one of them (.github/workflows/lint.yml): a skip there is a failure
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d)
holder=
cleanup() {
    [[ -n $holder ]] && kill "$holder" 2>/dev/null
    GNUPGHOME=$S/data/gnupg gpgconf --kill all 2>/dev/null
    rm -rf "$S"
}
[[ ${1:-} == keep ]] && echo "state: $S" || trap cleanup EXIT
mkdir -p "$S/ws" "$S/data" "$S/bin" "$S/pkgs"
# bin/publish refuses a workspace without build/cohorts.conf (#89)
mkdir -p "$S/ws/build" && printf '# test: no cohorts\n' >"$S/ws/build/cohorts.conf"
mkdir -m 0700 "$S/data/gnupg"
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data GNUPGHOME=$S/data/gnupg
unset OMARCHY_ASUS_PUBLISH_LOCKED PUBLISH_LOCK_WAIT STUB_SIGN OMARCHY_ASUS_CHANNEL
REPO=$S/data/repo/x86_64
DB=$REPO/omarchy-asus.db.tar.gz
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (exit $1, want $2)"; fail=1; fi; }
nonzero() { if [[ $1 != 0 ]]; then echo "ok: $2 (exit $1)"; else echo "FAIL: $2 (exit 0, want non-zero)"; fail=1; fi; }
listing() { [[ -d $REPO ]] && (cd "$REPO" && find . \( -type f -o -type l \) -print0 | sort -z | xargs -0 -r sha256sum); }
unchanged() { if [[ $(listing) == "$1" ]]; then echo "ok: $2"; else echo "FAIL: $2 (live repo changed)"; fail=1; fi; }
db_names() { bsdtar -xOf "$DB" 2>/dev/null | grep -qx "$1"; }

genkey() {
    gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "$1" ed25519 sign never 2>/dev/null
    gpg --batch --with-colons --list-secret-keys "$1" | awk -F: '/^fpr:/ {print $10; exit}'
}
key=$(genkey 'test <test@example.invalid>')
STUB_WRONG_KEY=$(genkey 'wrong <wrong@example.invalid>')
export STUB_WRONG_KEY
[[ -n $key && -n $STUB_WRONG_KEY ]] || { echo "FAIL: could not create the test keys"; exit 1; }
echo "$key" >"$S/data/fingerprint"

# Stub repo-add / repo-remove: keep '<name>-<ver>-<rel>/desc' entries with %FILENAME% in
# a db.tar.gz and files.tar.gz, rotate the old db to .old, relink .db/.files(.sig) and
# sign both with --key. STUB_SIGN=stale: skip signing, keep the old .sig, exit 0 (the
# GPG failure real repo-add hides); STUB_SIGN=wrongkey: sign with $STUB_WRONG_KEY.
cat >"$S/bin/repo-add" <<'EOF'
#!/bin/bash
set -euo pipefail
mode=$(basename "$0") db= signkey= remove=0 args=()
while (($#)); do
    case $1 in
        --key) signkey=$2; shift ;;
        --remove) remove=1 ;;
        --sign|--verify) ;;
        *.db.tar.gz) if [[ -z $db ]]; then db=$1; else args+=("$1"); fi ;;
        *) args+=("$1") ;;
    esac
    shift
done
[[ -n $db ]] || { echo "$mode: no db given" >&2; exit 1; }
dir=$(dirname "$db") repo=$(basename "$db" .db.tar.gz)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/e"
[[ -f $db ]] && bsdtar -xf "$db" -C "$work/e"
entry_file() { awk 'p {print; exit} /^%FILENAME%$/ {p=1}' "$1/desc"; }
drop() {  # drop <name> [<keep file>]: remove its entries (and with --remove, its old files)
    local d e found=1
    for d in "$work"/e/*/; do
        [[ -d $d ]] || continue
        e=$(basename "$d")
        [[ ${e%-*-*} == "$1" ]] || continue
        if ((remove)); then
            old=$(entry_file "$d")
            [[ $old == "${2:-}" ]] || rm -f "$dir/$old" "$dir/$old.sig"
        fi
        rm -rf "$d"; found=0
    done
    return $found
}
for a in "${args[@]}"; do
    if [[ $mode == repo-remove ]]; then
        drop "$a" || { echo "$mode: $a not in the db" >&2; exit 1; }
        continue
    fi
    b=$(basename "$a") s=$(basename "$a"); s=${s%.pkg.tar.*}; s=${s%-*}
    rel=${s##*-}; s=${s%-*}; ver=${s##*-}; name=${s%-*}
    drop "$name" "$b" || true
    mkdir -p "$work/e/$name-$ver-$rel"
    printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s-%s\n\n' "$b" "$name" "$ver" "$rel" \
        >"$work/e/$name-$ver-$rel/desc"
done
for kind in db files; do
    f=$dir/$repo.$kind.tar.gz
    if [[ $kind == files ]]; then
        for d in "$work"/e/*/; do [[ -d $d ]] && printf '%%FILES%%\n' >"$d/files"; done
    fi
    bsdtar -czf "$work/$kind.tar.gz" -C "$work/e" .
    if [[ -f $f ]]; then
        mv -f "$f" "$f.old"
        [[ -f $f.sig ]] && cp -f "$f.sig" "$f.old.sig"
    fi
    mv -f "$work/$kind.tar.gz" "$f"
    ln -sf "$repo.$kind.tar.gz" "$dir/$repo.$kind"
    ln -sf "$repo.$kind.tar.gz.sig" "$dir/$repo.$kind.sig"
    case ${STUB_SIGN:-} in
        stale) ;;
        wrongkey) gpg --batch --yes --local-user "$STUB_WRONG_KEY" --detach-sign --no-armor "$f" ;;
        *) gpg --batch --yes --local-user "$signkey" --detach-sign --no-armor "$f" ;;
    esac
done
EOF
cat >"$S/bin/gh" <<'EOF'
#!/bin/bash
# gh release view <tag> -R ... --json assets --jq ...
[[ $1 == release && $2 == view ]] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
[[ -z ${FAKE_GH_DOWN:-} ]] || { echo "error connecting to api.github.com" >&2; exit 1; }
[[ -f $FAKE_GH_DIR/release-$3.tsv ]] || { echo "release not found" >&2; exit 1; }
cat "$FAKE_GH_DIR/release-$3.tsv"
EOF
chmod +x "$S/bin/gh"
export FAKE_GH_DIR=$S
unset FAKE_GH_DOWN BASH_ENV ENV
cp "$S/bin/repo-add" "$S/bin/repo-remove"
chmod +x "$S/bin/repo-add" "$S/bin/repo-remove"
export PATH=$S/bin:$PATH

mkpkg() {  # mkpkg <name> <ver> <rel>: a small archive standing in for a package
    local d=$S/pkgsrc/$1-$2-$3
    mkdir -p "$d"
    printf 'pkgname = %s\npkgver = %s-%s\n' "$1" "$2" "$3" >"$d/.PKGINFO"
    bsdtar -cf "$S/pkgs/$1-$2-$3-x86_64.pkg.tar.zst" -C "$d" .PKGINFO
}
mkpkg foo 1 1
mkpkg foo 1 2
publish() { "$W/bin/publish" "$@" >"$S/out" 2>&1; }
unpublish() { "$W/bin/unpublish" "$@" >"$S/out" 2>&1; }

echo "== a. good publish"
publish "$S/pkgs/foo-1-1-x86_64.pkg.tar.zst"; expect $? 0 "publish foo-1-1"
db_names foo-1-1-x86_64.pkg.tar.zst; expect $? 0 "the db names foo-1-1"
gpg --batch --verify "$REPO/foo-1-1-x86_64.pkg.tar.zst.sig" "$REPO/foo-1-1-x86_64.pkg.tar.zst" 2>/dev/null
expect $? 0 "the package signature verifies"
if [[ -f $S/data/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 0 "the change is journaled in sync-pending"
if [[ -e $REPO.new || -e $REPO.prev ]]; then r=0; else r=1; fi; expect "$r" 1 "no staging or .prev dir left"

echo "== b. repo-add leaves the old db signature"
before=$(listing)
STUB_SIGN=stale publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "publish with a stale db signature is refused"
unchanged "$before" "live repo unchanged"
if [[ -e $REPO.new ]]; then r=0; else r=1; fi; expect "$r" 1 "no staging dir left"

echo "== c. db signed by another key"
STUB_SIGN=wrongkey publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "publish with a wrong-key db signature is refused"
unchanged "$before" "live repo unchanged"
if [[ -e $REPO.new ]]; then r=0; else r=1; fi; expect "$r" 1 "no staging dir left"

echo "== d. lock held elsewhere"
( exec 9>"$S/data/publish.lock"; flock 9; : >"$S/locked"; exec sleep 30 ) &
holder=$!
for _ in $(seq 100); do [[ -e $S/locked ]] && break; sleep 0.1; done
if [[ -e $S/locked ]]; then r=0; else r=1; fi; expect "$r" 0 "the test holds the lock"
PUBLISH_LOCK_WAIT=1 publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; expect $? 75 "publish waits, then exits 75"
grep -q 'holds .*publish.lock' "$S/out"; expect $? 0 "says who blocks it"
unchanged "$before" "live repo unchanged"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=

echo "== e. unpublish with a stale db signature"
STUB_SIGN=stale unpublish foo; nonzero $? "unpublish with a stale db signature is refused"
unchanged "$before" "live repo unchanged"
if [[ -f $REPO/foo-1-1-x86_64.pkg.tar.zst ]]; then r=0; else r=1; fi; expect "$r" 0 "foo-1-1 still present"

echo "== f. good unpublish"
unpublish foo; expect $? 0 "unpublish foo"
compgen -G "$REPO/foo-*" >/dev/null; expect $? 1 "foo's files are gone"
db_names foo-1-1-x86_64.pkg.tar.zst; expect $? 1 "the db no longer names foo"

echo "== g. recovery from an interrupted swap"
mv "$REPO" "$REPO.prev"
publish "$S/pkgs/foo-1-1-x86_64.pkg.tar.zst"; expect $? 0 "publish after an interrupted swap"
grep -q 'recovered' "$S/out"; expect $? 0 "says it recovered"
if [[ -e $REPO.prev || -e $REPO.new ]]; then r=0; else r=1; fi; expect "$r" 1 "no .prev or staging dir left"
db_names foo-1-1-x86_64.pkg.tar.zst; expect $? 0 "the db names foo-1-1"

echo "== h. no build/cohorts.conf in the workspace"
before=$(listing)
mv "$S/ws/build/cohorts.conf" "$S/ws/build/cohorts.conf.off"
publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "publish without a cohorts file is refused"
unchanged "$before" "live repo unchanged"
mv "$S/ws/build/cohorts.conf.off" "$S/ws/build/cohorts.conf"

echo "== i. the rc channel has its own repo and journal"
RC=$S/data/repo/rc-x86_64
rm -f "$S/data/sync-pending"
before=$(listing)
publish --channel rc "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; expect $? 0 "publish --channel rc foo-1-2"
bsdtar -xOf "$RC/omarchy-asus.db.tar.gz" 2>/dev/null | grep -qx foo-1-2-x86_64.pkg.tar.zst
expect $? 0 "the rc db names foo-1-2"
gpg --batch --verify "$RC/foo-1-2-x86_64.pkg.tar.zst.sig" "$RC/foo-1-2-x86_64.pkg.tar.zst" 2>/dev/null
expect $? 0 "its signature verifies"
unchanged "$before" "the x86_64 repo unchanged"
if [[ -f $S/data/channel-rc/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 0 "journaled in channel-rc/sync-pending"
if [[ -e $S/data/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 1 "the x86_64 journal untouched"

echo "== j. a package from the other channel's stage dir"
mkdir -p "$S/data/stage" "$S/data/stage-rc"
cp "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst" "$S/data/stage-rc/"
cp "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst" "$S/data/stage/"
rc_before=$( (cd "$RC" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) )
publish "$S/data/stage-rc/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "a quattro publish of an rc build is refused"
grep -q 'built for the rc channel' "$S/out"; expect $? 0 "says it was built for rc"
unchanged "$before" "the x86_64 repo unchanged"
publish --channel rc "$S/data/stage/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "an rc publish of a quattro build is refused"
grep -q 'built for the quattro channel' "$S/out"; expect $? 0 "says it was built for quattro"
if [[ $( (cd "$RC" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) ) == "$rc_before" ]]; then r=0; else r=1; fi
expect "$r" 0 "the rc repo unchanged"

echo "== k. one filename, one file, on every channel"
rc_listing() { (cd "$RC" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum); }
mkdir -p "$S/other"
printf 'pkgname = foo\npkgbase = foo\npkgver = 1-1\nbuilddate = 2\n' >"$S/other/.PKGINFO"
bsdtar -cf "$S/other/foo-1-1-x86_64.pkg.tar.zst" -C "$S/other" .PKGINFO
rc_before=$(rc_listing)
publish --channel rc "$S/other/foo-1-1-x86_64.pkg.tar.zst"
nonzero $? "an rc foo-1-1 with other bytes than quattro's local one is refused"
grep -q "quattro channel's local repo .* has a different foo-1-1" "$S/out"; expect $? 0 "says where the other file is"
grep -q 'bump pkgrel in recipes/foo' "$S/out"; expect $? 0 "names the recipe to bump"
if [[ $(rc_listing) == "$rc_before" ]]; then r=0; else r=1; fi; expect "$r" 0 "the rc repo unchanged"
mkpkg bar 1 1
bar=$S/pkgs/bar-1-1-x86_64.pkg.tar.zst
bar_sum=$(sha256sum "$bar" | cut -d' ' -f1)
before=$(listing)
# only on the rc release (superseded in the rc repo, not pruned yet), no listing kept
rm -f "$S/data/channel-rc/release-assets.tsv"
printf 'bar-1-1-x86_64.pkg.tar.zst\t10\tsha256:%064d\n' 0 >"$S/release-rc-x86_64.tsv"
publish "$bar"; nonzero $? "a name only the rc release serves, with another digest, is refused"
grep -q "rc channel's release serves a different bar-1-1" "$S/out"; expect $? 0 "says the rc release has it"
unchanged "$before" "the x86_64 repo unchanged"
grep -q '^bar-1-1' "$S/data/channel-rc/release-assets.tsv"; expect $? 0 "the rc listing is kept"
printf 'bar-1-1-x86_64.pkg.tar.zst\t10\t\n' >"$S/release-rc-x86_64.tsv"
publish "$bar"; nonzero $? "a name the rc release serves with no digest is refused"
grep -q 'digest is unknown' "$S/out"; expect $? 0 "says the digest is unknown"
unchanged "$before" "the x86_64 repo unchanged"
printf 'bar-1-1-x86_64.pkg.tar.zst\t10\tsha256:%s\n' "$bar_sum" >"$S/release-rc-x86_64.tsv"
publish "$bar"; expect $? 0 "the same bytes as the rc release's publish"
db_names bar-1-1-x86_64.pkg.tar.zst; expect $? 0 "the db names bar-1-1"
publish --channel rc "$S/pkgs/foo-1-1-x86_64.pkg.tar.zst"; expect $? 0 "the same bytes as quattro's local foo-1-1 publish on rc"

echo "== l. the other release can't be read"
mkpkg baz 1 1
mkpkg qux 1 1
rm -f "$S/data/channel-rc/release-assets.tsv"
before=$(listing)
FAKE_GH_DOWN=1 publish "$S/pkgs/baz-1-1-x86_64.pkg.tar.zst"; nonzero $? "no listing of the rc release: refused"
grep -q 'cannot read the rc-x86_64 release and have no listing' "$S/out"; expect $? 0 "says why"
unchanged "$before" "the x86_64 repo unchanged"
printf 'baz-1-1-x86_64.pkg.tar.zst\t10\tsha256:%064d\n' 0 >"$S/data/channel-rc/release-assets.tsv"
FAKE_GH_DOWN=1 publish "$S/pkgs/baz-1-1-x86_64.pkg.tar.zst"; nonzero $? "a clash in the last listing: refused"
grep -q "rc channel's release serves a different baz-1-1" "$S/out"; expect $? 0 "says the rc release has it"
unchanged "$before" "the x86_64 repo unchanged"
FAKE_GH_DOWN=1 publish "$S/pkgs/qux-1-1-x86_64.pkg.tar.zst"; expect $? 0 "a name the last listing lacks publishes"
grep -q 'checking against its last listing' "$S/out"; expect $? 0 "and warns it used the last listing"
((fail)) && { echo "--- last output:"; cat "$S/out"; }
exit $fail
