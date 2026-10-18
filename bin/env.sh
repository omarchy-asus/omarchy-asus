# Shared paths for the omarchy-asus build/publish scripts (sourced).
# Overrides (bin/auto-update and the systemd unit set these: there the scripts run
# from a root-owned copy and act for an unprivileged build user):
#   OMARCHY_ASUS_WORKSPACE  checkout whose recipes/ and build/ are used (default: this script's repo)
#   OMARCHY_ASUS_DATA       state dir (default: ~/.local/share/omarchy-asus of BUILD_USER when
#                           running as root, else of $HOME)
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
REPO_DIR=$DATA/repo/x86_64                # local repo; mirrored to the GitHub release
STAGE_DIR=$DATA/stage                     # chroot build output before signing
LOG_DIR=$DATA/logs
CHROOT=/var/lib/omarchy-asus/chroot       # mkarchroot parent dir (btrfs)
GH_REPO=omarchy-asus/omarchy-asus         # public; pacman pulls from its release
GH_TAG=x86_64                             # Server = .../releases/download/$arch
GH_BRANCH=main
