#!/bin/bash
# Offline build check for linux-omarchy's 0809 (amd_pmf hwmon, #238):
#   1. 0809 is in source=() right after 0807, with a b2sum and a sha256sum
#      that match the file (makepkg would refuse otherwise, but only after a
#      150 MB download);
#   2. the patch keeps its default-safe shape: read-only attributes, the
#      hwmon_support switch defaults on and can turn it off, and an unknown
#      SoC registers nothing; on both metrics table layouts (v1: Rembrandt,
#      Phoenix; v2: family 1Ah 20h/60h) each channel reads that table's own
#      field, socket included;
#   3. if the kernel tarball and a 7.2.8 linux-omarchy headers tree are on this
#      machine (the build host), amd_pmf with upstream's 0800-0802 and our 0809
#      applies at fuzz 0 and compiles as a module with W=1 and no warnings.
#      Elsewhere (CI's hosted runner) step 3 says SKIP; CI's kernel build
#      compiles it in full.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/linux-omarchy
P=$R/0809-platform-x86-amd-pmf-hwmon-apu-dgpu-socket-power.patch
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# ------------------------------------------------------------ 1. recipe
[[ -f $P ]] || { echo "FAIL $P missing"; exit 1; }
src=$(bash -c 'source "$1"; printf "%s\n" "${source[@]}"' _ "$R/PKGBUILD")
b2=$(bash -c 'source "$1"; printf "%s\n" "${b2sums[@]}"' _ "$R/PKGBUILD")
sha=$(bash -c 'source "$1"; printf "%s\n" "${sha256sums[@]}"' _ "$R/PKGBUILD")
i=$(grep -n -x "${P##*/}" <<<"$src" | cut -d: -f1)
prev=$(sed -n "$((i - 1))p" <<<"$src")
[[ -n $i && $prev == 0808-* ]] && ok "0809 follows 0808 in source=()" || bad "0809 position: after '$prev'"
[[ $(sed -n "${i}p" <<<"$b2") == "$(b2sum "$P" | cut -d' ' -f1)" ]] && ok "b2sum matches" || bad "b2sum mismatch"
[[ $(sed -n "${i}p" <<<"$sha") == "$(sha256sum "$P" | cut -d' ' -f1)" ]] && ok "sha256sum matches" || bad "sha256sum mismatch"
grep -q '^patch 0809-platform-x86-amd-pmf-hwmon-apu-dgpu-socket-power.patch after 0808-\*' "$R/DELTA" &&
  ok "DELTA re-applies 0809" || bad "DELTA has no 0809 line"

# ------------------------------------------------------------ 2. shape
grep -q '^+static bool hwmon_support = true;' "$P" && grep -q '^+module_param(hwmon_support, bool, 0444);' "$P" &&
  ok "hwmon_support defaults on, read-only param" || bad "hwmon_support switch"
grep -q '^+	if (!hwmon_support || !amd_pmf_hwmon_supported(dev))' "$P" && ok "off switch and SoC gate checked first" || bad "registration gate"
grep -E '^\+.*(0644|0200|0600|S_IW|_store|\.write)' "$P" | grep -v 'Copyright' >/dev/null &&
  bad "patch adds something writable" || ok "nothing writable added"
grep -q '^+	if (IS_ERR(hwdev)) {' "$P" && ! grep -q '^+.*return PTR_ERR(hwdev)' "$P" &&
  ok "a failed registration doesn't fail probe" || bad "hwmon failure handling"

# Both table layouts: each channel comes from that table's own field. The v2
# table (family 1Ah models 20h/60h) has socket_power, the v1 table (Rembrandt,
# Phoenix) current_socketpower; neither is APU + dGPU, which would put the
# dGPU's draw under the socket label.
# The table switch in amd_pmf_hwmon_update(): its v2 case, then its default.
sw=$(awk '/^\+static int amd_pmf_hwmon_update\(/ {on = 1} on {print} on && /^\+}$/ {exit}' "$P")
v2=$(awk '/case PCI_DEVICE_ID_AMD_1AH_M20H_ROOT:/ {on = 1} on {print} on && /break;/ {exit}' <<<"$sw")
v1=$(awk '/^\+\tdefault:/ {on = 1} on {print} on && /break;/ {exit}' <<<"$sw")
for want in 'hwmon_mw[AMD_PMF_HWMON_APU] = v2.apu_power;' 'hwmon_mw[AMD_PMF_HWMON_DGPU] = v2.dgpu_power;' \
  'hwmon_mw[AMD_PMF_HWMON_SOCKET] = v2.socket_power;'; do
  grep -qF "$want" <<<"$v2" && ok "v2 table: $want" || bad "v2 table lacks: $want"
done
for want in 'hwmon_mw[AMD_PMF_HWMON_APU] = v1.apu_power;' 'hwmon_mw[AMD_PMF_HWMON_DGPU] = v1.dgpu_power;' \
  'hwmon_mw[AMD_PMF_HWMON_SOCKET] = v1.current_socketpower;'; do
  grep -qF "$want" <<<"$v1" && ok "v1 table: $want" || bad "v1 table lacks: $want"
done
grep -qE '^\+.*apu_power *\+ *[a-z0-9_.]*dgpu_power' "$P" && bad "socket is computed as APU + dGPU somewhere" || ok "no APU + dGPU sum reported as socket"

# ------------------------------------------------------------ 3. build
tar=''
for d in "${SRCDEST:-}" "$HOME/.local/share/omarchy-asus/srcdest" "$R"; do
  [[ -n $d && -f $d/linux-7.2.8.tar.xz ]] && { tar=$d/linux-7.2.8.tar.xz; break; }
done
kdir=''
for k in /usr/lib/modules/7.2.8-*-omarchy/build; do [[ -f $k/Makefile ]] && kdir=$k; done
if [[ -z $tar || -z $kdir ]] || ! command -v gcc >/dev/null; then
  echo "SKIP build: needs linux-7.2.8.tar.xz and linux-omarchy 7.2.8 headers (the build host has both)"
  exit "$fail"
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tar -xJf "$tar" -C "$T" linux-7.2.8/drivers/platform/x86/amd/pmf || { bad "extract"; exit 1; }
cd "$T/linux-7.2.8" || exit 1
git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm base
for p in "$R"/080[0-2]-*.patch "$P"; do
  git apply --include='drivers/platform/x86/amd/pmf/*' "$p" || bad "apply ${p##*/}"
done
((fail)) && exit 1
ok "0800-0802 and 0809 apply to amd/pmf"
log=$T/build.log
# Plain gcc: a distcc masquerade on PATH would send this out.
if PATH=/usr/bin:/bin make -C "$kdir" M="$PWD/drivers/platform/x86/amd/pmf" CC=/usr/bin/gcc \
  CONFIG_AMD_PMF=m W=1 modules >"$log" 2>&1; then
  if grep -E 'warning:' "$log"; then bad "W=1 warnings"; else ok "amd-pmf.ko builds with W=1 against ${kdir%/build}"; fi
  modinfo -p drivers/platform/x86/amd/pmf/amd-pmf.ko | grep -q '^hwmon_support:' && ok "module has hwmon_support" || bad "no hwmon_support param"
else
  tail -20 "$log"; bad "module build failed"
fi
exit "$fail"
