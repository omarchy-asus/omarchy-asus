#!/bin/bash
# Channel switching is Omarchy's own omarchy-channel-set (#167, #201), offline. Our part is
# the pre-refresh hook bin/omarchy-asus-setup installs: Omarchy runs it after it copies a
# channel's pacman.conf into place and before pacman -Syyuu. The hook under test is the one
# install_hook writes, with its /etc paths pointed at temp files; sudo is a stub that logs.
#   a. a first setup picks our channel from Omarchy's: rc with Omarchy rc, quattro with stable
#   b. Omarchy switched to rc: [omarchy-asus] moves to rc-x86_64, the Include line goes back
#      above [omarchy], the other repos in custom-repos.conf stay, one sudo call
#   c. the hook again: nothing to do, no sudo
#   d. back to Omarchy stable: [omarchy-asus] moves to the x86_64 release
#   e. Omarchy edge: [omarchy-asus] stays where it is, with a warning; the Include line still goes in
#   f. a Server of your own (not our release) is left alone
#   g. no custom-repos.conf: the hook does nothing
#   h. LAPTOP-SETUP.md section 3 shows the same hook
#   i. --channel is retired: exits 2, points at omarchy-channel-set, changes nothing, and says
#      an older hook needs a rerun of the setup first
#   j. indented sections and Server lines, tabs around "=": still read and moved
#   k. through a refresh like omarchy-refresh-pacman's (its hook runner goes on after a failed
#      hook): the upgrade runs after a good hook; when sudo fails, the hook stops the refresh
#      before pacman -Syyuu, with or without the TERM trap Omarchy 4.5's refresh sets
# Usage: tests/ci/setup-channel.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/home"
cat >"$S/bin/sudo" <<'STUB'
#!/bin/bash
echo "sudo $1" >>"$SUDO_LOG"
[[ -z ${SUDO_FAIL:-} ]] || { echo "sudo: 3 incorrect password attempts" >&2; exit 1; }
exec "$@"
STUB
chmod +x "$S/bin/sudo"
export PATH=$S/bin:$PATH HOME=$S/home SUDO_LOG=$S/sudo.log
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
export OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_CUSTOM_REPOS=$S/custom-repos.conf
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
REL=https://github.com/omarchy-asus/omarchy-asus/releases/download
template() {  # template <stable|rc|edge>: pacman.conf as omarchy-refresh-pacman copies it, no Include line
    printf '[options]\nHoldPkg = pacman glibc\n\n[omarchy]\nSigLevel = Optional TrustAll\nServer = https://pkgs.omarchy.org/%s/$arch\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' \
        "$1" >"$S/pacman.conf"
}
snippet() {  # snippet <server>: custom-repos.conf with another repo of yours, then ours
    printf '[mine]\nServer = https://example.invalid/$arch\n\n[omarchy-asus]\nSigLevel = Required\nServer = %s\n' "$1" >"$S/custom-repos.conf"
}
server() { sed -n "/^\[$1\]\$/,/^\[/s/^Server = //p" "$2"; }
first_section() { grep -m1 -nE '^(Include = '"$S"'/custom-repos.conf|\[omarchy\]|\[core\])$' "$S/pacman.conf" | cut -d: -f2-; }
hook() { rm -f "$SUDO_LOG"; bash "$S/hook" >"$S/out" 2>&1; }
sudos() { if [[ -f $SUDO_LOG ]]; then wc -l <"$SUDO_LOG"; else echo 0; fi; }

# The hook install_hook writes, its /etc paths pointed at the temp files.
OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 bash -c 'f=$1; shift; source "$f" && install_hook' _ "$W/bin/omarchy-asus-setup" >/dev/null 2>&1
H=$HOME/.config/omarchy/hooks/pre-refresh-pacman.d/add-omarchy-asus-repo
[[ -x $H ]] || { echo "FAIL: install_hook wrote no executable $H"; exit 1; }
sed -e "s|^CONF=.*|CONF=$S/pacman.conf|" -e "s|^SNIPPET=.*|SNIPPET=$S/custom-repos.conf|" "$H" >"$S/hook"
expect "$(grep -c "^CONF=$S/\|^SNIPPET=$S/" "$S/hook")" 2 "the hook's paths point at the temp files"

echo "== a. a first setup follows Omarchy's channel"
for pair in rc:rc stable:quattro; do
    template "${pair%%:*}"
    got=$(OMARCHY_ASUS_SETUP_SOURCE_ONLY=1 bash -c 'f=$1; shift; source "$f" && set_channel && echo "$CHANNEL $GH_TAG $DB_URL"' _ \
        "$W/bin/omarchy-asus-setup" 2>/dev/null)
    tag=x86_64; [[ ${pair#*:} == rc ]] && tag=rc-x86_64
    expect "$got" "${pair#*:} $tag $REL/$tag/omarchy-asus.db" "Omarchy ${pair%%:*}: our ${pair#*:} channel"
done

echo "== b. omarchy-channel-set rc"
template rc; snippet "$REL/\$arch"
hook; expect $? 0 "exits 0"
expect "$(server omarchy-asus "$S/custom-repos.conf")" "$REL/rc-\$arch" "[omarchy-asus] on the rc-x86_64 release"
expect "$(server mine "$S/custom-repos.conf")" 'https://example.invalid/$arch' "your other repo is untouched"
expect "$(first_section)" "Include = $S/custom-repos.conf" "the Include line is above [omarchy]"
expect "$(grep -c '^\[omarchy-asus\]$' "$S/custom-repos.conf")" 1 "one [omarchy-asus] section"
expect "$(sudos)" 1 "one sudo call for both edits"

echo "== c. the hook again"
before=$(sha256sum "$S/pacman.conf" "$S/custom-repos.conf")
hook; expect $? 0 "exits 0"
expect "$(sha256sum "$S/pacman.conf" "$S/custom-repos.conf")" "$before" "no file changed"
expect "$(sudos)" 0 "no sudo"

echo "== d. omarchy-channel-set stable"
template stable
hook; expect $? 0 "exits 0"
expect "$(server omarchy-asus "$S/custom-repos.conf")" "$REL/\$arch" "[omarchy-asus] on the x86_64 release"
expect "$(first_section)" "Include = $S/custom-repos.conf" "the Include line is above [omarchy]"

echo "== e. Omarchy edge"
template edge; snippet "$REL/rc-\$arch"
hook; expect $? 0 "exits 0"
expect "$(server omarchy-asus "$S/custom-repos.conf")" "$REL/rc-\$arch" "[omarchy-asus] stays on rc-x86_64"
grep -qF 'neither Omarchy stable nor rc' "$S/out"; expect $? 0 "warns"
expect "$(first_section)" "Include = $S/custom-repos.conf" "the Include line is still added"

echo "== f. a Server of your own"
template rc; snippet 'https://mirror.invalid/omarchy-asus/$arch'
hook; expect $? 0 "exits 0"
expect "$(server omarchy-asus "$S/custom-repos.conf")" 'https://mirror.invalid/omarchy-asus/$arch' "left alone"

echo "== g. no custom-repos.conf"
template rc; rm -f "$S/custom-repos.conf"
before=$(sha256sum "$S/pacman.conf")
hook; expect $? 0 "exits 0"
expect "$(sha256sum "$S/pacman.conf")" "$before" "pacman.conf unchanged"
expect "$(sudos)" 0 "no sudo"

echo "== h. LAPTOP-SETUP.md section 3 shows the same hook"
doc=$(awk '/^## 3\. Hook/ { on = 1; next } on && /^```bash$/ { grab = 1; next } grab && /^```$/ { exit } grab' "$W/LAPTOP-SETUP.md")
if [[ $doc == "$(<"$H")" ]]; then r=0; else r=1; diff <(echo "$doc") "$H"; fi
expect "$r" 0 "the documented hook is the installed one"

echo "== i. --channel is retired"
template stable; snippet "$REL/\$arch"
before=$(sha256sum "$S/pacman.conf" "$S/custom-repos.conf")
"$W/bin/omarchy-asus-setup" --channel rc >"$S/out" 2>&1; expect $? 2 "exits 2"
grep -qF "omarchy-channel-set rc" "$S/out"; expect $? 0 "points at omarchy-channel-set rc"
"$W/bin/omarchy-asus-setup" --channel quattro >"$S/out" 2>&1; expect $? 2 "--channel quattro exits 2"
grep -qF "omarchy-channel-set stable" "$S/out"; expect $? 0 "points at omarchy-channel-set stable"
grep -qF "older copy" "$S/out"; expect $? 1 "a current hook needs no rerun"
expect "$(sha256sum "$S/pacman.conf" "$S/custom-repos.conf")" "$before" "no file changed"
printf '#!/bin/bash\n# an older hook\n' >"$H"
"$W/bin/omarchy-asus-setup" --channel rc >"$S/out" 2>&1
grep -qF "older copy" "$S/out"; expect $? 0 "an older hook: says to rerun the setup first"

echo "== j. blanks around sections, Server and ="
template rc
printf '[mine]\nServer = https://example.invalid/$arch\n\n  [omarchy-asus]  \n  SigLevel = Required\n\tServer\t=\t%s  \n' "$REL/\$arch" >"$S/custom-repos.conf"
sed -i 's/^\[omarchy\]$/ [omarchy]/; s|^Server = https://pkgs|  Server\t= https://pkgs|' "$S/pacman.conf"
hook; expect $? 0 "exits 0"
expect "$(grep -c "^Server = $REL/rc-\\\$arch\$" "$S/custom-repos.conf")" 1 "[omarchy-asus] on the rc-x86_64 release"
expect "$(grep -c "\\\$arch  \$\|$REL/\\\$arch" "$S/custom-repos.conf")" 0 "the old Server line is gone"
grep -qxF "Include = $S/custom-repos.conf" "$S/pacman.conf"; expect $? 0 "the Include line is in"
hook; expect "$(sudos)" 0 "a second run reads it back: no sudo"

echo "== k. through a refresh"
# Omarchy's hook runner: a failed hook is reported, and the refresh goes on.
cat >"$S/bin/omarchy-hook" <<'STUB'
#!/bin/bash
bash "$HOOK_UNDER_TEST" || echo "Hook failed: $HOOK_UNDER_TEST"
STUB
cat >"$S/bin/omarchy-refresh-pacman" <<'STUB'
#!/bin/bash
[[ -n ${REFRESH_TRAP:-} ]] && trap 'exit 143' TERM
cp "$TEMPLATE" "$OMARCHY_ASUS_PACMAN_CONF"
omarchy-hook pre-refresh-pacman
echo "pacman -Syyuu" >>"$PACMAN_LOG"
STUB
chmod +x "$S/bin/omarchy-hook" "$S/bin/omarchy-refresh-pacman"
export HOOK_UNDER_TEST=$S/hook TEMPLATE=$S/template PACMAN_LOG=$S/pacman.log
refresh() { rm -f "$PACMAN_LOG" "$SUDO_LOG"; { omarchy-refresh-pacman >"$S/out" 2>&1; } 2>/dev/null; }
template rc; cp "$S/pacman.conf" "$S/template"
snippet "$REL/\$arch"
refresh; expect $? 0 "a good hook: the refresh exits 0"
expect "$(cat "$PACMAN_LOG" 2>/dev/null)" "pacman -Syyuu" "and upgrades"
expect "$(server omarchy-asus "$S/custom-repos.conf")" "$REL/rc-\$arch" "on the rc-x86_64 release"
for trap in '' 1; do
    snippet "$REL/\$arch"
    SUDO_FAIL=1 REFRESH_TRAP=$trap refresh; r=$?
    expect "$((r != 0))" 1 "sudo fails${trap:+ (TERM trap)}: the refresh exits non-zero ($r)"
    if [[ -e $PACMAN_LOG ]]; then u=1; else u=0; fi
    expect "$u" 0 "no pacman -Syyuu"
    grep -qF 'stopping the refresh' "$S/out"; expect $? 0 "says it stopped the refresh"
done

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
