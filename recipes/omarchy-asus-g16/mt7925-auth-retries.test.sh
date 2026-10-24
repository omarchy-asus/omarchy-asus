#!/bin/bash
# omarchy-asus-g16's mt7925 NetworkManager drop-in (#196), offline:
#   1. package() installs the drop-in under NetworkManager's vendor conf.d,
#      mode 0644;
#   2. NetworkManager itself parses it as one [connection-*] section that
#      matches only driver mt7925e and sets only connection.auth-retries=6,
#      next to a [connection] file like Omarchy's, which keeps its keys;
#   3. post_install, post_upgrade and post_remove ask a running NetworkManager
#      to reread its configuration, skip it when NetworkManager is stopped or
#      nmcli is missing, and only warn when the reload fails.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/omarchy-asus-g16
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# 1. package() into a scratch pkgdir
mkdir -p "$T/src" "$T/pkg"
cp -r "$R"/. "$T/src/"
(
  cd "$T/src" || exit 1
  # shellcheck disable=SC1091
  source ./PKGBUILD
  # shellcheck disable=SC2034 # read by package()
  srcdir=$T/src pkgdir=$T/pkg
  package
) || bad "package() failed"
CONF=$T/pkg/usr/lib/NetworkManager/conf.d/omarchy-asus-g16-mt7925-auth-retries.conf
[[ -f $CONF ]] && ok "drop-in installed" || bad "missing: $(cd "$T/pkg" && find . -type f)"
[[ $(stat -c %a "$CONF" 2>/dev/null) == 644 ]] && ok "drop-in is 0644" || bad "drop-in not 0644"

# 2. the drop-in's settings
lines=$(grep -v '^[[:space:]]*\(#\|$\)' "$CONF" | paste -sd'|')
[[ $lines == '[connection-omarchy-asus-g16-mt7925]|match-device=driver:mt7925e|connection.auth-retries=6' ]] &&
  ok "one section: driver mt7925e, auth-retries=6" || bad "drop-in: $lines"
if command -v NetworkManager >/dev/null 2>&1; then
  mkdir -p "$T/nm/etc" "$T/nm/usr"
  : >"$T/nm/NetworkManager.conf"
  cp "$CONF" "$T/nm/usr/"
  printf '[connection]\nwifi.powersave = 2\n' >"$T/nm/etc/wifi-powersave.conf"
  out=$(NetworkManager --print-config --config="$T/nm/NetworkManager.conf" \
    --config-dir="$T/nm/etc" --system-config-dir="$T/nm/usr" 2>&1)
  sect=$(printf '%s\n' "$out" | sed -n '/^\[connection-omarchy-asus-g16-mt7925\]/,/^$/p' | grep -v '^$' | paste -sd'|')
  [[ $sect == '[connection-omarchy-asus-g16-mt7925]|match-device=driver:mt7925e|connection.auth-retries=6' ]] &&
    ok "NetworkManager reads the section as written" || bad "NetworkManager --print-config: $out"
  printf '%s\n' "$out" | sed -n '/^\[connection\]$/,/^$/p' | grep -qx 'wifi.powersave=2' &&
    ok "a [connection] file keeps its keys" || bad "[connection] lost wifi.powersave: $out"
else
  echo "skip: NetworkManager not installed, --print-config check not run"
fi

# 3. the install script's reload
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "$*" >>"%s/nmcli.log"\nexit "${NMCLI_RC:-0}"\n' "$T" >"$T/bin/nmcli"
printf '#!/bin/sh\n[ "$1 $2 $3" = "is-active --quiet NetworkManager.service" ] && exit "${NM_ACTIVE_RC:-0}"\nexit 1\n' >"$T/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/limine-update"
chmod +x "$T/bin/nmcli" "$T/bin/systemctl" "$T/bin/limine-update"
for fn in post_install post_upgrade post_remove; do
  rm -f "$T/nmcli.log"
  out=$(PATH="$T/bin:$PATH"; source "$R/omarchy-asus-g16.install"; "$fn" 2>&1); rc=$?
  [[ $rc == 0 && $(cat "$T/nmcli.log" 2>/dev/null) == "general reload conf" ]] &&
    ok "$fn rereads NetworkManager's configuration" || bad "$fn: rc=$rc log=$(cat "$T/nmcli.log" 2>/dev/null) $out"
done
rm -f "$T/nmcli.log"
out=$(PATH="$T/bin:$PATH" NM_ACTIVE_RC=3; export NM_ACTIVE_RC; source "$R/omarchy-asus-g16.install"; post_install 2>&1); rc=$?
[[ $rc == 0 && ! -e $T/nmcli.log ]] && ok "no reload while NetworkManager is stopped" || bad "stopped NM: rc=$rc $out"
out=$(PATH="$T/bin:$PATH" NMCLI_RC=8; export NMCLI_RC; source "$R/omarchy-asus-g16.install"; post_upgrade 2>&1); rc=$?
[[ $rc == 0 && $out == *"next restart"* ]] && ok "a failed reload warns, the upgrade goes on" || bad "failed reload: rc=$rc $out"
mkdir -p "$T/nonm"
for b in sh cat grep printf; do ln -sf "$(command -v "$b")" "$T/nonm/$b"; done
ln -sf "$T/bin/systemctl" "$T/nonm/systemctl"
out=$(export PATH="$T/nonm"; source "$R/omarchy-asus-g16.install"; post_install 2>&1); rc=$?
[[ $rc == 0 ]] && ok "no nmcli: install succeeds" || bad "no nmcli: rc=$rc $out"

((fails == 0)) && echo "all g16-mt7925-auth-retries checks passed" || { echo "$fails check(s) failed"; exit 1; }
