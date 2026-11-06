# Shared paths for the omarchy-asus build/publish scripts (sourced).
# Overrides (for scripts run from another checkout, or as root for an unprivileged build user):
#   OMARCHY_ASUS_WORKSPACE  checkout whose recipes/ and build/ are used (default: this script's repo)
#   OMARCHY_ASUS_DATA       state dir (default: ~/.local/share/omarchy-asus of BUILD_USER when
#                           running as root, else of $HOME)
#   OMARCHY_ASUS_CHROOT     the channel's chroot parent dir (default /var/lib/omarchy-asus/chroot,
#                           chroot-rc for rc; the offline tests point it at a temp dir)
#   OMARCHY_ASUS_CHANNEL    release channel (default quattro; the scripts' --channel sets it):
#     quattro  the x86_64 release, built against Omarchy's stable channel from main, the
#              trunk: every recipe and all the tooling (the Omarchy 4.5 stable switch, #411)
#     rc       the rc-x86_64 release, built against Omarchy's rc channel; idle until Omarchy
#              opens its next RC. It gets main's packages as the same files (bin/promote-channel)
#   main builds for one channel at a time (ci/channel main: bin/release-sign and ci/release-plan
#   serve only it); the other gets its packages by promotion (bin/promote-channel), never by a
#   second build (a filename names one file on every channel).
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
# The self-hosted runner's account (docs/kernel-runner.md), which bin/release-sign never runs
# as: local configuration, never in the repo. OMARCHY_ASUS_RUNNER_USER, else the first line of
# $DATA/runner-user; bin/release-sign refuses to run when neither names it.
RUNNER_USER=${OMARCHY_ASUS_RUNNER_USER:-$(head -n1 "$DATA/runner-user" 2>/dev/null || true)}
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
case $CHANNEL in
    quattro)
        CHANNEL_DATA=$DATA                        # sync-pending, release-db.sha256, prune-candidates
        REPO_DIR=$DATA/repo/x86_64                # local repo; mirrored to the GitHub release
        CHROOT=${OMARCHY_ASUS_CHROOT:-/var/lib/omarchy-asus/chroot}  # mkarchroot parent dir (btrfs)
        PACMAN_CONF=$WORKSPACE/build/pacman.conf  # chroot package sources
        OMARCHY_CHANNEL=stable                    # Omarchy's channel this one is built against
        GH_TAG=x86_64                             # Server = .../releases/download/$arch
        GH_BRANCH=main                            # main is the trunk (#411)
        SUBREL=101                                # .101 and up, the trunk's line (.1 to .99: the old files)
        RELEASE_NOTES=$WORKSPACE/build/release-notes.md
        ;;
    rc)
        CHANNEL_DATA=$DATA/channel-rc
        REPO_DIR=$DATA/repo/rc-x86_64
        CHROOT=${OMARCHY_ASUS_CHROOT:-/var/lib/omarchy-asus/chroot-rc}
        PACMAN_CONF=$WORKSPACE/build/pacman-rc.conf
        OMARCHY_CHANNEL=rc
        GH_TAG=rc-x86_64                          # Server = .../releases/download/rc-$arch
        GH_BRANCH=main                            # the trunk; rc is idle until Omarchy's next RC
        SUBREL=101                                # .101 and up, the trunk's line (#201)
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
