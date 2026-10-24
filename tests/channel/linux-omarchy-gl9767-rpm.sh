#!/bin/bash
# Offline check for linux-omarchy's 0570 (GL9767 SD reader runtime PM, #226):
#   1. 0570 is in source=() right after 0569, with a b2sum and a sha256sum
#      that match the file, and DELTA re-applies it;
#   2. the patch keeps the shape that fixes the first version's resume loop on
#      the G16: suspend waits for a stable card detect, a resume for a host
#      claim queues no rescan, and quick empty wakes stop runtime suspend;
#   3. if the kernel tarball and a 7.2.8 linux-omarchy headers tree are on this
#      machine (the build host), 0570 applies at fuzz 0 to stock 7.2.8 and
#      sdhci-pci compiles as a module with W=1 and no warnings. Elsewhere
#      (CI's hosted runner) step 3 says SKIP; CI's kernel build compiles it.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/linux-omarchy
P=$R/0570-mmc-sdhci-pci-gli-gl9767-runtime-pm.patch
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
[[ -n $i && $prev == 0569-* ]] && ok "0570 follows 0569 in source=()" || bad "0570 position: after '$prev'"
[[ $(sed -n "${i}p" <<<"$b2") == "$(b2sum "$P" | cut -d' ' -f1)" ]] && ok "b2sum matches" || bad "b2sum mismatch"
[[ $(sed -n "${i}p" <<<"$sha") == "$(sha256sum "$P" | cut -d' ' -f1)" ]] && ok "sha256sum matches" || bad "sha256sum mismatch"
grep -q '^patch 0570-mmc-sdhci-pci-gli-gl9767-runtime-pm.patch after 0569-\*' "$R/DELTA" &&
  ok "DELTA re-applies 0570" || bad "DELTA has no 0570 line"

# ------------------------------------------------------------ 2. shape
fn() { awk -v f="$1" '$0 ~ "^\\+static int " f "\\(" {on = 1} on {print} on && /^\+}$/ {exit}' "$P"; }
sus=$(fn gl9767_runtime_suspend)
res=$(fn gl9767_runtime_resume)
[[ -n $sus && -n $res ]] || bad "runtime_suspend/runtime_resume not found"
grep -q 'SDHCI_CD_STABLE' <<<"$sus" && grep -q 'return -EAGAIN;' <<<"$sus" &&
  ok "suspend waits for a stable card detect" || bad "suspend doesn't wait for card detect to settle"
grep -q 'GL9767_SETTLE_TRIES' <<<"$sus" && ok "the wait is bounded" || bad "unbounded settle retries"
grep -q 'pci_dev_run_wake' <<<"$sus" && grep -q 'MMC_POWER_OFF' <<<"$sus" &&
  ok "suspend needs a PME and the host powered off" || bad "suspend gates"
# The claimed check must come before the only mmc_detect_change().
c=$(grep -n 'if (READ_ONCE(host->mmc->claimed))' <<<"$res" | head -n1 | cut -d: -f1)
d=$(grep -n 'mmc_detect_change' <<<"$res" | head -n1 | cut -d: -f1)
[[ -n $c && -n $d ]] && ((c < d)) && [[ $(grep -c mmc_detect_change <<<"$res") == 1 ]] &&
  ok "a resume for a host claim queues no rescan" || bad "resume can queue a rescan for a claim"
grep -q 'GL9767_EMPTY_WAKES' <<<"$res" && grep -q 'rpm_stopped = true' <<<"$res" &&
  ok "quick empty wakes stop runtime suspend" || bad "no limit on empty wakes"
grep -q '^+	.allow_runtime_pm = true,' "$P" && grep -q '^+	.priv_size	= sizeof(struct gl9767_host),' "$P" &&
  ok "GL9767 fixes: allow_runtime_pm and its private state" || bad "fixes entry"

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
tar -xJf "$tar" -C "$T" linux-7.2.8/drivers/mmc/host || { bad "extract"; exit 1; }
cd "$T/linux-7.2.8" || exit 1
patch -sNp1 --fuzz=0 <"$P" || { bad "0570 does not apply at fuzz 0"; exit 1; }
ok "0570 applies at fuzz 0 to stock 7.2.8"
M=$PWD/drivers/mmc/host
# Only the sdhci-pci module; its directory's Makefile would build every host driver.
mv "$M/Makefile" "$M/Makefile.stock"
printf 'obj-m := sdhci-pci.o\nsdhci-pci-y := sdhci-pci-core.o sdhci-pci-o2micro.o sdhci-pci-arasan.o sdhci-pci-dwc-mshc.o sdhci-pci-gli.o\n' >"$M/Kbuild"
log=$T/build.log
# Plain gcc: a distcc masquerade on PATH would send this out.
if PATH=/usr/bin:/bin make -C "$kdir" M="$M" CC=/usr/bin/gcc W=1 modules >"$log" 2>&1; then
  if grep -E 'sdhci-pci-gli\.c.*warning:' "$log"; then bad "W=1 warnings in sdhci-pci-gli.c"; else ok "sdhci-pci.ko builds with W=1 against ${kdir%/build}"; fi
else
  tail -20 "$log"; bad "module build failed"
fi
exit "$fail"
