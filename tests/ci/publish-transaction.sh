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
# Throwaway gpg keys and stub repo-add/repo-remove (no pacman); no network, no sudo.
# Usage: tests/ci/publish-transaction.sh [keep]   (keep: leave the temp dir for inspection)
set -u
for t in gpg bsdtar flock; do
    command -v "$t" >/dev/null || { echo "skip: $t missing"; exit 0; }
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
mkdir -m 0700 "$S/data/gnupg"
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data GNUPGHOME=$S/data/gnupg
unset OMARCHY_ASUS_PUBLISH_LOCKED PUBLISH_LOCK_WAIT STUB_SIGN
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
[[ -f $S/data/sync-pending ]]; expect $? 0 "the change is journaled in sync-pending"
[[ -e $REPO.new || -e $REPO.prev ]]; expect $? 1 "no staging or .prev dir left"

echo "== b. repo-add leaves the old db signature"
before=$(listing)
STUB_SIGN=stale publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "publish with a stale db signature is refused"
unchanged "$before" "live repo unchanged"
[[ -e $REPO.new ]]; expect $? 1 "no staging dir left"

echo "== c. db signed by another key"
STUB_SIGN=wrongkey publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; nonzero $? "publish with a wrong-key db signature is refused"
unchanged "$before" "live repo unchanged"
[[ -e $REPO.new ]]; expect $? 1 "no staging dir left"

echo "== d. lock held elsewhere"
( exec 9>"$S/data/publish.lock"; flock 9; : >"$S/locked"; exec sleep 30 ) &
holder=$!
for _ in $(seq 100); do [[ -e $S/locked ]] && break; sleep 0.1; done
[[ -e $S/locked ]]; expect $? 0 "the test holds the lock"
PUBLISH_LOCK_WAIT=1 publish "$S/pkgs/foo-1-2-x86_64.pkg.tar.zst"; expect $? 75 "publish waits, then exits 75"
grep -q 'holds .*publish.lock' "$S/out"; expect $? 0 "says who blocks it"
unchanged "$before" "live repo unchanged"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; holder=

echo "== e. unpublish with a stale db signature"
STUB_SIGN=stale unpublish foo; nonzero $? "unpublish with a stale db signature is refused"
unchanged "$before" "live repo unchanged"
[[ -f $REPO/foo-1-1-x86_64.pkg.tar.zst ]]; expect $? 0 "foo-1-1 still present"

echo "== f. good unpublish"
unpublish foo; expect $? 0 "unpublish foo"
compgen -G "$REPO/foo-*" >/dev/null; expect $? 1 "foo's files are gone"
db_names foo-1-1-x86_64.pkg.tar.zst; expect $? 1 "the db no longer names foo"

echo "== g. recovery from an interrupted swap"
mv "$REPO" "$REPO.prev"
publish "$S/pkgs/foo-1-1-x86_64.pkg.tar.zst"; expect $? 0 "publish after an interrupted swap"
grep -q 'recovered' "$S/out"; expect $? 0 "says it recovered"
[[ -e $REPO.prev || -e $REPO.new ]]; expect $? 1 "no .prev or staging dir left"
db_names foo-1-1-x86_64.pkg.tar.zst; expect $? 0 "the db names foo-1-1"
((fail)) && { echo "--- last output:"; cat "$S/out"; }
exit $fail
