#!/bin/bash
# bin/omarchy-asus-setup --channel quattro|rc (#167), offline: pacman, gpg, curl and
# omarchy-channel-set are stubs, HOME, pacman.conf and custom-repos.conf are temp files.
# The stub omarchy-channel-set rewrites the [omarchy] server the way Omarchy's does and puts
# the Include line back above it (the pre-refresh hook's job).
#   a. a first setup picks our channel from Omarchy's: rc with Omarchy rc, quattro with stable
#   b. --dry-run --channel rc: previews the rc-x86_64 database, prints the rc repo section
#      and 'omarchy-channel-set rc', changes no file
#   c. --channel rc: custom-repos.conf points at rc-x86_64, omarchy-channel-set rc runs,
#      both are on rc afterwards
#   d. --channel rc again: already there, omarchy-channel-set does not run
#   e. --channel quattro: back to the x86_64 release and omarchy-channel-set stable
#   f. the target channel's database can't be downloaded: stops, nothing changed
#   g. the repo is not set up: stops, nothing changed
#   h. an unknown channel: usage error
#   i. omarchy-channel-set rewrites the configs, then its upgrade fails: the switch stays
#      pending, a rerun runs omarchy-channel-set again (not "already on"), and only a
#      verified switch clears it
#   j. a package installed from us is not on the target channel (#201): listed in the dry run
#      before the confirm, and the switch refuses (nothing changed) without --force
#   k. the same with --force: switches, but the check after it fails and it stays pending
#   l. after the switch a package of ours is another repo's build (the kernel downgraded to
#      Omarchy's): the switch fails and stays pending; a rerun still checks it (from the pending
#      record) and passes once it is ours again
#   m. our kernel was withdrawn from the database the machine is on: still found as ours (a
#      .N pkgrel), as is a package whose packager is ours, and the switch refuses
# The pacman stub answers in German (Packer, [Installiert]) unless it runs with LC_ALL=C, as
# pacman does under LANG=de_DE.UTF-8, so every case above also checks that the script parses
# pacman in the C locale.
# Usage: tests/ci/setup-channel.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/home" "$S/dmi"
echo GA605KM >"$S/dmi/product_name"
FPR=$(sed -n 's/^FPR=//p' "$W/bin/omarchy-asus-setup")
# pacman: -Q NAME and -Qi from $PKG_Q ("name version [packager]" lines; none: nothing
# installed), -Sl [REPO] from $PKG_SL (pacman -Sl lines). Outside the C locale, -Qi and -Sl
# print German, as pacman does under LANG=de_DE.UTF-8.
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
de=1; [[ ${LC_ALL:-} == C ]] && de=0
case ${1:-} in
    -Q) [[ -f ${PKG_Q:-} ]] && awk -v n="${2:-}" '$1 == n { print $1, $2; f = 1 } END { exit !f }' "$PKG_Q" ;;
    -Qi) [[ -f ${PKG_Q:-} ]] && awk -v de=$de '{ printf "Name            : %s\nVersion         : %s\n%s: %s\n\n", $1, $2,
        (de ? "Packer          " : "Packager        "), ($3 == "" ? "Unknown Packager" : $3) }' "$PKG_Q"; exit 0 ;;
    -Sl) [[ -f ${PKG_SL:-} ]] && awk -v r="${2:-}" -v de=$de 'r == "" || $1 == r {
        if (de) { sub(/\[installed\]/, "[Installiert]"); sub(/\[installed:/, "[Installiert:") } print }' "$PKG_SL"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
# bsdtar -xOf DB '*/desc': the target database's entries from $TARGET_DESC; anything else succeeds
cat >"$S/bin/bsdtar" <<'STUB'
#!/bin/bash
[[ ${1:-} == -xOf && -f ${TARGET_DESC:-} ]] && cat "$TARGET_DESC"
exit 0
STUB
cat >"$S/bin/gpg" <<STUB
#!/bin/bash
# --show-keys: the expected key; --dearmor -o FILE: an empty keyring
if [[ " \$* " == *" --show-keys "* ]]; then printf 'pub:-:255:22:X:1::::\nfpr:::::::::%s:\n' "$FPR"; fi
while ((\$#)); do [[ \$1 == -o ]] && : >"\$2"; shift; done
exit 0
STUB
# curl -o FILE URL: logs the URL; fails for URLs matching \$CURL_FAIL
cat >"$S/bin/curl" <<'STUB'
#!/bin/bash
out='' url=''
while (($#)); do
    case $1 in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac
    shift
done
echo "$url" >>"$CURL_LOG"
[[ -n ${CURL_FAIL:-} && $url == *$CURL_FAIL* ]] && exit 22
[[ -n $out ]] && echo stub >"$out"
exit 0
STUB
cat >"$S/bin/omarchy-channel-set" <<'STUB'
#!/bin/bash
echo "omarchy-channel-set $*" >>"$OCS_LOG"
printf '[options]\n\nInclude = %s\n\n[omarchy]\nServer = https://pkgs.omarchy.org/%s/$arch\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' \
    "$OMARCHY_ASUS_CUSTOM_REPOS" "$1" >"$OMARCHY_ASUS_PACMAN_CONF"
# PKG_SL_AFTER: what pacman -Sl shows after its -Syyuu
[[ -f ${PKG_SL_AFTER:-} ]] && cp "$PKG_SL_AFTER" "$PKG_SL"
# OCS_FAIL=1: the configs are rewritten, then the -Syyuu / migrations fail
[[ -z ${OCS_FAIL:-} ]]
STUB
for c in pacman-key gpgv vercmp; do printf '#!/bin/bash\nexit 0\n' >"$S/bin/$c"; done
printf '#!/bin/bash\nexec "$@"\n' >"$S/bin/sudo"
chmod +x "$S"/bin/*
printf 'y\n' >"$S/tty"
export PATH=$S/bin:$PATH HOME=$S/home CURL_LOG=$S/curl.log OCS_LOG=$S/ocs.log
unset LC_ALL XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME CURL_FAIL OCS_FAIL PKG_Q PKG_SL PKG_SL_AFTER TARGET_DESC
export OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_CUSTOM_REPOS=$S/custom-repos.conf \
    OMARCHY_ASUS_SETUP_TTY=$S/tty OMARCHY_ASUS_SNAPPER_CONFIG=$S/no-snapper OMARCHY_ASUS_DMI_DIR=$S/dmi
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
conf() {  # conf <stable|rc>: pacman.conf on that Omarchy channel, our Include line above it
    printf '[options]\n\nInclude = %s\n\n[omarchy]\nServer = https://pkgs.omarchy.org/%s/$arch\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' \
        "$OMARCHY_ASUS_CUSTOM_REPOS" "$1" >"$S/pacman.conf"
}
snippet() {  # snippet <prefix>: custom-repos.conf with our section on .../download/<prefix>$arch
    printf '[omarchy-asus]\nSigLevel = Required\nServer = https://github.com/omarchy-asus/omarchy-asus/releases/download/%s$arch\n' \
        "$1" >"$S/custom-repos.conf"
}
setup() { rm -f "$S/curl.log" "$S/ocs.log"; "$W/bin/omarchy-asus-setup" --force "$@" >"$S/out" 2>&1; }
server() { sed -n 's/^Server = //p' "$1"; }
sums() { sha256sum "$S/pacman.conf" "$S/custom-repos.conf" 2>/dev/null; }

echo "== a. a first setup follows Omarchy's channel"
for pair in rc:rc stable:quattro; do
    conf "${pair%%:*}"
    got=$(OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 bash -c 'f=$1; shift; source "$f" && set_channel && echo "$CHANNEL $GH_TAG $DB_URL"' _ \
        "$W/bin/omarchy-asus-setup" 2>/dev/null)
    tag=x86_64; [[ ${pair#*:} == rc ]] && tag=rc-x86_64
    expect "$got" "${pair#*:} $tag https://github.com/omarchy-asus/omarchy-asus/releases/download/$tag/omarchy-asus.db" \
        "Omarchy ${pair%%:*}: our ${pair#*:} channel"
done

echo "== b. dry run to rc"
conf stable; snippet ''
before=$(sums)
setup --dry-run --channel rc; expect $? 0 "exits 0"
grep -qx 'https://github.com/omarchy-asus/omarchy-asus/releases/download/rc-x86_64/omarchy-asus.db' "$S/curl.log"
expect $? 0 "previews the rc-x86_64 database"
grep -qF 'Server = https://github.com/omarchy-asus/omarchy-asus/releases/download/rc-$arch' "$S/out"
expect $? 0 "prints the rc repo section"
grep -qF '[dry-run] omarchy-channel-set rc' "$S/out"; expect $? 0 "prints omarchy-channel-set rc"
if [[ -e $S/ocs.log ]]; then r=0; else r=1; fi; expect "$r" 1 "omarchy-channel-set does not run"
expect "$(sums)" "$before" "no file changed"

echo "== c. switch to rc"
setup --channel rc; expect $? 0 "exits 0"
expect "$(server "$S/custom-repos.conf")" 'https://github.com/omarchy-asus/omarchy-asus/releases/download/rc-$arch' \
    "[omarchy-asus] on the rc-x86_64 release"
expect "$(cat "$S/ocs.log" 2>/dev/null)" "omarchy-channel-set rc" "omarchy-channel-set rc ran"
expect "$(server "$S/pacman.conf")" 'https://pkgs.omarchy.org/rc/$arch' "[omarchy] on Omarchy rc"
grep -qF 'on Omarchy rc, [omarchy-asus] on rc' "$S/out"; expect $? 0 "says both are on rc"

echo "== d. already on rc"
setup --channel rc; expect $? 0 "exits 0"
grep -qF 'already on the rc channel' "$S/out"; expect $? 0 "says so"
if [[ -e $S/ocs.log ]]; then r=0; else r=1; fi; expect "$r" 1 "omarchy-channel-set does not run"

echo "== e. back to quattro"
setup --channel quattro; expect $? 0 "exits 0"
expect "$(server "$S/custom-repos.conf")" 'https://github.com/omarchy-asus/omarchy-asus/releases/download/$arch' \
    "[omarchy-asus] on the x86_64 release"
expect "$(cat "$S/ocs.log" 2>/dev/null)" "omarchy-channel-set stable" "omarchy-channel-set stable ran"
grep -qF 'downgraded to the Quattro versions' "$S/out"; expect $? 0 "says it downgrades"
expect "$(server "$S/pacman.conf")" 'https://pkgs.omarchy.org/stable/$arch' "[omarchy] on Omarchy stable"
if [[ -e $S/home/.local/state/omarchy-asus/channel-switch-pending ]]; then r=0; else r=1; fi
expect "$r" 1 "no switch left pending"

echo "== f. the rc database is missing"
before=$(sums)
CURL_FAIL=rc-x86_64 setup --channel rc; r=$?; expect "$((r != 0))" 1 "exits non-zero ($r)"
grep -qF 'nothing was changed' "$S/out"; expect $? 0 "says nothing was changed"
expect "$(sums)" "$before" "no file changed"
if [[ -e $S/ocs.log ]]; then r=0; else r=1; fi; expect "$r" 1 "omarchy-channel-set does not run"

echo "== g. the repo is not set up"
rm -f "$S/custom-repos.conf"
before=$(sums)
setup --channel rc; r=$?; expect "$((r != 0))" 1 "exits non-zero ($r)"
grep -qF 'not set up' "$S/out"; expect $? 0 "says so"
expect "$(sums)" "$before" "no file changed"

echo "== h. an unknown channel"
setup --channel edge; expect $? 2 "exits 2"

echo "== i. a switch whose upgrade fails is finished by a rerun"
P=$S/home/.local/state/omarchy-asus/channel-switch-pending
conf stable; snippet ''
OCS_FAIL=1 setup --channel rc; r=$?; expect "$((r != 0))" 1 "the failed switch exits non-zero ($r)"
expect "$(server "$S/pacman.conf")" 'https://pkgs.omarchy.org/rc/$arch' "the configs are already on rc"
expect "$(cat "$P" 2>/dev/null)" rc "the rc switch is pending"
setup --channel rc; expect $? 0 "the rerun exits 0"
grep -qF 'already on the rc channel' "$S/out"; expect $? 1 "the rerun does not stop at 'already on'"
expect "$(cat "$S/ocs.log" 2>/dev/null)" "omarchy-channel-set rc" "the rerun runs omarchy-channel-set rc again"
if [[ -e $P ]]; then r=0; else r=1; fi; expect "$r" 1 "the verified switch clears it"
setup --channel rc; expect $? 0 "a third run exits 0"
grep -qF 'already on the rc channel' "$S/out"; expect $? 0 "and says it is already on rc"

# The G16's packages: the kernel and hyprland from us, the kernel also on [omarchy].
installed() {
    printf 'linux-omarchy 7.2.8-9.4\nhyprland 0.51.1-1.1\n' >"$S/q"
    printf '%s\n' 'omarchy-asus hyprland 0.51.1-1.1 [installed]' 'omarchy-asus linux-omarchy 7.2.8-9.4 [installed]' \
        'omarchy linux-omarchy 7.2.8-9' 'omarchy hyprland 0.51.1-1' >"$S/sl"
    export PKG_Q=$S/q PKG_SL=$S/sl TARGET_DESC=$S/target-desc
}
target() {  # target NAME VERSION...: the target channel's database
    : >"$S/target-desc"
    while (($#)); do printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n' "$1" "$2" >>"$S/target-desc"; shift 2; done
}
noforce() { rm -f "$S/curl.log" "$S/ocs.log"; "$W/bin/omarchy-asus-setup" "$@" >"$S/out" 2>&1; }

echo "== j. our kernel is not on the target channel: listed, refused"
conf stable; snippet ''; installed; target hyprland 0.51.1-1.1
before=$(sums)
noforce --dry-run --channel rc; r=$?; expect "$((r != 0))" 1 "the dry run exits non-zero ($r)"
grep -qE 'linux-omarchy +7\.2\.8-9\.4 installed, not on the rc channel' "$S/out"; expect $? 0 "the dry run lists linux-omarchy"
grep -qF 'Switch [omarchy]' "$S/out"; expect $? 1 "before the confirm"
grep -qF 'not switched' "$S/out"; expect $? 0 "says it is not switched"
grep -qF 'hyprland  0.51.1-1.1 installed, not on' "$S/out"; expect $? 1 "hyprland, which rc has, is not listed"
noforce --channel rc; r=$?; expect "$((r != 0))" 1 "the switch exits non-zero ($r)"
grep -qF 'use --force' "$S/out"; expect $? 0 "names --force"
expect "$(sums)" "$before" "no file changed"
if [[ -e $S/ocs.log ]]; then r=0; else r=1; fi; expect "$r" 1 "omarchy-channel-set does not run"

echo "== k. the same with --force"
printf '%s\n' 'omarchy-asus hyprland 0.51.1-1.1 [installed]' 'omarchy linux-omarchy 7.2.8-9 [installed: 7.2.8-9.4]' >"$S/sl-after"
printf 'linux-omarchy 7.2.8-9\nhyprland 0.51.1-1.1\n' >"$S/q-after"
PKG_Q=$S/q-after PKG_SL_AFTER=$S/sl-after setup --channel rc; r=$?; expect "$((r != 0))" 1 "exits non-zero ($r)"
grep -qF 'switching anyway because of --force: linux-omarchy' "$S/out"; expect $? 0 "warns about linux-omarchy"
grep -qF 'after the switch, linux-omarchy not the [omarchy-asus] rc builds' "$S/out"; expect $? 0 "the check after the switch fails"
grep -qF 'all 2 installed packages of ours' "$S/out"; expect $? 1 "and does not say they are all ours"
expect "$(server "$S/pacman.conf")" 'https://pkgs.omarchy.org/rc/$arch' "[omarchy] on Omarchy rc"
expect "$(head -n1 "$P" 2>/dev/null)" rc "the switch stays pending"
rm -f "$P"

echo "== l. the switch replaced our kernel: it fails until the kernel is ours again"
conf stable; snippet ''; installed; target hyprland 0.51.1-1.1 linux-omarchy 7.2.8-9.4
printf '%s\n' 'omarchy-asus hyprland 0.51.1-1.1 [installed]' 'omarchy-asus linux-omarchy 7.2.8-9.4 [installed: 7.2.8-9]' \
    'omarchy linux-omarchy 7.2.8-9' >"$S/sl-after"
printf 'linux-omarchy 7.2.8-9\nhyprland 0.51.1-1.1\n' >"$S/q-after"
PKG_Q=$S/q-after PKG_SL_AFTER=$S/sl-after setup --channel rc; r=$?; expect "$((r != 0))" 1 "the switch exits non-zero ($r)"
cp "$S/q-after" "$S/q"
grep -qE 'linux-omarchy +7\.2\.8-9 installed, not the \[omarchy-asus\] rc build' "$S/out"
expect $? 0 "names linux-omarchy and the stock version"
expect "$(head -n1 "$P" 2>/dev/null)" rc "the switch stays pending"
grep -qxF linux-omarchy "$P"; expect $? 0 "and records linux-omarchy as ours"
PKG_SL_AFTER=$S/sl-after setup --channel rc; r=$?; expect "$((r != 0))" 1 "a rerun that leaves the stock kernel still fails ($r)"
grep -qF 'after the switch, linux-omarchy not' "$S/out"; expect $? 0 "naming linux-omarchy"
printf '%s\n' 'omarchy-asus hyprland 0.51.1-1.1 [installed]' 'omarchy-asus linux-omarchy 7.2.8-9.4 [installed]' >"$S/sl-after"
PKG_SL_AFTER=$S/sl-after setup --channel rc; expect $? 0 "a rerun that installs ours passes"
grep -qF 'all 2 installed packages of ours are the [omarchy-asus] rc builds' "$S/out"; expect $? 0 "says both are ours"
if [[ -e $P ]]; then r=0; else r=1; fi; expect "$r" 1 "and clears the pending switch"

echo "== m. our kernel was withdrawn from the current channel's database"
conf stable; snippet ''; installed; target hyprland 0.51.1-1.1
printf 'linux-omarchy 7.2.8-9.4\nhyprland 0.51.1-1.1\ng16-extra 1.0-1 omarchy-asus\n' >"$S/q"
printf '%s\n' 'omarchy-asus hyprland 0.51.1-1.1 [installed]' 'omarchy linux-omarchy 7.2.8-9 [installed: 7.2.8-9.4]' \
    'omarchy hyprland 0.51.1-1' >"$S/sl"
before=$(sums)
noforce --channel rc; r=$?; expect "$((r != 0))" 1 "the switch exits non-zero ($r)"
grep -qE 'linux-omarchy +7\.2\.8-9\.4 installed, not on the rc channel' "$S/out"; expect $? 0 "lists linux-omarchy (.N pkgrel)"
grep -qE 'g16-extra +1\.0-1 installed, not on the rc channel' "$S/out"; expect $? 0 "lists a package whose packager is ours"
grep -qE '^ +hyprland .*not on the rc channel' "$S/out"; expect $? 1 "not hyprland, which rc has"
expect "$(sums)" "$before" "no file changed"
if [[ -e $S/ocs.log ]]; then r=0; else r=1; fi; expect "$r" 1 "omarchy-channel-set does not run"

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
