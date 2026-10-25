#!/bin/bash
# omarchy-asus-g16-testd (#277), offline: the helper's own tests (allowlists, restore on
# stop, expiry, SIGTERM and after a crash, stay-awake) against a fake root, then
# package() into a scratch pkgdir installs exactly the expected files.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/omarchy-asus-g16-testd
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
python3 -I -W ignore::ResourceWarning "$R/tests/test_g16_testd.py" || fails=$((fails + 1))

mkdir -p "$T/src" "$T/pkg"
cp -r "$R"/. "$T/src/"
(
  cd "$T/src" || exit 1
  # shellcheck disable=SC1091
  source ./PKGBUILD
  # shellcheck disable=SC2034 # read by package()
  srcdir=$T/src pkgdir=$T/pkg
  package
) || { echo "FAIL: package() failed"; fails=$((fails + 1)); }
got=$(cd "$T/pkg" && find . \( -type f -o -type l \) -printf '%p %m\n' | sort | paste -sd' ')
want="./usr/bin/g16-testd 777 ./usr/lib/omarchy-asus-g16-testd/g16-testd 755 ./usr/share/doc/omarchy-asus-g16-testd/README.md 644 ./usr/share/licenses/omarchy-asus-g16-testd/LICENSE 644 ./usr/share/polkit-1/actions/io.github.omarchy-asus.g16-testd.policy 644"
if [[ $got == "$want" ]]; then echo "ok: package() files"; else echo "FAIL: files: $got"; fails=$((fails + 1)); fi
[[ $(readlink "$T/pkg/usr/bin/g16-testd") == /usr/lib/omarchy-asus-g16-testd/g16-testd ]] ||
  { echo "FAIL: /usr/bin/g16-testd link"; fails=$((fails + 1)); }
((fails == 0)) && echo "==> g16-testd: all passed" || { echo "==> g16-testd: $fails failed"; exit 1; }
