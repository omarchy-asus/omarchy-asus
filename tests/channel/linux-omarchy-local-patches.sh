#!/bin/bash
# recipes/linux-omarchy: our own patches (the ones without a .sig) are pinned only
# by their checksums, at the same index in source=(), b2sums=() and sha256sums=().
#   1. every local patch's b2sum and sha256sum sit at its own index (an entry
#      one slot off still has the right count, and makepkg then blames the wrong file);
#   2. 0808 (#185): the patch applies at fuzz 0 to asus-wmi.c's hibernate/resume
#      callbacks as 0800 and 0803 leave them (tests/channel/fixtures), and
#      asus_hotk_restore() then writes the thermal policy and fan curves back.
#      Online, it also checks the fixture against v7.2.8's real file.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/linux-omarchy
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# ------------------------------------------------------------- 1. checksums
# Source the PKGBUILD's arrays only (no functions run) in a subshell.
mapfile -t rows < <(cd "$R" && bash -c '
  source ./PKGBUILD >/dev/null 2>&1 || exit 1
  [[ ${#source[@]} -eq ${#b2sums[@]} && ${#source[@]} -eq ${#sha256sums[@]} ]] || { echo "COUNT ${#source[@]} ${#b2sums[@]} ${#sha256sums[@]}"; exit 0; }
  for i in "${!source[@]}"; do printf "%s %s %s\n" "${source[$i]}" "${b2sums[$i]}" "${sha256sums[$i]}"; done')
((${#rows[@]})) || bad "could not read the PKGBUILD arrays"
[[ ${rows[0]:-} == COUNT* ]] && bad "source/b2sums/sha256sums counts differ: ${rows[0]#COUNT }"
n=0
for row in "${rows[@]}"; do
  read -r f b s <<<"$row"
  [[ $f == *.patch && $f != */* && -f $R/$f && ! -e $R/$f.sig ]] || continue
  n=$((n + 1))
  [[ $(b2sum "$R/$f" | cut -d' ' -f1) == "$b" ]] || bad "$f: b2sums entry at its index is not its b2sum"
  [[ $(sha256sum "$R/$f" | cut -d' ' -f1) == "$s" ]] || bad "$f: sha256sums entry at its index is not its sha256sum"
done
((n >= 7)) && ok "$n local patches pinned at their own index" || bad "only $n local patches found in source=()"
grep -q '^  0808-platform-x86-asus-wmi-restore-thermal-policy-after-hibernation.patch$' "$R/PKGBUILD" &&
  ok "0808 is in source=()" || bad "0808 missing from source=()"
grep -q '^patch 0808-platform-x86-asus-wmi-restore-thermal-policy-after-hibernation.patch after 0807-\*$' "$R/DELTA" &&
  ok "0808 is in DELTA" || bad "0808 missing from DELTA"

# ------------------------------------------------------------- 2. 0808 applies
P=$R/0808-platform-x86-asus-wmi-restore-thermal-policy-after-hibernation.patch
FX=$W/tests/channel/fixtures/asus-wmi-7.2.8-pm-callbacks.c
F=drivers/platform/x86/asus-wmi.c
check_0808() { # tree: applies 0808 to $tree/$F and checks the result
  (
    cd "$1" || exit 1
    patch -p1 -N --fuzz=0 --no-backup-if-mismatch <"$P" >/dev/null || { echo "FAIL: 0808 does not apply at fuzz 0"; exit 1; }
    body=$(awk '/^static int asus_hotk_restore\(/,/^}/' "$F")
    grep -q 'asus_wmi_restore_thermal_state(asus);' <<<"$body" || { echo "FAIL: asus_hotk_restore does not call the restore"; exit 1; }
    helper=$(awk '/^static void asus_wmi_restore_thermal_state\(/,/^}/' "$F")
    grep -q 'throttle_thermal_policy_write(asus)' <<<"$helper" || { echo "FAIL: the restore does not write the thermal policy"; exit 1; }
    grep -q 'fan_curve_write(asus, &asus->custom_fan_curves\[i\])' <<<"$helper" || { echo "FAIL: the restore does not re-enable fan curves"; exit 1; }
    # thaw (hibernation aborted, no power cycle) and resume (s2idle) stay as they were
    for cb in asus_hotk_thaw asus_hotk_resume; do
      awk "/^static int $cb\\(/,/^}/" "$F" | grep -q restore_thermal && { echo "FAIL: $cb calls the restore"; exit 1; }
    done
    exit 0
  )
}
# Offline: the hibernate/resume callbacks of asus-wmi.c as 0800 and 0803 leave them.
mkdir -p "$T/fx/${F%/*}"
grep -v '^// ' "$FX" >"$T/fx/$F"
check_0808 "$T/fx" && ok "0808 applies at fuzz 0 to the fixture; restore writes the policy and fan curves back, thaw and resume untouched" ||
  bad "0808 against the fixture"
# Online: the same against the real file, and the fixture still matches it.
mkdir -p "$T/k/${F%/*}"
if curl -sfL --max-time 30 -o "$T/k/$F" "https://raw.githubusercontent.com/gregkh/linux/v7.2.8/$F"; then
  (
    cd "$T/k" || exit 1
    git init -q . || exit 1
    for p in 0800-platform-updates 0803-acpi-battery-hook-api-acpi-prefix; do
      git apply --include="$F" "$R/$p.patch" || { echo "FAIL: $p does not apply to v7.2.8's $F"; exit 1; }
    done
  ) || bad "0800/0803 against v7.2.8's $F"
  s=$(grep -n '^/\* Platform driver - hibernate/resume callbacks' "$T/k/$F" | cut -d: -f1)
  e=$(grep -n '^static const struct dev_pm_ops asus_pm_ops' "$T/k/$F" | cut -d: -f1)
  cmp -s <(sed -n "$((s - 1)),$((e + 5))p" "$T/k/$F") <(grep -v '^// ' "$FX") &&
    ok "the fixture matches v7.2.8 + 0800/0803" || bad "the fixture no longer matches v7.2.8 + 0800/0803"
  check_0808 "$T/k" && ok "0808 applies at fuzz 0 to the full file too" || bad "0808 against v7.2.8's $F"
else
  echo "skip: no network: the fixture was not compared with v7.2.8's $F"
fi

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }
