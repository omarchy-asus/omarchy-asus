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
# Usage: tests/ci/setup-channel.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/home"
FPR=$(sed -n 's/^FPR=//p' "$W/bin/omarchy-asus-setup")
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
case ${1:-} in -Q) exit 1 ;; esac
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
# OCS_FAIL=1: the configs are rewritten, then the -Syyuu / migrations fail
[[ -z ${OCS_FAIL:-} ]]
STUB
for c in pacman-key gpgv bsdtar vercmp; do printf '#!/bin/bash\nexit 0\n' >"$S/bin/$c"; done
printf '#!/bin/bash\nexec "$@"\n' >"$S/bin/sudo"
chmod +x "$S"/bin/*
printf 'y\n' >"$S/tty"
export PATH=$S/bin:$PATH HOME=$S/home CURL_LOG=$S/curl.log OCS_LOG=$S/ocs.log
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME CURL_FAIL OCS_FAIL
export OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_CUSTOM_REPOS=$S/custom-repos.conf \
    OMARCHY_ASUS_SETUP_TTY=$S/tty OMARCHY_ASUS_SNAPPER_CONFIG=$S/no-snapper
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

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
