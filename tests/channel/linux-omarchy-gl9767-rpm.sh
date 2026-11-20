#!/bin/bash
# Offline check for linux-omarchy's 0570 (GL9767 SD reader runtime PM, #226, #418):
#   1. 0570 is in source=() right after 0569, with a b2sum and a sha256sum
#      that match the file, and DELTA re-applies it;
#   2. the patch keeps the shape that fixes the G16's results: suspend waits
#      for a stable card detect, a resume for a host claim queues no rescan,
#      and nothing stops runtime suspend for good. Then its own functions,
#      compiled against stubs (fixtures/gl9767-rpm-sim.c, needs gcc), replay a
#      card cycle whose removal makes the reader wake straight back from D3
#      for a while, as on the G16 (#418): it must suspend again within a few
#      seconds, back off from a reader that never settles, and leave the
#      controller alone in D3;
#   3. if the kernel tarball and linux-omarchy headers of the recipe's pkgver
#      are on this machine (the build host; GL9767_KDIR names an extracted
#      headers tree), 0570 applies at fuzz 0 to the stock kernel and sdhci-pci
#      compiles as a module with W=1 and no warnings. Elsewhere (CI's hosted
#      runner) step 3 says SKIP; CI's kernel build compiles it.
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
grep -q 'GL9767_EMPTY_WAKES' <<<"$res" && grep -q 'gl9767_back_off' <<<"$res" &&
  ok "quick empty wakes back runtime suspend off" || bad "no limit on empty wakes"
grep -q 'rpm_stopped' "$P" && bad "runtime suspend can still stop for good (rpm_stopped)" ||
  ok "nothing stops runtime suspend for good"
# Behaviour, not just shape: the patch's own functions, compiled against stubs
# (fixtures/gl9767-rpm-sim.c), replayed through a card cycle whose removal makes
# the reader wake straight back from D3 for a while, as on the G16 (#418).
if command -v gcc >/dev/null; then
  H=$(mktemp -d)
  # The patch's post-image: context and added lines.
  awk '/^diff --git/ {on = 1; next} on && /^\+\+\+ / {next} on && /^[ +]/ {print substr($0, 2)}' "$P" >"$H/post"
  {
    grep '^#define GL9767_' "$H/post"
    awk '/^struct gl9767_host \{/ {on = 1} on {print} on && /^\};/ {exit}' "$H/post"
  } >"$H/gl9767.c"
  for f in gl9767_hold_end gl9767_hold gl9767_back_off gl9767_slot_seen sdhci_gl9767_card_event \
    gl9767_runtime_suspend gl9767_runtime_resume; do
    awk -v f="$f" '$0 ~ "^static [a-z ]+\\**" f "\\(" {on = 1} on {print} on && /^}$/ {exit}' "$H/post"
  done >"$H/gl9767-fns.c"
  grep -q '^static void gl9767_hold_end(' "$H/gl9767-fns.c" && sed -i '1i #define HAVE_HOLD 1' "$H/gl9767.c"
  # What the patch adds to the GL9767's probe_slot.
  {
    echo 'static void sim_probe(struct sdhci_pci_slot *slot)'
    echo '{'
    awk '/^ static int gli_probe_slot_gl9767\(/ {on = 1; next} on && /^(@@|diff )/ {exit} on && /^\+/ {print substr($0, 2)}' "$P"
    echo '	(void)slot;'
    echo '}'
  } >>"$H/gl9767-fns.c"
  cp "$W/tests/channel/fixtures/gl9767-rpm-sim.c" "$H/sim.c"
  if PATH=/usr/bin:/bin /usr/bin/gcc -std=gnu11 -Wall -Werror -Wno-unused-function -o "$H/sim" "$H/sim.c" 2>"$H/cc.log" && out=$("$H/sim"); then
    v() { awk -v k="$1" '$1 == k {print $2}' <<<"$out"; }
    [[ $(v empty_boot_suspended) == 1 ]] && ok "slot empty from boot: suspends" || bad "slot empty from boot: $out"
    s1=$(v removal_1s_settled_ms)
    [[ $(v removal_1s_suspended) == 1 ]] && ((s1 <= 5000)) &&
      ok "a removal that wakes it back for 1 s: suspended again ${s1} ms after the removal" ||
      bad "a removal that wakes it back for 1 s: not suspended again within 5 s (#418): $(tr '\n' ' ' <<<"$out")"
    s3=$(v removal_3s_settled_ms)
    [[ $(v removal_3s_suspended) == 1 ]] && ((s3 <= 8000)) &&
      ok "a 3 s burst after a removal: backs off and suspends again after ${s3} ms" ||
      bad "a 3 s burst after a removal: not suspended again within 8 s: $(tr '\n' ' ' <<<"$out")"
    c1=$(v cycles_first_settled_ms) c6=$(v cycles_last_settled_ms)
    ((c6 >= 0 && c6 <= c1 + 500)) &&
      ok "six card cycles: suspended again ${c1} ms after the first removal, ${c6} ms after the sixth" ||
      bad "the settle time grows from one card cycle to the next: ${c1} ms, then ${c6} ms"
    n=$(v storm_resumes_600s)
    ((n < 120)) && ok "a reader that never settles: $n resumes in 600 s (backs off, no D3 cycling)" ||
      bad "a reader that never settles cycles through D3: $n resumes in 600 s"
    [[ $(v mmio_while_suspended) == 0 ]] && ok "card_event leaves the controller alone while it is in D3" ||
      bad "registers touched while runtime-suspended: $(v mmio_while_suspended) times"
  else
    cat "$H/cc.log"; bad "resume simulation did not build or run"
  fi
  rm -rf "$H"
else
  echo "SKIP resume simulation: no gcc"
fi
grep -q '^+	.allow_runtime_pm = true,' "$P" && grep -q '^+	.priv_size	= sizeof(struct gl9767_host),' "$P" &&
  ok "GL9767 fixes: allow_runtime_pm and its private state" || bad "fixes entry"

# ------------------------------------------------------------ 3. build
ver=$(bash -c 'source "$1"; echo "$pkgver"' _ "$R/PKGBUILD")
tar=''
for d in "${SRCDEST:-}" "$HOME/.local/share/omarchy-asus/srcdest" "$R"; do
  [[ -n $d && -f $d/linux-$ver.tar.xz ]] && { tar=$d/linux-$ver.tar.xz; break; }
done
# GL9767_KDIR: a headers tree to build against (an extracted linux-omarchy-headers).
kdir=${GL9767_KDIR:-}
if [[ -z $kdir ]]; then
  for k in /usr/lib/modules/"$ver"-*-omarchy/build; do [[ -f $k/Makefile ]] && kdir=$k; done
fi
if [[ -z $tar || -z $kdir ]] || ! command -v gcc >/dev/null; then
  echo "SKIP build: needs linux-$ver.tar.xz and linux-omarchy $ver headers (or GL9767_KDIR)"
  exit "$fail"
fi
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tar -xJf "$tar" -C "$T" "linux-$ver/drivers/mmc/host" || { bad "extract"; exit 1; }
cd "$T/linux-$ver" || exit 1
patch -sNp1 --fuzz=0 <"$P" || { bad "0570 does not apply at fuzz 0"; exit 1; }
ok "0570 applies at fuzz 0 to stock $ver"
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
