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
# offer_g16_fixes installing a package that isn't installed yet (asus-rog-nkey-winlock, its
# udev rule copied in by hand), the same rule:
#   7. identical unowned rule: pacman -S gets --overwrite for the real path
#   8. differing unowned rule: names the path, installs nothing, the file is unchanged,
#      and the script goes on (exit 0)
#   9. identical, under --dry-run: the printed pacman -S line has the --overwrite
# asus-rog-nkey-winlock depending on a second repo package that isn't installed either
# (omarchy-asus-dep-test>=1, its udev rule copied in by hand), which pacman -S pulls in (#111):
#  10. identical unowned rule of the dependency: pacman -S gets --overwrite for its real path
#  11. differing unowned rule of the dependency: names the path, installs nothing, the file
#      is unchanged, and the script goes on (exit 0)
# Usage: tests/ci/omarchy-asus-setup-etc-takeover.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
export STUB_STATE=$S
P=/etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf
DROP=$S/root$P
SAVED=$S/root/var/lib/omarchy-asus/replaced$P
WP=/etc/udev/rules.d/70-g16-winlock-hidraw.rules
WRULE=$S/root$WP
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }

# Without the source guard, sourcing the script would run the whole setup.
grep -q OMARCHY_ASUS_SETUP_SOURCE_ONLY "$W/bin/omarchy-asus-setup" ||
    { echo "FAIL: bin/omarchy-asus-setup has no OMARCHY_ASUS_SETUP_SOURCE_ONLY guard"; exit 1; }

mkdir -p "$S/bin" "$S/obin" "$S/fixtures" "$S/fx/db/omarchy-settings-4.0.5-1.1" \
    "$S/fx/pkg${P%/*}" "$S/fx/db/asus-rog-nkey-winlock-1-1" "$S/fx/wpkg${WP%/*}" "$S/home"

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
    -Qu) exit 0 ;;
    -Su) exit 0 ;;
    -Si) [[ $2 == omarchy-asus/* ]] ;;
    -S) exit 0 ;;
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
# A G16 package that is not installed (never in $S/installed), for offer_g16_fixes.
printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", MODE="0660"\n' >"$S/wpackaged.rules"
printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", MODE="0666"\n' >"$S/wdifferent.rules"
cp "$S/wpackaged.rules" "$S/fx/wpkg$WP"
cat >"$S/fx/db/asus-rog-nkey-winlock-1-1/desc" <<'EOF'
%NAME%
asus-rog-nkey-winlock

%VERSION%
1-1

%FILENAME%
asus-rog-nkey-winlock-1-1-any.pkg.tar.zst
EOF
cat >"$S/fx/db/asus-rog-nkey-winlock-1-1/files" <<'EOF'
%FILES%
etc/
etc/udev/
etc/udev/rules.d/
etc/udev/rules.d/70-g16-winlock-hidraw.rules
usr/bin/g16-winlock
EOF
tar -cf "$S/fixtures/omarchy-asus.files" -C "$S/fx/db" omarchy-settings-4.0.5-1.1 asus-rog-nkey-winlock-1-1
cp "$S/fixtures/omarchy-asus.files" "$S/fixtures/omarchy-asus.db"
tar -cf "$S/fixtures/omarchy-settings-4.0.5-1.1-any.pkg.tar.zst" -C "$S/fx/pkg" "${P#/}"
tar -cf "$S/fixtures/asus-rog-nkey-winlock-1-1-any.pkg.tar.zst" -C "$S/fx/wpkg" "${WP#/}"
for f in omarchy-asus.db omarchy-asus.files omarchy-settings-4.0.5-1.1-any.pkg.tar.zst \
    asus-rog-nkey-winlock-1-1-any.pkg.tar.zst; do
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
# path_without TAG NAME...: $S/bin and BASE_PATH, without the stubs in $S/obin and without
# any real NAME the host has. On an Omarchy host that is /usr/bin, so a directory holding
# one is replaced by a copy of its links without them, rather than dropped with its tools.
path_without() {
    local tag=$1 out=$S/bin d e n=0 hide
    local -a dirs
    shift
    IFS=: read -ra dirs <<<"$BASE_PATH"
    for d in "${dirs[@]}"; do
        [[ -n $d && -d $d ]] || continue
        hide=0
        for e in "$@"; do
            if [[ -x $d/$e ]]; then hide=1; fi
        done
        if ((hide)); then
            n=$((n + 1))
            mkdir -p "$S/shim-$tag$n"
            for e in "$d"/*; do
                [[ " $* " == *" ${e##*/} "* ]] && continue
                ln -s "$e" "$S/shim-$tag$n/${e##*/}"
            done
            out+=:$S/shim-$tag$n
        else
            out+=:$d
        fi
    done
    echo "$out"
}
NO_APPLY=$(path_without apply omarchy-asus-g16-apply)
# run_g16 [dry run 0|1]: source the script and run offer_g16_fixes for asus-rog-nkey-winlock
# alone, with a 'yes' to every question and no omarchy-asus-g16-apply on PATH; sets rc.
run_g16() {
    local dry=${1:-0}
    (
        set --
        export OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 OMARCHY_ASUS_SETUP_ROOT=$S/root OMARCHY_ASUS_SETUP_TTY=/dev/null
        export HOME=$S/home PATH=$NO_APPLY
        # retire_local_winlock reads the user unit dir from XDG_CONFIG_HOME: keep it under HOME.
        unset XDG_CONFIG_HOME
        # shellcheck source=/dev/null
        . "$W/bin/omarchy-asus-setup"
        touch "$TMP/key.gpg"
        # The --dry-run branch also runs retire_local_winlock: keep it off the host's /etc.
        # shellcheck disable=SC2034 # read by the sourced functions
        FORCE=1 DRY_RUN=$dry WINLOCK_UDEV_DIR=$S/no-udev-rules
        # shellcheck disable=SC2034 # read by offer_g16_fixes
        G16_PKGS=(asus-rog-nkey-winlock)
        confirm() { return 0; }
        preview_repo
        offer_g16_fixes
    ) </dev/null >"$S/out" 2>&1
    rc=$?
}
# g16_rule <content file>: the hand-copied udev rule of asus-rog-nkey-winlock.
g16_rule() {
    mkdir -p "${WRULE%/*}"
    cp "$1" "$WRULE"
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
expect "$((rc != 0))" 1 "exits non-zero"
expect "$(same "$S/packaged.conf" "$DROP")" 0 "the original is back"
expect "$(has "put back $P" "$S/out")" 0 "says it put it back"
expect "$(exists "$SAVED")" 1 "no saved copy left"

echo "== 3. differing unowned drop-in"
reset "$S/different.conf"
run
expect "$((rc != 0))" 1 "exits non-zero"
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
NO_UPDATE=$(path_without update omarchy-update omarchy)
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
expect "$((rc != 0))" 1 "exits non-zero"
expect "$(has "does not verify" "$S/out")" 0 "says the signature does not verify"
expect "$(exists "$S/omarchy.log")" 1 "omarchy update never ran"

echo "== 7. G16 install, identical unowned udev rule"
reset "$S/packaged.conf"
g16_rule "$S/wpackaged.rules"
run_g16
expect "$rc" 0 "exits 0"
expect "$(has "$WP: not owned by any package and identical" "$S/out")" 0 "check names the path"
expect "$(has "pacman -S --needed --overwrite $WP asus-rog-nkey-winlock" "$S/sudo.log")" 0 \
    "pacman -S overwrites the real path"
expect "$(same "$S/wpackaged.rules" "$WRULE")" 0 "the file is in place"

echo "== 8. G16 install, differing unowned udev rule"
reset "$S/packaged.conf"
g16_rule "$S/wdifferent.rules"
run_g16
expect "$rc" 0 "exits 0 (the upgrade already ran)"
expect "$(has "$WP" "$S/out")" 0 "names the path"
expect "$(has "were not installed" "$S/out")" 0 "says the G16 packages were not installed"
expect "$(same "$S/wdifferent.rules" "$WRULE")" 0 "the file is unchanged"
n=$(grep -cF 'pacman -S ' "$S/sudo.log" 2>/dev/null)
expect "${n:-0}" 0 "nothing installed"

echo "== 9. G16 install under --dry-run, identical unowned udev rule"
reset "$S/packaged.conf"
g16_rule "$S/wpackaged.rules"
run_g16 1
expect "$rc" 0 "exits 0"
expect "$(has "[dry-run] sudo pacman -S --needed --overwrite $WP asus-rog-nkey-winlock" "$S/out")" 0 \
    "prints pacman -S with the --overwrite"
expect "$(exists "$S/sudo.log")" 1 "nothing ran through sudo"

# From here on, asus-rog-nkey-winlock depends on a second repo package that isn't installed
# (never in $S/installed). glibc is in no repo database here, so it is left out of the check.
DP=/etc/udev/rules.d/71-dep-test.rules
DRULE=$S/root$DP
mkdir -p "$S/fx/db/omarchy-asus-dep-test-1-1" "$S/fx/dpkg${DP%/*}"
printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", GROUP="input"\n' >"$S/dpackaged.rules"
printf 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", GROUP="users"\n' >"$S/ddifferent.rules"
cp "$S/dpackaged.rules" "$S/fx/dpkg$DP"
cat >"$S/fx/db/omarchy-asus-dep-test-1-1/desc" <<'EOF'
%NAME%
omarchy-asus-dep-test

%VERSION%
1-1

%FILENAME%
omarchy-asus-dep-test-1-1-any.pkg.tar.zst
EOF
cat >"$S/fx/db/omarchy-asus-dep-test-1-1/files" <<'EOF'
%FILES%
etc/
etc/udev/
etc/udev/rules.d/
etc/udev/rules.d/71-dep-test.rules
EOF
# The versioned form: the check must strip it down to the package name.
printf '\n%%DEPENDS%%\nglibc\nomarchy-asus-dep-test>=1\n' >>"$S/fx/db/asus-rog-nkey-winlock-1-1/desc"
tar -cf "$S/fixtures/omarchy-asus.files" -C "$S/fx/db" omarchy-settings-4.0.5-1.1 asus-rog-nkey-winlock-1-1 \
    omarchy-asus-dep-test-1-1
cp "$S/fixtures/omarchy-asus.files" "$S/fixtures/omarchy-asus.db"
tar -cf "$S/fixtures/omarchy-asus-dep-test-1-1-any.pkg.tar.zst" -C "$S/fx/dpkg" "${DP#/}"
echo signature >"$S/fixtures/omarchy-asus-dep-test-1-1-any.pkg.tar.zst.sig"
# dep_rule <content file>: the hand-copied udev rule of the dependency.
dep_rule() {
    mkdir -p "${DRULE%/*}"
    cp "$1" "$DRULE"
}

echo "== 10. G16 install, identical unowned udev rule of a repo dependency"
reset "$S/packaged.conf"
dep_rule "$S/dpackaged.rules"
run_g16
expect "$rc" 0 "exits 0"
expect "$(has "omarchy-asus-dep-test-1-1-any.pkg.tar.zst" "$S/curl.log")" 0 "the dependency's package is checked"
expect "$(has "$DP: not owned by any package and identical to omarchy-asus-dep-test's copy" "$S/out")" 0 \
    "check names the path and the dependency"
expect "$(has "pacman -S --needed --overwrite $DP asus-rog-nkey-winlock" "$S/sudo.log")" 0 \
    "pacman -S overwrites the dependency's real path"
expect "$(same "$S/dpackaged.rules" "$DRULE")" 0 "the file is in place"

echo "== 11. G16 install, differing unowned udev rule of a repo dependency"
reset "$S/packaged.conf"
dep_rule "$S/ddifferent.rules"
run_g16
expect "$rc" 0 "exits 0 (the upgrade already ran)"
expect "$(has "$DP: not owned by any package and different" "$S/out")" 0 "names the path"
expect "$(has "were not installed" "$S/out")" 0 "says the G16 packages were not installed"
expect "$(same "$S/ddifferent.rules" "$DRULE")" 0 "the file is unchanged"
n=$(grep -cF 'pacman -S ' "$S/sudo.log" 2>/dev/null)
expect "${n:-0}" 0 "nothing installed"

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
