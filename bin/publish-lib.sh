# Shared publication helpers for bin/publish, bin/unpublish, bin/sync-release (sourced after env.sh).
# A change to the local repo is one transaction:
#   pub_lock                  serialize on $DATA/publish.lock (exit 75 after
#                             PUBLISH_LOCK_WAIT seconds, default 600), repair a swap a
#                             killed run left half done
#   pub_mark_pending <why>    journal it in $DATA/sync-pending before the repo changes
#   pub_stage                 build the change in $REPO_DIR.new ($PUB_STAGE), a hardlink
#                             copy whose db files are unshared
#   pub_verify_repo <dir>     every signature by $SIGN_KEY, every package the db names present
#   pub_commit / pub_abort    swap the staging dir in, or drop it (the live repo untouched)
# bin/sync-release calls pub_clear_pending once the release matches the repo.

pub_lock() {
    # A child of a lock holder (it exported this) runs under the parent's lock.
    if [[ ${OMARCHY_ASUS_PUBLISH_LOCKED:-} == 1 ]]; then return 0; fi
    mkdir -p "$DATA" || return 1
    exec {PUB_LOCK_FD}>"$DATA/publish.lock" || return 1
    if ! flock -w "${PUBLISH_LOCK_WAIT:-600}" "$PUB_LOCK_FD"; then
        echo "another publish/unpublish/sync-release holds $DATA/publish.lock" >&2
        exit 75
    fi
    export OMARCHY_ASUS_PUBLISH_LOCKED=1
    pub_recover
}

pub_recover() {
    # pub_commit renames $REPO_DIR to .prev, then .new to $REPO_DIR: a crash between
    # the two leaves only .prev, the last verified repo.
    if [[ ! -e $REPO_DIR && -e $REPO_DIR.prev ]]; then
        mv "$REPO_DIR.prev" "$REPO_DIR" || return 1
        echo "recovered $REPO_DIR from an interrupted swap" >&2
    elif [[ -e $REPO_DIR.prev ]]; then
        rm -rf "$REPO_DIR.prev" || return 1
    fi
    rm -rf "$REPO_DIR.new" || return 1
}

pub_mark_pending() {
    mkdir -p "$DATA" || return 1
    echo "$(date +%s) $*" >>"$DATA/sync-pending" || return 1
}

pub_clear_pending() {
    rm -f "$DATA/sync-pending"
}

pub_verify_sig() {  # pub_verify_sig <file> [<sigfile>]: 0 only for a good signature by $SIGN_KEY
    local file=$1 sig=${2:-$1.sig} name key status rc=0
    name=$(basename "$file")
    key=${SIGN_KEY:-}; key=${key//[[:space:]]/}
    if [[ -z $key ]]; then
        echo "signature check failed for $name: no signing key fingerprint" >&2; return 1
    fi
    if [[ ! -f $file ]]; then
        echo "signature check failed for $name: file missing" >&2; return 1
    fi
    if [[ ! -f $sig ]]; then
        echo "signature check failed for $name: $(basename "$sig") missing" >&2; return 1
    fi
    status=$(gpg --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null) || rc=$?
    if ((rc != 0)); then
        echo "signature check failed for $name: gpg --verify exited $rc" >&2; return 1
    fi
    # VALIDSIG <signing key fpr> ... <primary key fpr>
    if ! awk -v k="${key^^}" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && (toupper($3) == k || toupper($NF) == k) {f = 1}
            END {exit !f}' <<<"$status"; then
        echo "signature check failed for $name: not signed by $key" >&2; return 1
    fi
}

pub_verify_repo() {  # pub_verify_repo <dir>: the repo in <dir> is complete and signed by $SIGN_KEY
    local dir=$1 base link target listing descs names f rc=0
    for base in "$REPO_NAME.db" "$REPO_NAME.files"; do
        if [[ ! -f $dir/$base.tar.gz ]]; then
            echo "repo check failed: $base.tar.gz missing" >&2; return 1
        fi
        pub_verify_sig "$dir/$base.tar.gz" || return 1
        for link in "$base" "$base.sig"; do
            target=$base.tar.gz; [[ $link == *.sig ]] && target=$base.tar.gz.sig
            if [[ ! -e $dir/$link ]]; then
                echo "repo check failed: $link missing" >&2; return 1
            fi
            if [[ $(readlink -f "$dir/$link") != "$(readlink -f "$dir/$target")" ]] \
                    && ! cmp -s "$dir/$link" "$dir/$target"; then
                echo "repo check failed: $link is not $target" >&2; return 1
            fi
        done
    done
    # Every package the db names must be here with a good signature, or pacman would
    # 404 or refuse it. An empty db names none (and has no */desc to extract).
    listing=$(bsdtar -tf "$dir/$REPO_NAME.db.tar.gz") || rc=$?
    if ((rc != 0)); then
        echo "repo check failed: cannot list $REPO_NAME.db.tar.gz (bsdtar exited $rc)" >&2; return 1
    fi
    grep -q '/desc$' <<<"$listing" || return 0
    descs=$(bsdtar -xOf "$dir/$REPO_NAME.db.tar.gz" '*/desc') || rc=$?
    if ((rc != 0)); then
        echo "repo check failed: cannot read $REPO_NAME.db.tar.gz (bsdtar exited $rc)" >&2; return 1
    fi
    names=$(awk 'p {print; p=0} /^%FILENAME%$/ {p=1}' <<<"$descs")
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        if [[ $f == */* || $f == . || $f == .. ]]; then
            echo "repo check failed: the db names a bad file name" >&2; return 1
        fi
        if [[ ! -f $dir/$f ]]; then
            echo "repo check failed: the db names $f but it is missing" >&2; return 1
        fi
        pub_verify_sig "$dir/$f" || return 1
    done <<<"$names"
}

pub_stage() {
    PUB_STAGE=$REPO_DIR.new
    rm -rf "$PUB_STAGE" || return 1
    if [[ -e $REPO_DIR ]]; then
        cp -al "$REPO_DIR" "$PUB_STAGE" || return 1
    else
        mkdir -p "$PUB_STAGE" || return 1
    fi
    # repo-add/repo-remove and gpg may rewrite the db files in place: give staging its
    # own copies so nothing written there reaches the live repo through a hardlink.
    local f
    for f in "$PUB_STAGE/$REPO_NAME".db* "$PUB_STAGE/$REPO_NAME".files*; do
        [[ -f $f && ! -L $f ]] || continue
        cp -p "$f" "$f.tmp" || return 1
        mv -f "$f.tmp" "$f" || return 1
    done
}

pub_commit() {
    rm -rf "$REPO_DIR.prev" || return 1
    if [[ -e $REPO_DIR ]]; then
        mv "$REPO_DIR" "$REPO_DIR.prev" || return 1
    fi
    if ! mv "$PUB_STAGE" "$REPO_DIR"; then
        [[ -e $REPO_DIR.prev ]] && mv "$REPO_DIR.prev" "$REPO_DIR"
        return 1
    fi
    # committed: a .prev left here is removed by the next pub_recover
    rm -rf "$REPO_DIR.prev" || echo "warning: could not remove $REPO_DIR.prev" >&2
}

pub_abort() {
    if [[ -n ${PUB_STAGE:-} && $PUB_STAGE != "$REPO_DIR" ]]; then
        rm -rf "$PUB_STAGE"
    fi
}
