#!/bin/bash
# The PR CI's nvidia-open-dkms vs linux-omarchy-headers check runs against the channel the
# PR targets: ci/nvidia-compat --channel rc sets up the container with the RC package sources
# and takes the side this run did not build from the rc-x86_64 release, not x86_64.
#   1. ci/channel --tag maps each channel to its release tag
#   2. ci/fetch-release downloads from the channel's release (curl stubbed: logs the URL)
#   3. ci/nvidia-compat passes the channel to ci/setup-arch and ci/fetch-release (both
#      stubbed in a copy of ci/), quattro when none is given
# Offline: no network, no docker, no root.
set -u
for t in gpg; do
    command -v "$t" >/dev/null && continue
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected '$3', got '$2'"; fails=1; fi
}

# 1. release tags
expect "1. quattro's release" "$("$W/ci/channel" --tag quattro)" x86_64
expect "1. rc's release" "$("$W/ci/channel" --tag rc)" rc-x86_64
rc=0; "$W/ci/channel" --tag beta >/dev/null 2>&1 || rc=$?
expect "1. unknown channel refused" "$((rc != 0))" 1

# 2. ci/fetch-release asks the channel's release for the signed db first
mkdir -p "$T/bin"
printf '#!/bin/bash\nfor a; do [[ $a == http* ]] && echo "$a" >>"%s"; done\nexit 22\n' "$T/urls" >"$T/bin/curl"
chmod +x "$T/bin/curl"
fetch() { : >"$T/urls"; PATH=$T/bin:$PATH GNUPGHOME=$T/gnupg "$W/ci/fetch-release" "$@" nvidia-open-dkms "$T/dest" >/dev/null 2>&1; head -1 "$T/urls"; }
mkdir -m 700 "$T/gnupg"
base=https://github.com/omarchy-asus/omarchy-asus/releases/download
expect "2. default: the x86_64 release" "$(fetch)" "$base/x86_64/omarchy-asus.db"
expect "2. --channel quattro: the x86_64 release" "$(fetch --channel quattro)" "$base/x86_64/omarchy-asus.db"
expect "2. --channel rc: the rc-x86_64 release" "$(fetch --channel rc)" "$base/rc-x86_64/omarchy-asus.db"

# 3. ci/nvidia-compat hands the channel on (nothing built in this run: both sides fetched)
R=$T/repo
mkdir -p "$R/ci" "$T/pkgs"
cp "$W/ci/nvidia-compat" "$W/ci/channel" "$R/ci/"
printf '#!/bin/bash\necho "setup-arch $*" >>"%s"\n' "$T/calls" >"$R/ci/setup-arch"
printf '#!/bin/bash\necho "fetch-release $*" >>"%s"\nexit 1\n' "$T/calls" >"$R/ci/fetch-release"
chmod +x "$R/ci/"*
compat() { : >"$T/calls"; "$R/ci/nvidia-compat" "$@" >/dev/null 2>&1; paste -sd'|' "$T/calls"; }
expect "3. default: quattro sources and release" "$(compat "$T/pkgs")" \
    "setup-arch --channel quattro dkms|fetch-release --channel quattro linux-omarchy-headers /tmp/release"
expect "3. --channel rc: rc sources and release" "$(compat --channel rc "$T/pkgs")" \
    "setup-arch --channel rc dkms|fetch-release --channel rc linux-omarchy-headers /tmp/release"
exit $fails
