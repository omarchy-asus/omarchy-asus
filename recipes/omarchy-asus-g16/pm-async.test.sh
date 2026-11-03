#!/bin/bash
# omarchy-asus-g16's pm_async=off drop-in (#397), offline:
#   1. package() installs the drop-in under limine-entry-tool's vendor
#      directory, mode 0644, next to the rcu_nocbs one;
#   2. the drop-in appends exactly " pm_async=off" to the default command line,
#      in the KERNEL_CMDLINE[default]+= form limine-entry-tool reads, and stacks
#      with the rcu_nocbs drop-in in either order;
#   3. "off" is the one value the kernel's pm_async= parser accepts;
#   4. the package's alpm hook (checked in rcu-nocbs.test.sh) fires for it too.
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
: >"$T/src/0010-FocalTech__ASUF1209.bpf.o" # build()'s product; this test doesn't run clang
(
  cd "$T/src" || exit 1
  # shellcheck disable=SC1091
  source ./PKGBUILD
  # shellcheck disable=SC2034 # read by package()
  srcdir=$T/src pkgdir=$T/pkg
  package
) || bad "package() failed"
D=$T/pkg/usr/share/limine-entry-tool.d
CONF=$D/omarchy-asus-g16-pm-async.conf
[[ -f $CONF ]] && ok "drop-in installed" || bad "missing $CONF"
[[ $(stat -c %a "$CONF" 2>/dev/null) == 644 ]] && ok "drop-in is 0644" || bad "drop-in not 0644"
cmp -s "$CONF" "$R/omarchy-asus-g16-pm-async.conf" && ok "installed byte-identical" || bad "installed copy differs"

# 2. the drop-in's only setting, alone and stacked with rcu_nocbs
lines=$(grep -v '^[[:space:]]*\(#\|$\)' "$CONF")
[[ $lines == 'KERNEL_CMDLINE[default]+=" pm_async=off"' ]] && ok "drop-in appends \" pm_async=off\"" || bad "drop-in: $lines"
rcu=$(grep -v '^[[:space:]]*\(#\|$\)' "$D/omarchy-asus-g16-rcu-nocbs.conf")
cmd=$(declare -A KERNEL_CMDLINE=([default]="root=/dev/x quiet"); eval "$rcu"; eval "$lines"; printf '%s' "${KERNEL_CMDLINE[default]}")
[[ $cmd == "root=/dev/x quiet rcu_nocbs=all pm_async=off" ]] && ok "stacks after rcu_nocbs" || bad "command line: $cmd"
cmd=$(declare -A KERNEL_CMDLINE=([default]="root=/dev/x"); eval "$lines"; eval "$rcu"; printf '%s' "${KERNEL_CMDLINE[default]}")
[[ $cmd == "root=/dev/x pm_async=off rcu_nocbs=all" ]] && ok "stacks before rcu_nocbs" || bad "command line: $cmd"

# 3. kernel/power/main.c: pm_async_setup() clears pm_async_enabled only on !strcmp(str, "off")
val=${lines#*pm_async=}
val=${val%\"}
[[ $val == off ]] && ok "value is \"off\", the one pm_async_setup() acts on" || bad "value: $val"

# 4. the alpm hook's Target covers this drop-in
trig=$(sed -n 's/^Target = //p' "$R/omarchy-asus-g16-limine.hook")
# shellcheck disable=SC2053 # the Target is a glob, matched as pacman does
[[ usr/share/limine-entry-tool.d/omarchy-asus-g16-pm-async.conf == $trig ]] && ok "hook Target matches the drop-in" || bad "Target $trig"

((fails == 0)) && echo "all g16-pm-async checks passed" || { echo "$fails check(s) failed"; exit 1; }
