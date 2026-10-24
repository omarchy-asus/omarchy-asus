#!/bin/bash
# omarchy-asus-g16's rcu_nocbs=all drop-in (#229), offline:
#   1. package() installs the drop-in under limine-entry-tool's vendor directory
#      and the alpm hook under libalpm's, and nothing else new;
#   2. the drop-in appends exactly " rcu_nocbs=all" to the default command line,
#      in the KERNEL_CMDLINE[default]+= form limine-entry-tool reads;
#   3. the hook fires on install and upgrade of that path (its Target matches
#      the installed file), after the transaction, and runs limine-update, or
#      says the change waits for the next kernel update when it is missing;
#   4. post_remove runs limine-update, tolerates its absence and its failure,
#      and post_install/post_upgrade still only warn off a GA605KM.
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
CONF=$T/pkg/usr/share/limine-entry-tool.d/omarchy-asus-g16-rcu-nocbs.conf
HOOK=$T/pkg/usr/share/libalpm/hooks/95-omarchy-asus-g16-limine.hook
[[ -f $CONF && -f $HOOK ]] && ok "drop-in and hook installed" || bad "missing: $(cd "$T/pkg" && find . -type f)"
got=$(cd "$T/pkg" && find . -type f | sort | paste -sd' ')
want="./usr/lib/NetworkManager/conf.d/omarchy-asus-g16-mt7925-auth-retries.conf ./usr/lib/systemd/sleep.conf.d/omarchy-asus-g16-hibernate-mode.conf ./usr/lib/systemd/system/nvidia-powerd.service.d/20-omarchy-asus.conf ./usr/lib/udev/rules.d/99-omarchy-asus-g16-touchpad-wake.rules ./usr/share/doc/omarchy-asus-g16/README.md ./usr/share/libalpm/hooks/95-omarchy-asus-g16-limine.hook ./usr/share/licenses/omarchy-asus-g16/LICENSE ./usr/share/limine-entry-tool.d/omarchy-asus-g16-rcu-nocbs.conf"
[[ $got == "$want" ]] && ok "no other new files" || bad "files: $got"
for f in "$CONF" "$HOOK"; do
  [[ $(stat -c %a "$f" 2>/dev/null) == 644 ]] || bad "$(basename "$f") not 0644"
done

# 2. the drop-in's only setting
lines=$(grep -v '^[[:space:]]*\(#\|$\)' "$CONF")
[[ $lines == 'KERNEL_CMDLINE[default]+=" rcu_nocbs=all"' ]] && ok "drop-in appends \" rcu_nocbs=all\"" || bad "drop-in: $lines"
# Evaluated the way the Omarchy drop-ins are (bash array append): the command
# line gains the parameter as its own word.
cmd=$(declare -A KERNEL_CMDLINE=([default]="root=/dev/x quiet"); eval "$lines"; printf '%s' "${KERNEL_CMDLINE[default]}")
[[ $cmd == "root=/dev/x quiet rcu_nocbs=all" ]] && ok "appends as a separate word" || bad "command line: $cmd"

# 3. the hook
trig=$(sed -n 's/^Target = //p' "$HOOK")
# shellcheck disable=SC2053 # the Target is a glob, matched as pacman does
[[ usr/share/limine-entry-tool.d/omarchy-asus-g16-rcu-nocbs.conf == $trig ]] && ok "hook Target matches the drop-in" || bad "Target $trig"
grep -qx 'Type = Path' "$HOOK" && grep -qx 'Operation = Install' "$HOOK" && grep -qx 'Operation = Upgrade' "$HOOK" &&
  grep -qx 'When = PostTransaction' "$HOOK" && ok "hook: path trigger, install and upgrade, after the transaction" || bad "hook header"
grep -q '^Operation = Remove' "$HOOK" && bad "hook claims Remove (it is deleted before it could run)" || ok "removal left to post_remove"
exec_line=$(sed -n 's/^Exec = //p' "$HOOK")
mkdir -p "$T/bin" "$T/nobin"
printf '#!/bin/sh\necho ran >>"%s/updates"\n' "$T" >"$T/bin/limine-update"
chmod +x "$T/bin/limine-update"
# The install script also asks NetworkManager to reread its configuration
# (#196, checked in mt7925-auth-retries.test.sh); never let it reach the host's.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/nmcli"
chmod +x "$T/bin/nmcli"
for b in sh cat grep printf; do ln -sf "$(command -v "$b")" "$T/nobin/$b"; done
[[ ${exec_line%% *} == /bin/sh ]] || bad "Exec does not start with /bin/sh: $exec_line"
cmdstr=$(sed -n "s/^Exec = \/bin\/sh -c '\(.*\)'$/\1/p" "$HOOK")
PATH="$T/bin:$PATH" sh -c "$cmdstr" >/dev/null && [[ $(cat "$T/updates" 2>/dev/null) == ran ]] && ok "hook runs limine-update" || bad "hook did not run limine-update"
out=$(PATH="$T/nobin" sh -c "$cmdstr" 2>&1); rc=$?
[[ $rc == 0 && $out == *"next kernel update"* ]] && ok "hook without limine-update says so and succeeds" || bad "hook without limine-update: rc=$rc $out"

# 4. the install script
rm -f "$T/updates"
(
  PATH="$T/bin:$PATH"
  # shellcheck disable=SC1091
  source "$R/omarchy-asus-g16.install"
  post_remove
) && [[ $(cat "$T/updates" 2>/dev/null) == ran ]] && ok "post_remove runs limine-update" || bad "post_remove did not run limine-update"
out=$(export PATH="$T/nobin"; source "$R/omarchy-asus-g16.install"; post_remove 2>&1); rc=$?
[[ $rc == 0 ]] && ok "post_remove without limine-update succeeds" || bad "post_remove without limine-update: rc=$rc $out"
printf '#!/bin/sh\nexit 3\n' >"$T/bin/limine-update"
out=$(PATH="$T/bin:$PATH"; source "$R/omarchy-asus-g16.install"; post_remove 2>&1); rc=$?
[[ $rc == 0 && $out == *"run it by hand"* ]] && ok "a failing limine-update warns, removal goes on" || bad "failing limine-update: rc=$rc $out"
rm -f "$T/updates"
out=$(PATH="$T/bin:$PATH"; source "$R/omarchy-asus-g16.install"; post_install 2>&1; post_upgrade 2>&1)
[[ ! -e $T/updates ]] && ok "post_install/post_upgrade leave the entries to the hook" || bad "post_install ran limine-update"

((fails == 0)) && echo "all g16-rcu-nocbs checks passed" || { echo "$fails check(s) failed"; exit 1; }
