# Shared paths for the omarchy-asus build/publish scripts (sourced).
# Overrides (for scripts run from another checkout, or as root for an unprivileged build user):
#   OMARCHY_ASUS_WORKSPACE  checkout whose recipes/ and build/ are used (default: this script's repo)
#   OMARCHY_ASUS_DATA       state dir (default: ~/.local/share/omarchy-asus of BUILD_USER when
#                           running as root, else of $HOME)
#   OMARCHY_ASUS_CHROOT     the channel's chroot parent dir (default /var/lib/omarchy-asus/chroot,
#                           chroot-rc for rc; the offline tests point it at a temp dir)
#   OMARCHY_ASUS_CHANNEL    release channel (default quattro; the scripts' --channel sets it):
#     quattro  the x86_64 release, built from main against Omarchy's stable channel
#     rc       the rc-x86_64 release, built from next/omarchy-4.5 against Omarchy's rc channel
#   A channel has its own chroot, pacman.conf, stage dir, local repo and release, and its own
#   sync journal and publisher record ($CHANNEL_DATA): nothing built or staged for one
#   reaches the other.
REPO_NAME=omarchy-asus
WORKSPACE=${OMARCHY_ASUS_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
if [[ -z ${OMARCHY_ASUS_DATA:-} ]]; then
    # system services start without HOME: fall back to the passwd entry
    _home=${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}
    [[ $EUID -eq 0 && -n ${BUILD_USER:-} ]] && _home=$(getent passwd "$BUILD_USER" | cut -d: -f6)
    OMARCHY_ASUS_DATA=$_home/.local/share/omarchy-asus
    unset _home
fi
DATA=$OMARCHY_ASUS_DATA
export GNUPGHOME=$DATA/gnupg              # dedicated signing key; never in git
SIGN_KEY=$(cat "$DATA/fingerprint" 2>/dev/null || true)
LOG_DIR=$DATA/logs
GH_REPO=omarchy-asus/omarchy-asus         # public; pacman pulls from its release
CHANNELS=(quattro rc)
CHANNEL=${OMARCHY_ASUS_CHANNEL:-quattro}
# channel_stage_dir <channel>: where bin/build-pkg leaves that channel's packages
channel_stage_dir() {
    case $1 in
        quattro) echo "$DATA/stage" ;;
        rc) echo "$DATA/stage-rc" ;;
        *) return 1 ;;
    esac
}
# channel_repo_dir / channel_gh_tag <channel>: that channel's local repo and release tag
# (bin/publish reads the other channel's to keep a filename from naming two different files)
channel_repo_dir() {
    case $1 in
        quattro) echo "$DATA/repo/x86_64" ;;
        rc) echo "$DATA/repo/rc-x86_64" ;;
        *) return 1 ;;
    esac
}
channel_gh_tag() {
    case $1 in
        quattro) echo x86_64 ;;
        rc) echo rc-x86_64 ;;
        *) return 1 ;;
    esac
}
# Promotion rings (#309; not in use yet: nothing calls these, the channels still build from
# their own branches). A package moves through the rings in this order, source first.
RINGS=(rc quattro)
# ring_next <channel>: the ring a package is promoted to next (nothing after the last)
ring_next() {
    local i
    for i in "${!RINGS[@]}"; do
        [[ ${RINGS[i]} == "$1" ]] || continue
        [[ -n ${RINGS[i + 1]:-} ]] && echo "${RINGS[i + 1]}"
        return 0
    done
    return 1
}
# channel_pins_ref <channel>: the git ref that channel's omarchy + omarchy-settings pins come
# from (rc: main; quattro: pins/stable, which is main plus one pin commit)
channel_pins_ref() {
    case $1 in
        rc) echo main ;;
        quattro) echo pins/stable ;;
        *) return 1 ;;
    esac
}
# fast_ring_packages [conf]: the package names in build/fast-ring.conf (or conf), one per
# line. Each line is "<pkgname>  <reason>"; blank lines and # comments are skipped. Exit 1,
# naming the line, when one has no reason, an invalid name or a name listed twice.
fast_ring_packages() {
    local conf=${1:-$WORKSPACE/build/fast-ring.conf}
    awk 'function bad(why) { printf "%s:%d: %s: %s\n", FILENAME, FNR, why, $0 > "/dev/stderr"; err = 1 }
         /^[[:space:]]*(#|$)/ { next }
         NF < 2 { bad("no reason (want: <pkgname>  <reason>)"); next }
         $1 !~ /^[a-z0-9@_+][a-z0-9@._+-]*$/ { bad("invalid package name"); next }
         $1 in seen { bad("listed twice"); next }
         { seen[$1] = 1; names[++n] = $1 }
         END { if (err) exit 1; for (i = 1; i <= n; i++) print names[i] }' "$conf"
}
case $CHANNEL in
    quattro)
        CHANNEL_DATA=$DATA                        # sync-pending, release-db.sha256, prune-candidates
        REPO_DIR=$DATA/repo/x86_64                # local repo; mirrored to the GitHub release
        CHROOT=${OMARCHY_ASUS_CHROOT:-/var/lib/omarchy-asus/chroot}  # mkarchroot parent dir (btrfs)
        PACMAN_CONF=$WORKSPACE/build/pacman.conf  # chroot package sources
        OMARCHY_CHANNEL=stable                    # Omarchy's channel this one is built against
        GH_TAG=x86_64                             # Server = .../releases/download/$arch
        GH_BRANCH=main
        SUBREL=1                                  # first pkgrel subrelease (.1 to .99; bin/rebase-recipe)
        RELEASE_NOTES=$WORKSPACE/build/release-notes.md
        ;;
    rc)
        CHANNEL_DATA=$DATA/channel-rc
        REPO_DIR=$DATA/repo/rc-x86_64
        CHROOT=${OMARCHY_ASUS_CHROOT:-/var/lib/omarchy-asus/chroot-rc}
        PACMAN_CONF=$WORKSPACE/build/pacman-rc.conf
        OMARCHY_CHANNEL=rc
        GH_TAG=rc-x86_64                          # Server = .../releases/download/rc-$arch
        GH_BRANCH=next/omarchy-4.5
        SUBREL=101                                # .101 and up: never a Quattro filename (#201)
        RELEASE_NOTES=$WORKSPACE/build/release-notes-rc.md
        ;;
    *)
        echo "unknown release channel '$CHANNEL' (OMARCHY_ASUS_CHANNEL or --channel: ${CHANNELS[*]})" >&2
        return 1
        ;;
esac
# The packager every chroot build is signed off as: bin/mkchroot writes it into each channel's
# chroot (#201: the RC chroot had none, so its packages said "Unknown Packager").
PACKAGER_FILE=etc/makepkg.conf.d/packager.conf
PACKAGER_LINE='PACKAGER="omarchy-asus"'
# chroot_packager_ok <chroot root>: 0 when its makepkg config carries $PACKAGER_LINE
chroot_packager_ok() { grep -qxF "$PACKAGER_LINE" "$1/$PACKAGER_FILE" 2>/dev/null; }
STAGE_DIR=$(channel_stage_dir "$CHANNEL")     # chroot build output before signing
export OMARCHY_ASUS_CHANNEL=$CHANNEL          # children (bin/publish's helpers) see the same channel

# channel_conf_ok <pacman.conf>: 0 when that config pulls [omarchy], [core], [extra] and
# [multilib] from the same servers, in the same order, as this channel's $PACMAN_CONF (a
# chroot made for the other channel fails it). Read with awk: CI has no pacman-conf.
channel_servers() {
    awk '/^[[:space:]]*\[/ {s = $0; gsub(/[[:space:]]/, "", s); next}
         s ~ /^\[(omarchy|core|extra|multilib)\]$/ && /^[[:space:]]*Server[[:space:]]*=/ {
             v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); print s, v}' "$1"
}
channel_conf_ok() {
    local want got
    [[ -r $1 && -r $PACMAN_CONF ]] || return 1
    want=$(channel_servers "$PACMAN_CONF") && got=$(channel_servers "$1") || return 1
    [[ -n $want && $want == "$got" ]]
}
