#!/bin/bash
# bin/mkchroot writes our packager into the chroot of each channel (#201: the RC chroot had
# none, so its packages said "Unknown Packager"), offline: sudo, mkarchroot and arch-nspawn
# are stubs, the chroots are temp dirs.
#   a. a new chroot (quattro, then rc) gets etc/makepkg.conf.d/packager.conf
#   b. an existing chroot without one (the RC chroot before this fix) gets it on update
#   c. bin/env.sh chroot_packager_ok tells the two apart (bin/auto-update re-runs mkchroot on it)
# Usage: tests/ci/mkchroot-packager.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin"
printf '#!/bin/bash\nexec "$@"\n' >"$S/bin/sudo"
# mkarchroot -C CONF -M CONF DIR PKGS...: an empty root with the dirs makepkg uses
printf '#!/bin/bash\nmkdir -p "$5/etc/makepkg.conf.d"\n' >"$S/bin/mkarchroot"
printf '#!/bin/bash\necho "arch-nspawn $*" >>"$NSPAWN_LOG"\n' >"$S/bin/arch-nspawn"
chmod +x "$S"/bin/*
export PATH=$S/bin:$PATH NSPAWN_LOG=$S/nspawn.log OMARCHY_ASUS_DATA=$S/data
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
want='PACKAGER="omarchy-asus"'

echo "== a. new chroots"
for ch in quattro rc; do
    OMARCHY_ASUS_CHROOT=$S/chroot-$ch "$W/bin/mkchroot" --channel "$ch" >"$S/out" 2>&1; expect $? 0 "$ch: exits 0"
    expect "$(cat "$S/chroot-$ch/root/etc/makepkg.conf.d/packager.conf" 2>/dev/null)" "$want" "$ch: packager written"
done

echo "== b. an existing chroot without a packager"
mkdir -p "$S/old/root/etc/makepkg.conf.d"
OMARCHY_ASUS_CHROOT=$S/old "$W/bin/mkchroot" --channel rc >"$S/out" 2>&1; expect $? 0 "exits 0"
grep -qF "arch-nspawn" "$NSPAWN_LOG"; expect $? 0 "updates it"
expect "$(cat "$S/old/root/etc/makepkg.conf.d/packager.conf" 2>/dev/null)" "$want" "packager written"

echo "== c. chroot_packager_ok"
mkdir -p "$S/none/root"
r=$(source "$W/bin/env.sh" && { chroot_packager_ok "$S/old/root" && echo y || echo n; } &&
    { chroot_packager_ok "$S/none/root" && echo y || echo n; })
expect "$(echo $r)" "y n" "with one: ok; without: not"

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
