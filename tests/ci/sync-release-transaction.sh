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
#   i. no record yet (an upgraded host adopts the release) and the db upload fails before
#      it replaces the release's db: the retry still knows that db as this host's
#   j. --channel rc: repo/rc-x86_64 goes to the rc-x86_64 release only (created on first
#      sync), with its own record in channel-rc; the x86_64 release and its record are
#      untouched (#167)
#   k. no regression (#201), on a fresh rc release whose previous release is a Quattro one
#      serving foo, bar and baz, with recipes read through a stub sandbox: a first publish
#      without our bar is withheld (no release made, nothing uploaded, bar in
#      channel-rc/release-withheld), while a net-new recipe not built yet holds nothing; a
#      held recipe's package counts too; a ready foo goes up while bar, behind, keeps our
#      last build; a db missing bar is withheld while recipes/bar exists, also when it is
#      unreadable, and goes up once the recipe is removed; an unreadable Quattro release
#      refuses (exit 1); no recipes/ at all refuses (exit 1)
#   e also checks that a train issue the fake gh cannot update (bin/release-train, #212)
#   is a warning, never a failed sync, and that RELEASE_TRAIN=off skips it
# No network, no real gh, no pacman; workspace and data dir are temp dirs.
# Usage: tests/ci/sync-release-transaction.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
for t in gpg bsdtar flock strings; do
    command -v "$t" >/dev/null && continue
    # CI installs every one of them (.github/workflows/lint.yml): a skip there is a failure
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
S=$(mktemp -d)
cleanup() { GNUPGHOME=$S/data/gnupg gpgconf --kill gpg-agent >/dev/null 2>&1; rm -rf "$S"; }
[[ ${1:-} == keep ]] && echo "state: $S" || trap cleanup EXIT
R=$S/data/repo/x86_64
mkdir -p "$S/ws/build" "$S/ws/recipes" "$S/data/gnupg" "$R" "$S/release" "$S/bin" \
    "$S/src/pkg" "$S/src/db/foo-1-1" "$S/src/files/foo-1-1"
chmod 700 "$S/data/gnupg"
printf '# test denylist\nzorbleplex\n' >"$S/denylist"
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data GNUPGHOME=$S/data/gnupg \
    PII_DENYLIST=$S/denylist FAKE_REL=$S/release FAKE_LOG=$S/gh.log FAKE_CALLS=$S/calls \
    PATH=$S/bin:$PATH
unset PII_SCAN SYNC_ADOPT_REMOTE PRUNE_GRACE_HOURS PUBLISH_LOCK_WAIT OMARCHY_ASUS_PUBLISH_LOCKED OMARCHY_ASUS_CHANNEL
# Quattro is frozen (#309); this test runs the default (quattro) channel's code, so it overrides
export OMARCHY_ASUS_ALLOW_QUATTRO=1
# bin/sync-release talks to the live release (env.sh fixes GH_REPO/GH_TAG), so the fake gh
# must win: a BASH_ENV that puts another dir first on PATH (a wrapper's gh shim) would hand
# the uploads to the real gh. Drop it, and give any real gh that still runs no credentials.
unset BASH_ENV ENV GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
mkdir -p "$S/no-gh"
export GH_CONFIG_DIR=$S/no-gh GH_HOST=fake-gh.invalid
fail=0 out=''
expect() {
    if [[ $1 == "$2" ]]; then echo "ok: $3"
    else echo "FAIL: $3 (exit $1, want $2)"; sed 's/^/    | /' <<<"$out"; fail=1; fi
}
run_sync() { "$W/bin/sync-release" "$@" 2>&1; }
uploaded() { [[ -f $S/calls ]] && grep -q "^upload" "$S/calls"; }
reset_release() { rm -f "$S/release"/* "$S/calls" "$S/gh.log"; }

# --- a fake gh: the release is $FAKE_REL; uploads and deletes are logged to $FAKE_CALLS ---
cat >"$S/bin/gh" <<'EOF'
#!/bin/bash
set -u
echo "gh $*" >>"$FAKE_LOG"
[[ ${1:-} == release ]] || { echo "fake gh: unsupported: $*" >&2; exit 1; }
sub=$2 tag=${3:-}; shift 3   # 'release <sub> <tag>'
# the x86_64 release is $FAKE_REL, any other tag's is $FAKE_REL-<tag>
rel=$FAKE_REL; [[ $tag == x86_64 ]] || rel=$FAKE_REL-$tag
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
        [[ -d $rel ]] || exit 1
        for f in "$rel"/*; do
            [[ -f $f ]] || continue
            printf '%s\t%s\tsha256:%s\n' "$(basename "$f")" "$(stat -c %s "$f")" \
                "$(sha256sum "$f" | cut -d' ' -f1)"
        done ;;
    upload)
        names=()
        # FAKE_DB_UPLOAD_FAILS=1: a db upload fails before anything reaches the release
        if [[ -n ${FAKE_DB_UPLOAD_FAILS:-} && " ${args[*]##*/} " == *" omarchy-asus.db "* ]]; then exit 1; fi
        for f in "${args[@]}"; do cp "$f" "$rel/" || exit 1; names+=("$(basename "$f")"); done
        echo "upload ${names[*]}" >>"$FAKE_CALLS"
        # FAKE_DB_UPLOAD_DIES=1: the db lands on the release, then the caller dies
        if [[ -n ${FAKE_DB_UPLOAD_DIES:-} && " ${names[*]} " == *" omarchy-asus.db "* ]]; then exit 1; fi ;;
    delete-asset)
        rm -f "$rel/${args[0]}" || exit 1
        echo "delete ${args[0]}" >>"$FAKE_CALLS" ;;
    download) cp "$rel/$pat" "$dir/" ;;
    create) mkdir -p "$rel"; echo create >>"$FAKE_CALLS" ;;
    *) echo "fake gh: unsupported: release $sub" >&2; exit 1 ;;
esac
EOF
chmod +x "$S/bin/gh"
# refuse to run at all unless a child bash script (as bin/sync-release is) resolves the fake
[[ $(bash -c 'command -v gh') == "$S/bin/gh" ]] ||
    { echo "FAIL: a child bash does not resolve the fake gh; refusing to run against the real one"; exit 1; }

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
if [[ -s $S/gh.log ]]; then r=0; else r=1; fi; expect "$r" 1 "no gh call while the lock is busy"

echo "== e. a good repo syncs, is verified, and the journal is cleared"
reset_release
touch "$S/data/sync-pending"
out=$(run_sync); expect $? 0 "a good repo syncs"
for n in foo-1-1-x86_64.pkg.tar.zst foo-1-1-x86_64.pkg.tar.zst.sig \
         omarchy-asus.db omarchy-asus.db.sig omarchy-asus.files omarchy-asus.files.sig; do
    if [[ -f $S/release/$n ]]; then r=0; else r=1; fi; expect "$r" 0 "$n is on the release"
done
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is the local db"
if [[ -e $S/data/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 1 "sync-pending is cleared"
if [[ $(cat "$S/data/release-db.sha256" 2>/dev/null) == "$db_sum" ]]; then r=0; else r=1; fi; expect "$r" 0 "release-db.sha256 records the db"
# the fake gh knows no issues: the train issue (bin/release-train, #212) fails, the sync stands
grep -q "warning: the release train issue was not updated" <<<"$out"; expect $? 0 "a failed train update only warns"
out=$(RELEASE_TRAIN=off run_sync); expect $? 0 "RELEASE_TRAIN=off syncs"
grep -q "release train issue not updated (RELEASE_TRAIN=off)" <<<"$out"; expect $? 0 "and skips the train issue"

echo "== f. superseded assets wait out the grace period"
printf 'stale\n' >"$S/release/old-1-1-x86_64.pkg.tar.zst"
: >"$S/calls"
out=$(run_sync); expect $? 0 "a sync with a superseded asset succeeds"
if [[ -f $S/release/old-1-1-x86_64.pkg.tar.zst ]]; then r=0; else r=1; fi; expect "$r" 0 "the superseded asset is kept for now"
grep -q $'^old-1-1-x86_64.pkg.tar.zst\t[0-9]' "$S/data/prune-candidates" 2>/dev/null
expect $? 0 "it is listed in prune-candidates"
grep -q '^delete' "$S/calls"; expect $? 1 "nothing deleted"
printf 'old-1-1-x86_64.pkg.tar.zst\t%s\n' $(($(date +%s) - 7200)) >"$S/data/prune-candidates"
out=$(PRUNE_GRACE_HOURS=1 run_sync); expect $? 0 "a sync after the grace period succeeds"
if [[ -e $S/release/old-1-1-x86_64.pkg.tar.zst ]]; then r=0; else r=1; fi; expect "$r" 1 "the superseded asset is deleted"
grep -q '^delete old-1-1-x86_64.pkg.tar.zst$' "$S/calls"; expect $? 0 "through gh release delete-asset"
grep -q '^old-' "$S/data/prune-candidates"; expect $? 1 "and dropped from prune-candidates"
if [[ -f $S/release/omarchy-asus.db && -f $S/release/foo-1-1-x86_64.pkg.tar.zst ]]; then r=0; else r=1; fi
expect "$r" 0 "the db and the package it names stay"

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
if [[ -s $S/calls ]]; then r=0; else r=1; fi; expect "$r" 1 "a dry run uploads and deletes nothing"

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
if ((rc != 0)); then r=0; else r=1; fi; expect "$r" 0 "a sync that dies in its db upload fails (exit $rc)"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the new db did reach the release"
tail -n 1 "$S/data/release-db.sha256" | grep -qxF -- "$sum_b"; expect $? 0 "its sum was recorded before the upload"
if [[ -e $S/data/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 0 "sync-pending is kept"
newdb third   # another publish before the retry
out=$(run_sync); expect $? 0 "the next sync is not refused as another publisher"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is the newest local one"
if [[ $(cat "$S/data/release-db.sha256") == "$(sha256sum "$R/omarchy-asus.db.tar.gz" | cut -d' ' -f1)" ]]; then r=0; else r=1; fi
expect "$r" 0 "a verified sync leaves only its own db in the record"
if [[ -e $S/data/sync-pending ]]; then r=0; else r=1; fi; expect "$r" 1 "sync-pending is cleared"

echo "== i. an adopted release whose first db upload fails"
rm -f "$S/data/release-db.sha256"
newdb fourth
out=$(FAKE_DB_UPLOAD_FAILS=1 run_sync); rc=$?
if ((rc != 0)); then r=0; else r=1; fi; expect "$r" 0 "the failed db upload fails the sync (exit $rc)"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 1 "the release still has the adopted db"
out=$(run_sync); expect $? 0 "the retry is not refused as another publisher"
cmp -s "$S/release/omarchy-asus.db" "$R/omarchy-asus.db.tar.gz"; expect $? 0 "the release's db is the local one"

echo "== j. the rc channel syncs to its own release"
RR=$S/data/repo/rc-x86_64
mkdir -p "$RR"
cp -a "$R"/. "$RR"/
rel_before=$( (cd "$S/release" && sha256sum -- *) )
rec_before=$(cat "$S/data/release-db.sha256")
: >"$S/gh.log"; rm -f "$S/calls"
out=$(run_sync --channel rc); expect $? 0 "an rc sync succeeds"
grep -q '^create' "$S/calls"; expect $? 0 "it creates the rc release"
cmp -s "$S/release-rc-x86_64/omarchy-asus.db" "$RR/omarchy-asus.db.tar.gz"; expect $? 0 "the rc release's db is the rc repo's"
if [[ -f $S/release-rc-x86_64/foo-1-1-x86_64.pkg.tar.zst ]]; then r=0; else r=1; fi; expect "$r" 0 "the package is on the rc release"
awk '$1 == "gh" && $2 == "release" && $4 != "rc-x86_64" {bad = 1} END {exit !bad}' "$S/gh.log"
expect $? 1 "every gh release call names rc-x86_64"
grep -q -- '--target main' "$S/gh.log"; expect $? 0 "the rc release targets main, the RC trunk (#309)"
if [[ $( (cd "$S/release" && sha256sum -- *) ) == "$rel_before" ]]; then r=0; else r=1; fi; expect "$r" 0 "the x86_64 release unchanged"
if [[ $(cat "$S/data/release-db.sha256") == "$rec_before" ]]; then r=0; else r=1; fi; expect "$r" 0 "the x86_64 record unchanged"
if [[ $(cat "$S/data/channel-rc/release-db.sha256" 2>/dev/null) == "$(sha256sum "$RR/omarchy-asus.db.tar.gz" | cut -d' ' -f1)" ]]; then r=0; else r=1; fi
expect "$r" 0 "channel-rc/release-db.sha256 records the rc db"

echo "== k. no regression"
# bin/ with a stub sandbox (runs the command in --chdir) and a makepkg that prints the
# recipe's SRCINFO file (or fails when the recipe has a FAIL file)
L=$S/lib
mkdir -p "$L" "$S/pool"
cp "$W/bin/sync-release" "$W/bin/env.sh" "$W/bin/publish-lib.sh" "$W/bin/check-upstream" "$W/bin/release-train" "$L/"
cat >"$L/recipe-sandbox" <<'STUB'
#!/bin/bash
dir=.
while (($#)) && [[ $1 != -- ]]; do [[ $1 == --chdir ]] && { dir=$2; shift; }; shift; done
shift; cd "$dir" && exec "$@"
STUB
cat >"$S/bin/makepkg" <<'STUB'
#!/bin/bash
[[ $* == --printsrcinfo && -f SRCINFO && ! -e FAIL ]] || exit 1
cat SRCINFO
STUB
chmod +x "$L"/* "$S/bin/makepkg"
recipe() {  # recipe <dir> <pkgver-pkgrel> <pkgname>...: a recipe makepkg reports at that version
    local d=$S/ws/recipes/$1 v=$2 n; shift 2
    mkdir -p "$d"; : >"$d/PKGBUILD"
    { printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n' "${d##*/}" "${v%-*}" "${v##*-}"
      for n; do printf '\npkgname = %s\n' "$n"; done; } >"$d/SRCINFO"
}
mkdb() {  # mkdb <repo dir> <name>-<pkgver>-<pkgrel>...: those packages (the same bytes every
          # time: a pool), and a signed db and files naming them, as bin/publish leaves a repo
    local dir=$1 e n v d k=$S/k; shift
    rm -rf "$dir" "$k"; mkdir -p "$dir" "$k/db" "$k/files" "$k/pkg"
    for e; do
        n=${e%-*-*} v=${e#"$n"-}
        if [[ ! -e $S/pool/$e-x86_64.pkg.tar.zst ]]; then
            printf 'pkgname = %s\npkgver = %s\n' "$n" "$v" >"$k/pkg/.PKGINFO"
            bsdtar -cf "$S/pool/$e-x86_64.pkg.tar.zst" -C "$k/pkg" .PKGINFO
        fi
        cp "$S/pool/$e-x86_64.pkg.tar.zst" "$dir/"
        sign "$K1" "$dir/$e-x86_64.pkg.tar.zst" "$dir/$e-x86_64.pkg.tar.zst.sig"
        mkdir -p "$k/db/$e" "$k/files/$e"
        printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' "$e-x86_64.pkg.tar.zst" "$n" "$v" \
            >"$k/db/$e/desc"
        cp "$k/db/$e/desc" "$k/files/$e/desc"
    done
    bsdtar -czf "$dir/omarchy-asus.db.tar.gz" -C "$k/db" "$@"
    bsdtar -czf "$dir/omarchy-asus.files.tar.gz" -C "$k/files" "$@"
    for d in db files; do
        sign "$K1" "$dir/omarchy-asus.$d.tar.gz" "$dir/omarchy-asus.$d.tar.gz.sig"
        ln -sf "omarchy-asus.$d.tar.gz" "$dir/omarchy-asus.$d"
        ln -sf "omarchy-asus.$d.tar.gz.sig" "$dir/omarchy-asus.$d.sig"
    done
}
KR=$S/release-rc-x86_64 KD=$S/data/channel-rc
rm -rf "$KR" "$KD"; mkdir -p "$KD"
run_k() { "$L/sync-release" --channel rc "$@" 2>&1; }
exists() { if [[ -e $1 ]]; then echo 0; else echo 1; fi; }

# The Quattro release (x86_64) serves foo, bar, bar-extra and baz: RC's previous release.
mkdb "$S/qrepo" foo-1-1 bar-1-1 bar-extra-1-1 baz-1-1
mkdir -p "$S/release"; rm -f "$S/release/omarchy-asus.db"; cp -L "$S/qrepo/omarchy-asus.db" "$S/release/"
recipe foo 1-1 foo; recipe bar 1-1 bar bar-extra; recipe new 1-1 newpkg
mkdb "$RR" foo-1-1
touch "$KD/sync-pending"; rm -f "$S/calls"
out=$(run_k); expect $? 3 "a first RC publish without our bar, which Quattro serves, is withheld (a regression)"
expect "$(exists "$KR")" 1 "no rc release is made"
uploaded; expect $? 1 "nothing uploaded"
grep -qx 'regression bar (recipes/bar)' "$KD/release-withheld" 2>/dev/null; expect $? 0 "release-withheld names bar"
grep -qx 'regression bar-extra (recipes/bar)' "$KD/release-withheld" 2>/dev/null; expect $? 0 "and its split package"
grep -q 'newpkg' "$KD/release-withheld" 2>/dev/null; expect $? 1 "the net-new newpkg is no regression"
grep -q 'regression bar ' <<<"$out"; expect $? 0 "the output names it"
expect "$(exists "$KD/sync-pending")" 0 "sync-pending is kept"
out=$(run_k --dry-run); expect $? 3 "a dry run says withheld too"

recipe baz 1-1 baz; printf 'waits for a G16 boot\n' >"$S/ws/recipes/baz/HOLD"
mkdb "$RR" foo-1-1 bar-1-1 bar-extra-1-1 baz-1-1
out=$(run_k); expect $? 0 "our foo, bar and the held baz go up; the net-new newpkg, not built yet, does not hold them"
grep -q 'missing newpkg' <<<"$out"; expect $? 0 "says newpkg goes up once built"
cmp -s "$KR/omarchy-asus.db" "$RR/omarchy-asus.db.tar.gz"; expect $? 0 "the rc release serves it"
expect "$(exists "$KD/release-withheld")" 1 "release-withheld is removed"
expect "$(exists "$KD/sync-pending")" 1 "sync-pending is cleared"

mkdb "$RR" foo-1-1 bar-1-1 bar-extra-1-1
out=$(run_k); expect $? 3 "dropping the held baz, which the release serves, is a regression"
grep -qx 'regression baz (recipes/baz)' "$KD/release-withheld" 2>/dev/null; expect $? 0 "release-withheld names baz"

recipe foo 1-2 foo; recipe bar 1-2 bar bar-extra
mkdb "$RR" foo-1-2 bar-1-1 bar-extra-1-1 baz-1-1
out=$(run_k); expect $? 0 "foo 1-2 is ready and goes up; bar, not ready at 1-2, keeps our 1-1"
cmp -s "$KR/omarchy-asus.db" "$RR/omarchy-asus.db.tar.gz"; expect $? 0 "the rc release serves foo 1-2 next to our bar 1-1"

mkdb "$RR" foo-1-2 baz-1-1
rm -f "$S/calls"
out=$(run_k); expect $? 3 "a db without our bar while recipes/bar exists is withheld, never stock in its place"
uploaded; expect $? 1 "nothing uploaded"
touch "$S/ws/recipes/bar/FAIL"
out=$(run_k); expect $? 3 "with recipes/bar unreadable, a missing bar the release served is still withheld"
grep -qx 'unknown bar (recipes/bar unreadable)' "$KD/release-withheld" 2>/dev/null; expect $? 0 "release-withheld says it cannot tell"
mkdb "$RR" foo-1-2 bar-1-1 bar-extra-1-1 baz-1-1
out=$(run_k); expect $? 0 "an unreadable recipe whose packages are all in the db holds nothing"
rm "$S/ws/recipes/bar/FAIL"

mv "$S/release" "$S/release.away"
mkdb "$RR" foo-1-2 baz-1-1
out=$(run_k); expect $? 1 "a Quattro release that cannot be read refuses"
grep -q 'cannot read the Quattro release' <<<"$out"; expect $? 0 "says so"
mv "$S/release.away" "$S/release"

rm -rf "$S/ws/recipes/bar"
out=$(run_k); expect $? 0 "once recipes/bar is removed (upstream replaced our patch), the db without bar goes up"
cmp -s "$KR/omarchy-asus.db" "$RR/omarchy-asus.db.tar.gz"; expect $? 0 "the rc release serves it"

mv "$S/ws/recipes" "$S/ws/recipes.away"
rm -f "$S/calls"
mkdb "$RR" foo-1-2
out=$(run_k); expect $? 1 "no recipes/ to check against refuses"
grep -q 'cannot check' <<<"$out"; expect $? 0 "says it cannot check"
uploaded; expect $? 1 "nothing uploaded"
mv "$S/ws/recipes.away" "$S/ws/recipes"
exit $fail
