#!/bin/bash
# shellcheck disable=SC2034  # the globals are read by the bin/auto-update functions eval'd below
# A release-cohort member publishes next to a partner already published at its version (#127),
# as bin/publish (bin/release-cohort check-publish) allows. The real publish_files runs with
# the real bin/release-cohort, a stub bin/publish and a built repo db:
#   1. partner in the repo db at the same version: the member is published alone
#   2. partner in the db at another version: held back (3), nothing published
#   3. partner absent from the db and not staged: held back (3)
#   4. partner staged from the base branch, absent from the db: both go out in one call
# Offline: no network, no sudo, no bwrap.
set -u
for t in python3 bsdtar; do
    command -v "$t" >/dev/null && continue
    # The runner ships both (.github/workflows/lint.yml): a skip there is a failure
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected '$3', got '$2'"; fails=1; fi
}

# The function under test, verbatim from bin/auto-update.
for f in publish_files; do
    body=$(awk -v f="$f" 'index($0, f "() {") == 1, /^\}/' "$W/bin/auto-update")
    if [[ -z $body ]]; then echo "not ok - cannot extract $f() from bin/auto-update"; fails=1; continue; fi
    eval "$body"
done

# What it calls, stubbed.
as_user() { "$@"; }
note() { echo "[$1] $2"; }
srcinfo() { echo 'pkgname = omarchy'; }
ugit() { case $1 in fetch) return 0 ;; rev-parse) echo tree-settings ;; esac; }
pending_edit() { :; }
sync_now() { echo sync >>"$T/calls"; }
unset merged_pr built_tree

mode=full BASE_BRANCH=main
LIB=$T/lib STAGE_DIR=$T/stage REPO_DIR=$T/repo REPO_NAME=omarchy-asus
export OMARCHY_ASUS_WORKSPACE=$T/ws
mkdir -p "$LIB" "$STAGE_DIR" "$REPO_DIR" "$OMARCHY_ASUS_WORKSPACE/build" "$OMARCHY_ASUS_WORKSPACE/recipes/omarchy"
echo 'omarchy omarchy-settings' >"$OMARCHY_ASUS_WORKSPACE/build/cohorts.conf"
ln -s "$W/bin/release-cohort" "$LIB/release-cohort"
printf '#!/bin/bash\necho "publish $*" >>"%s"\n' "$T/calls" >"$LIB/publish"
chmod +x "$LIB/publish"
: >"$STAGE_DIR/omarchy-4.0.5-1.3-any.pkg.tar.zst"

mkdb() {  # mkdb <name-ver-rel>...: the repo db holds exactly these entries (repo-add layout)
    rm -rf "$T/dbsrc" "$REPO_DIR/$REPO_NAME.db.tar.gz"
    mkdir -p "$T/dbsrc"
    local e; for e; do mkdir -p "$T/dbsrc/$e"; : >"$T/dbsrc/$e/desc"; done
    (cd "$T/dbsrc" && bsdtar -czf "$REPO_DIR/$REPO_NAME.db.tar.gz" "$@")
}
calls() { : >"$T/calls"; }
publish_line() { grep '^publish' "$T/calls"; }

# 1. partner already published at the same version: the member goes out next to it
mkdb omarchy-settings-4.0.5-1.3 linux-omarchy-6.1-1.1; calls
rc=0; publish_files "$OMARCHY_ASUS_WORKSPACE/recipes/omarchy" 4.0.5-1.3 >"$T/out" 2>&1 || rc=$?
expect "1. partner published at 4.0.5-1.3: returns 0" "$rc" 0
expect "1. partner published at 4.0.5-1.3: bin/publish gets only the member" \
    "$(publish_line)" "publish $STAGE_DIR/omarchy-4.0.5-1.3-any.pkg.tar.zst"
expect "1. partner published at 4.0.5-1.3: synced" "$(grep -c '^sync$' "$T/calls")" 1
expect "1. partner published at 4.0.5-1.3: the note says why" \
    "$(grep -c 'omarchy-settings 4.0.5-1.3 is already published' "$T/out")" 1

# 2. partner published at another version: held back
mkdb omarchy-settings-4.0.5-1; calls
rc=0; publish_files "$OMARCHY_ASUS_WORKSPACE/recipes/omarchy" 4.0.5-1.3 >"$T/out" 2>&1 || rc=$?
expect "2. partner published at 4.0.5-1: held back" "$rc" 3
expect "2. partner published at 4.0.5-1: bin/publish not run" "$(grep -c '^publish' "$T/calls")" 0

# 3. partner absent from the db and not staged: held back
mkdb linux-omarchy-6.1-1.1; calls
rc=0; publish_files "$OMARCHY_ASUS_WORKSPACE/recipes/omarchy" 4.0.5-1.3 >"$T/out" 2>&1 || rc=$?
expect "3. partner absent: held back" "$rc" 3
expect "3. partner absent: bin/publish not run" "$(grep -c '^publish' "$T/calls")" 0

# 4. partner staged from the base branch, absent from the db: both in one bin/publish call
mkdb linux-omarchy-6.1-1.1; calls
echo 'tree-settings key' >"$STAGE_DIR/.staged-omarchy-settings"
: >"$STAGE_DIR/omarchy-settings-4.0.5-1.3-any.pkg.tar.zst"
rc=0; publish_files "$OMARCHY_ASUS_WORKSPACE/recipes/omarchy" 4.0.5-1.3 >"$T/out" 2>&1 || rc=$?
expect "4. partner staged: returns 0" "$rc" 0
expect "4. partner staged: bin/publish gets both" "$(publish_line)" \
    "publish $STAGE_DIR/omarchy-4.0.5-1.3-any.pkg.tar.zst $STAGE_DIR/omarchy-settings-4.0.5-1.3-any.pkg.tar.zst"
exit $fails
