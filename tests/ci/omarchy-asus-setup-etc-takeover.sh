#!/bin/bash
# bin/omarchy-asus-setup and an /etc file the upgrade installs that no package owns
# (#86), offline: the script is sourced with OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 and its
# /etc paths live under a temp root; pacman, vercmp, sudo, gpgv, curl, omarchy and
# omarchy-update are stubs, and the repo files database and the package are plain tars.
#   1. identical unowned drop-in: taken over; omarchy update runs with it moved aside,
#      the package's copy is in place afterwards and no saved copy is left
#   2. same, but the upgrade fails: the original is put back and the status is non-zero
#   3. differing unowned drop-in: the check stops, names the path, changes nothing, and
#      omarchy update never runs
#   4. a package owns the path: nothing is taken over, the file is untouched
#   5. no omarchy-update: pacman -Su gets --overwrite for the real path, nothing moves
#   6. a bad signature: preview_repo stops
# Usage: tests/ci/omarchy-asus-setup-etc-takeover.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
export STUB_STATE=$S
P=/etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf
DROP=$S/root$P
SAVED=$S/root/var/lib/omarchy-asus/replaced$P
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }

# Without the source guard, sourcing the script would run the whole setup.
grep -q OMARCHY_ASUS_SETUP_SOURCE_ONLY "$W/bin/omarchy-asus-setup" ||
    { echo "FAIL: bin/omarchy-asus-setup has no OMARCHY_ASUS_SETUP_SOURCE_ONLY guard"; exit 1; }

mkdir -p "$S/bin" "$S/obin" "$S/fixtures" "$S/fx/db/omarchy-settings-4.0.5-1.1" \
    "$S/fx/pkg${P%/*}"

# The CI host has GNU tar and maybe no bsdtar; GNU tar needs --wildcards for '*/desc'.
if ! command -v bsdtar >/dev/null; then
    cat >"$S/bin/bsdtar" <<'STUB'
#!/bin/bash
exec tar --wildcards "$@"
STUB
fi
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
S=$STUB_STATE
printf '%s\n' "$*" >>"$S/pacman.log"
case $1 in
    -Q) grep -qxF "$2" "$S/installed" 2>/dev/null || exit 1; echo "$2 4.0.5-1" ;;
    -Qo) grep -qxF "$2" "$S/owned" 2>/dev/null || exit 1; echo "$2 is owned by omarchy-settings 4.0.5-1" ;;
    -Su) exit 0 ;;
    -S*) exit 1 ;;
esac
STUB
cat >"$S/bin/vercmp" <<'STUB'
#!/bin/bash
if [[ $1 == "$2" ]]; then echo 0; else echo 1; fi
STUB
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$STUB_STATE/sudo.log"
exec "$@"
STUB
cat >"$S/bin/gpgv" <<'STUB'
#!/bin/bash
[[ ! -e $STUB_STATE/badsig ]]
STUB
cat >"$S/bin/curl" <<'STUB'
#!/bin/bash
out='' url=''
while (($#)); do
    case $1 in
        -o) out=$2; shift 2 ;;
        --proto) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >>"$STUB_STATE/curl.log"
f=$STUB_STATE/fixtures/${url##*/}
[[ -f $f && -n $out ]] || exit 22
cp "$f" "$out"
STUB
cat >"$S/obin/omarchy-update" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$S/obin/omarchy" <<'STUB'
#!/bin/bash
S=$STUB_STATE
f=$S/root/etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf
if [[ -e $f ]]; then echo present >>"$S/omarchy.log"; else echo absent >>"$S/omarchy.log"; fi
[[ -e $S/upgrade-fails ]] && exit 1
[[ -e $f ]] || { mkdir -p "${f%/*}" && cp "$S/packaged.conf" "$f"; }
exit 0
STUB
chmod +x "$S"/bin/* "$S"/obin/*

# The packaged drop-in, the repo files database (also served as the plain database) and the package.
printf '[Service]\nExecStartPost=/usr/bin/true\n' >"$S/packaged.conf"
printf '[Service]\nExecStartPost=/usr/bin/false\n' >"$S/different.conf"
cp "$S/packaged.conf" "$S/fx/pkg$P"
cat >"$S/fx/db/omarchy-settings-4.0.5-1.1/desc" <<'EOF'
%NAME%
omarchy-settings

%VERSION%
4.0.5-1.1

%FILENAME%
omarchy-settings-4.0.5-1.1-any.pkg.tar.zst
EOF
cat >"$S/fx/db/omarchy-settings-4.0.5-1.1/files" <<'EOF'
%FILES%
etc/
etc/systemd/system/asusd.service.d/
etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf
usr/bin/x
EOF
tar -cf "$S/fixtures/omarchy-asus.files" -C "$S/fx/db" omarchy-settings-4.0.5-1.1
cp "$S/fixtures/omarchy-asus.files" "$S/fixtures/omarchy-asus.db"
tar -cf "$S/fixtures/omarchy-settings-4.0.5-1.1-any.pkg.tar.zst" -C "$S/fx/pkg" "${P#/}"
for f in omarchy-asus.db omarchy-asus.files omarchy-settings-4.0.5-1.1-any.pkg.tar.zst; do
    echo signature >"$S/fixtures/$f.sig"
done

BASE_PATH=$PATH
export PATH=$S/bin:$S/obin:$BASE_PATH

# reset <drop-in content file>: a fresh root with that drop-in, omarchy-settings installed.
reset() {
    rm -rf "$S/root" "$S"/*.log "$S/owned" "$S/badsig" "$S/upgrade-fails"
    mkdir -p "${DROP%/*}"
    cp "$1" "$DROP"
    echo omarchy-settings >"$S/installed"
}
# Source the script in a subshell and run the check and the upgrade; sets rc.
run() {
    (
        set --
        export OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 OMARCHY_ASUS_SETUP_ROOT=$S/root OMARCHY_ASUS_SETUP_TTY=/dev/null
        # shellcheck source=/dev/null
        . "$W/bin/omarchy-asus-setup"
        touch "$TMP/key.gpg"
        preview_repo
        check_unowned_etc
        run_upgrade
    ) </dev/null >"$S/out" 2>&1
    rc=$?
}
has() { grep -qF -- "$1" "$2" 2>/dev/null; echo $?; }
same() { cmp -s "$1" "$2"; echo $?; }
exists() { [[ -e $1 ]]; echo $?; }

echo "== 1. identical unowned drop-in"
reset "$S/packaged.conf"
run
expect "$rc" 0 "exits 0"
expect "$(has "$P: not owned by any package and identical" "$S/out")" 0 "check names the path"
expect "$(cat "$S/omarchy.log" 2>/dev/null)" absent "omarchy update ran with the path moved aside"
expect "$(same "$S/packaged.conf" "$DROP")" 0 "the packaged copy is in place"
expect "$(has "took over $P" "$S/out")" 0 "says it took it over"
expect "$(exists "$SAVED")" 1 "no saved copy left"

echo "== 2. identical unowned drop-in, the upgrade fails"
reset "$S/packaged.conf"
: >"$S/upgrade-fails"
run
expect "$([[ $rc != 0 ]]; echo $?)" 0 "exits non-zero"
expect "$(same "$S/packaged.conf" "$DROP")" 0 "the original is back"
expect "$(has "put back $P" "$S/out")" 0 "says it put it back"
expect "$(exists "$SAVED")" 1 "no saved copy left"

echo "== 3. differing unowned drop-in"
reset "$S/different.conf"
run
expect "$([[ $rc != 0 ]]; echo $?)" 0 "exits non-zero"
expect "$(has "$P" "$S/out")" 0 "names the path"
expect "$(has "Nothing was changed" "$S/out")" 0 "says nothing was changed"
expect "$(same "$S/different.conf" "$DROP")" 0 "the file is unchanged"
expect "$(exists "$S/omarchy.log")" 1 "omarchy update never ran"

echo "== 4. a package owns the path"
reset "$S/different.conf"
echo "$P" >"$S/owned"
run
expect "$rc" 0 "exits 0"
expect "$(has "no unowned /etc files" "$S/out")" 0 "nothing unowned"
expect "$(has "took over" "$S/out")" 1 "nothing taken over"
expect "$(same "$S/different.conf" "$DROP")" 0 "the file is untouched"
expect "$(exists "$S/sudo.log")" 1 "nothing moved"

echo "== 5. no omarchy-update"
# A PATH without the stub, and without any real omarchy-update the host has.
NO_UPDATE=$S/bin
IFS=: read -ra dirs <<<"$BASE_PATH"
for d in "${dirs[@]}"; do
    [[ -n $d && ! -x $d/omarchy-update ]] && NO_UPDATE+=:$d
done
reset "$S/packaged.conf"
PATH=$NO_UPDATE
run
PATH=$S/bin:$S/obin:$BASE_PATH
expect "$rc" 0 "exits 0"
expect "$(has "pacman -Su --overwrite $P" "$S/sudo.log")" 0 "pacman -Su overwrites the real path"
expect "$(has "mv" "$S/sudo.log")" 1 "nothing moved"
expect "$(same "$S/packaged.conf" "$DROP")" 0 "the file is in place"

echo "== 6. bad signature"
reset "$S/packaged.conf"
: >"$S/badsig"
run
expect "$([[ $rc != 0 ]]; echo $?)" 0 "exits non-zero"
expect "$(has "does not verify" "$S/out")" 0 "says the signature does not verify"
expect "$(exists "$S/omarchy.log")" 1 "omarchy update never ran"

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
