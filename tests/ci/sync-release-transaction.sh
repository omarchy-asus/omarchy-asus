#!/bin/bash
# Exercise bin/sync-release as one locked, verified transaction (#80), offline, against a
# hand-made signed repo, a throwaway gpg key and a fake gh whose release is a directory:
#   a. --pii-scan of a truncated archive or a non-archive fails closed ("could not ...")
#   b. a db signed by another key is refused, nothing uploaded
#   c. a stale db signature (made over other bytes) is refused, nothing uploaded
#   d. the publication lock held elsewhere: exit 75 before any gh call
#   e. a good repo syncs, then the db sum is recorded and $DATA/sync-pending cleared
#   f. an asset the db no longer names waits out PRUNE_GRACE_HOURS, then is deleted
#   g. a db someone else put on the release is refused; SYNC_ADOPT_REMOTE=1 takes over
#   h. a sync that dies after its db upload, then another publish: the next sync is not
#      refused as another publisher (each db is recorded before it goes up)
# No network, no real gh, no pacman; workspace and data dir are temp dirs.
# Usage: tests/ci/sync-release-transaction.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
for t in gpg bsdtar flock strings; do
    command -v "$t" >/dev/null || { echo "skip: $t missing"; exit 0; }
done
S=$(mktemp -d)
cleanup() { GNUPGHOME=$S/data/gnupg gpgconf --kill gpg-agent >/dev/null 2>&1; rm -rf "$S"; }
[[ ${1:-} == keep ]] && echo "state: $S" || trap cleanup EXIT
R=$S/data/repo/x86_64
mkdir -p "$S/ws/build" "$S/data/gnupg" "$R" "$S/release" "$S/bin" \
    "$S/src/pkg" "$S/src/db/foo-1-1" "$S/src/files/foo-1-1"
chmod 700 "$S/data/gnupg"
printf '# test denylist\nzorbleplex\n' >"$S/denylist"
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data GNUPGHOME=$S/data/gnupg \
    PII_DENYLIST=$S/denylist FAKE_REL=$S/release FAKE_LOG=$S/gh.log FAKE_CALLS=$S/calls \
    PATH=$S/bin:$PATH
unset PII_SCAN SYNC_ADOPT_REMOTE PRUNE_GRACE_HOURS PUBLISH_LOCK_WAIT OMARCHY_ASUS_PUBLISH_LOCKED
fail=0 out=''
expect() {
    if [[ $1 == "$2" ]]; then echo "ok: $3"
    else echo "FAIL: $3 (exit $1, want $2)"; sed 's/^/    | /' <<<"$out"; fail=1; fi
}
run_sync() { "$W/bin/sync-release" "$@" 2>&1; }
uploaded() { grep -q '^upload' "$S/calls" 2>/dev/null; }
reset_release() { rm -f "$S/release"/* "$S/calls" "$S/gh.log"; }

# --- a fake gh: the release is $FAKE_REL; uploads and deletes are logged to $FAKE_CALLS ---
cat >"$S/bin/gh" <<'EOF'
#!/bin/bash
set -u
echo "gh $*" >>"$FAKE_LOG"
[[ ${1:-} == release ]] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
sub=$2; shift 3   # 'release <sub> <tag>'
args=() pat='' dir=''
while (($#)); do
    case $1 in
        -R|--repo|--json|--jq|--target|--title|--notes-file) shift 2 ;;
        -p|--pattern) pat=$2; shift 2 ;;
        -D|--dir) dir=$2; shift 2 ;;
        --*) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
case $sub in
    view)
        [[ -d $FAKE_REL ]] || exit 1
        for f in "$FAKE_REL"/*; do
            [[ -f $f ]] || continue
            printf '%s\t%s\tsha256:%s\n' "$(basename "$f")" "$(stat -c %s "$f")" \
                "$(sha256sum "$f" | cut -d' ' -f1)"
        done ;;
    upload)
        names=()
        for f in "${args[@]}"; do cp "$f" "$FAKE_REL/" || exit 1; names+=("$(basename "$f")"); done
        echo "upload ${names[*]}" >>"$FAKE_CALLS"
        # FAKE_DB_UPLOAD_DIES=1: the db lands on the release, then the caller dies
        if [[ -n ${FAKE_DB_UPLOAD_DIES:-} && " ${names[*]} " == *" omarchy-asus.db "* ]]; then exit 1; fi ;;
    delete-asset)
        rm -f "$FAKE_REL/${args[0]}" || exit 1
        echo "delete ${args[0]}" >>"$FAKE_CALLS" ;;
    download) cp "$FAKE_REL/$pat" "$dir/" ;;
    create) mkdir -p "$FAKE_REL"; echo create >>"$FAKE_CALLS" ;;
    *) echo "fake gh: unsupported: release $sub" >&2; exit 1 ;;
esac
EOF
chmod +x "$S/bin/gh"

# --- a signing key (its fingerprint in $DATA/fingerprint) and a second, foreign one ---
gen() { gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "$1" ed25519 sign never >/dev/null 2>&1; }
fpr() { gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}'; }
sign() {  # sign <fingerprint> <file> <sig>
    gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$1" \
        --detach-sign --no-armor -o "$3" "$2" 2>/dev/null
}
gen 'test <test@example.invalid>' && gen 'other <other@example.invalid>' ||
    { echo "FAIL: cannot make the test keys"; exit 1; }
K1=$(fpr '<test@example.invalid>') K2=$(fpr '<other@example.invalid>')
[[ -n $K1 && -n $K2 && $K1 != "$K2" ]] || { echo "FAIL: cannot read the test key fingerprints"; exit 1; }
printf '%s\n' "$K1" >"$S/data/fingerprint"

# --- a repo as bin/publish (repo-add) leaves it: one package, signed db and files ---
printf 'pkgname = foo\npkgver = 1-1\n' >"$S/src/pkg/.PKGINFO"
bsdtar -cf "$R/foo-1-1-x86_64.pkg.tar.zst" -C "$S/src/pkg" .PKGINFO
sign "$K1" "$R/foo-1-1-x86_64.pkg.tar.zst" "$R/foo-1-1-x86_64.pkg.tar.zst.sig"
printf '%%FILENAME%%\nfoo-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\nfoo\n' >"$S/src/db/foo-1-1/desc"
cp "$S/src/db/foo-1-1/desc" "$S/src/files/foo-1-1/desc"
printf '%%FILES%%\nusr/bin/foo\n' >"$S/src/files/foo-1-1/files"
bsdtar -czf "$R/omarchy-asus.db.tar.gz" -C "$S/src/db" foo-1-1
bsdtar -czf "$R/omarchy-asus.files.tar.gz" -C "$S/src/files" foo-1-1
for d in db files; do
    sign "$K1" "$R/omarchy-asus.$d.tar.gz" "$R/omarchy-asus.$d.tar.gz.sig"
    ln -sf "omarchy-asus.$d.tar.gz" "$R/omarchy-asus.$d"
    ln -sf "omarchy-asus.$d.tar.gz.sig" "$R/omarchy-asus.$d.sig"
done
db_sum=$(sha256sum "$R/omarchy-asus.db.tar.gz" | cut -d' ' -f1)

echo "== a. --pii-scan fails closed on an unreadable archive"
head -c 65536 /dev/urandom >"$S/src/blob"   # incompressible: half the .tar.gz cuts into it
bsdtar -czf "$S/whole.tar.gz" -C "$S/src" blob
sz=$(stat -c %s "$S/whole.tar.gz"); head -c $((sz / 2)) "$S/whole.tar.gz" >"$S/half.tar.gz"
printf 'this is not an archive at all\n' >"$S/garbage.pkg.tar.zst"
out=$(run_sync --pii-scan "$S/whole.tar.gz"); expect $? 0 "a whole archive passes"
out=$(run_sync --pii-scan "$S/half.tar.gz"); rc=$?
expect $rc 1 "a truncated archive is refused"
grep -q 'could not' <<<"$out"; expect $? 0 "says it could not read it"
out=$(run_sync --pii-scan "$S/garbage.pkg.tar.zst"); rc=$?
expect $rc 1 "a file that is no archive is refused"
grep -q 'could not' <<<"$out"; expect $? 0 "says it could not list it"

echo "== b. db signed by another key"
reset_release
sign "$K2" "$R/omarchy-asus.db.tar.gz" "$R/omarchy-asus.db.tar.gz.sig"
out=$(run_sync); expect $? 1 "a db signed by a foreign key is refused"
grep -q 'signature does not verify' <<<"$out"; expect $? 0 "says the signature does not verify"
uploaded; expect $? 1 "nothing uploaded"

echo "== c. stale db signature"
reset_release
cp "$R/omarchy-asus.db.tar.gz" "$S/other.db"; printf 'x' >>"$S/other.db"
sign "$K1" "$S/other.db" "$R/omarchy-asus.db.tar.gz.sig"
out=$(run_sync); expect $? 1 "a signature over other bytes is refused"
uploaded; expect $? 1 "nothing uploaded"
sign "$K1" "$R/omarchy-asus.db.tar.gz" "$R/omarchy-asus.db.tar.gz.sig"   # good again

echo "== d. publication lock held elsewhere"
reset_release
exec 9>"$S/data/publish.lock"
flock -n 9 || echo "FAIL: the test cannot take the lock itself"
out=$(PUBLISH_LOCK_WAIT=1 run_sync 9>&-); rc=$?
exec 9>&-
expect $rc 75 "a busy lock exits 75"
[[ -s $S/gh.log ]]; expect $? 1 "no gh call while the lock is busy"

echo "== e. a good repo syncs, is verified, and the journal is cleared"
reset_release
touch "$S/data/sync-pending"
out=$(run_sync); expect $? 0 "a good repo syncs"
for n in foo-1-1-x86_64.pkg.tar.zst foo-1-1-x86_64.pkg.tar.zst.sig \
         omarchy-asus.db omarchy-asus.db.sig omarchy-asus.files omarchy-asus.files.sig; do
    [[ -f $S/release/$n ]]; expect $? 0 "$n is on the release"
done
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is the local db"
[[ -e $S/data/sync-pending ]]; expect $? 1 "sync-pending is cleared"
[[ $(cat "$S/data/release-db.sha256" 2>/dev/null) == "$db_sum" ]]; expect $? 0 "release-db.sha256 records the db"

echo "== f. superseded assets wait out the grace period"
printf 'stale\n' >"$S/release/old-1-1-x86_64.pkg.tar.zst"
: >"$S/calls"
out=$(run_sync); expect $? 0 "a sync with a superseded asset succeeds"
[[ -f $S/release/old-1-1-x86_64.pkg.tar.zst ]]; expect $? 0 "the superseded asset is kept for now"
grep -q $'^old-1-1-x86_64.pkg.tar.zst\t[0-9]' "$S/data/prune-candidates" 2>/dev/null
expect $? 0 "it is listed in prune-candidates"
grep -q '^delete' "$S/calls"; expect $? 1 "nothing deleted"
printf 'old-1-1-x86_64.pkg.tar.zst\t%s\n' $(($(date +%s) - 7200)) >"$S/data/prune-candidates"
out=$(PRUNE_GRACE_HOURS=1 run_sync); expect $? 0 "a sync after the grace period succeeds"
[[ -e $S/release/old-1-1-x86_64.pkg.tar.zst ]]; expect $? 1 "the superseded asset is deleted"
grep -q '^delete old-1-1-x86_64.pkg.tar.zst$' "$S/calls"; expect $? 0 "through gh release delete-asset"
grep -q '^old-' "$S/data/prune-candidates"; expect $? 1 "and dropped from prune-candidates"
[[ -f $S/release/omarchy-asus.db && -f $S/release/foo-1-1-x86_64.pkg.tar.zst ]]
expect $? 0 "the db and the package it names stay"

echo "== g. one publisher"
printf 'a db from somewhere else\n' >"$S/release/omarchy-asus.db"
: >"$S/calls"
out=$(run_sync); expect $? 1 "a db someone else put on the release is refused"
grep -q 'another publisher' <<<"$out"; expect $? 0 "says why"
uploaded; expect $? 1 "nothing uploaded"
out=$(SYNC_ADOPT_REMOTE=1 run_sync); expect $? 0 "SYNC_ADOPT_REMOTE=1 takes the release over"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is ours again"
: >"$S/calls"
out=$(run_sync --dry-run); expect $? 0 "a dry run of a synced repo passes"
[[ -s $S/calls ]]; expect $? 1 "a dry run uploads and deletes nothing"

echo "== h. a sync that dies after its db upload is still this host's"
newdb() {  # newdb <tag>: a new signed local db (same package, another desc field)
    printf '%%FILENAME%%\nfoo-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\nfoo\n\n%%DESC%%\n%s\n' "$1" \
        >"$S/src/db/foo-1-1/desc"
    bsdtar -czf "$R/omarchy-asus.db.tar.gz" -C "$S/src/db" foo-1-1
    sign "$K1" "$R/omarchy-asus.db.tar.gz" "$R/omarchy-asus.db.tar.gz.sig"
}
newdb second
sum_b=$(sha256sum "$R/omarchy-asus.db.tar.gz" | cut -d' ' -f1)
touch "$S/data/sync-pending"
out=$(FAKE_DB_UPLOAD_DIES=1 run_sync); rc=$?
((rc != 0)); expect $? 0 "a sync that dies in its db upload fails (exit $rc)"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the new db did reach the release"
[[ $(tail -n 1 "$S/data/release-db.sha256") == "$sum_b" ]]; expect $? 0 "its sum was recorded before the upload"
[[ -e $S/data/sync-pending ]]; expect $? 0 "sync-pending is kept"
newdb third   # another publish before the retry
out=$(run_sync); expect $? 0 "the next sync is not refused as another publisher"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is the newest local one"
[[ $(cat "$S/data/release-db.sha256") == "$(sha256sum "$R/omarchy-asus.db.tar.gz" | cut -d' ' -f1)" ]]
expect $? 0 "a verified sync leaves only its own db in the record"
[[ -e $S/data/sync-pending ]]; expect $? 1 "sync-pending is cleared"
exit $fail
