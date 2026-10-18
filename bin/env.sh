# Shared paths for the omarchy-asus build/publish scripts (sourced).
REPO_NAME=omarchy-asus
WORKSPACE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA=$HOME/.local/share/omarchy-asus
export GNUPGHOME=$DATA/gnupg              # dedicated signing key; never in git
SIGN_KEY=$(cat "$DATA/fingerprint")
REPO_DIR=$DATA/repo/x86_64                # local repo; mirrored to the GitHub release
STAGE_DIR=$DATA/stage                     # chroot build output before signing
LOG_DIR=$DATA/logs
CHROOT=/var/lib/omarchy-asus/chroot       # mkarchroot parent dir (btrfs)
GH_REPO=omarchy-asus/omarchy-asus         # public; pacman pulls from its release
GH_TAG=x86_64                             # Server = .../releases/download/$arch
GH_BRANCH=main
