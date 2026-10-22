#!/bin/bash
# Shared helpers for recipes/linux-omarchy/g16-test/{deploy,test}. Sourced, not run.
# shellcheck disable=SC2034  # variables here are used by the sourcing scripts

GH_REPO=omarchy-asus/omarchy-asus
# The kernel PR this checkout is on (gh pr checkout N), so reports and CI
# artifacts follow the PR under test. G16_TEST_PR=N overrides; 8 is the first.
PR=${G16_TEST_PR:-$(gh pr view --json number -q .number 2>/dev/null || true)}
[[ $PR =~ ^[0-9]+$ ]] || PR=8
TEMPS_ISSUE=42
RESUME_ISSUE=185
WORKFLOW=build-pr.yml
KIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECIPE_DIR=$(cd "$KIT_DIR/.." && pwd)
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-asus-g16-test

# Expected package version, read from the PKGBUILD next to this kit (no sourcing).
pkgbuild_var() { sed -n "s/^$1=\\([^ #]*\\).*/\\1/p" "$RECIPE_DIR/PKGBUILD" | head -n1; }
PKGVER=$(pkgbuild_var pkgver)
PKGREL=$(pkgbuild_var pkgrel)
EXPECT_VER=$PKGVER-$PKGREL                 # 7.2.8-9.3
EXPECT_KREL=$PKGVER-$PKGREL-omarchy        # 7.2.8-9.3-omarchy

if [[ -t 1 ]]; then B=$'\e[1m' R=$'\e[31m' Y=$'\e[33m' G=$'\e[32m' D=$'\e[2m' N=$'\e[0m'; else B='' R='' Y='' G='' D='' N=''; fi

say() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Before every sudo step: say what it does, then run it.
SUDO_OK=0
as_root() {
  local why=$1; shift
  printf '%s[sudo]%s %s\n' "$Y" "$N" "$why" >&2
  printf '       %s%s%s\n' "$D" "$*" "$N" >&2
  if [[ ${G16_ROOT:-} == pkexec ]]; then
    # Through polkit: from the user manager, the desktop session's agent asks.
    # G16_POLKIT_REASON names a wrapper (`W run REASON -- pkexec CMD`) that shows
    # the reason in the dialog; without it the dialog shows only the command.
    if [[ -n ${G16_POLKIT_REASON:-} ]]; then
      systemd-run --user --wait -q -P "$G16_POLKIT_REASON" run "$why" -- pkexec "$@"
    else
      systemd-run --user --wait -q -P pkexec --disable-internal-agent "$@"
    fi
  else
    sudo "$@"
  fi
}
# Root reads that must not prompt mid-test (sudo -v was done up front).
root_read() { sudo -n "$@" 2>/dev/null; }

dmi() { local v=''; read -r v 2>/dev/null <"/sys/class/dmi/id/$1"; printf '%s' "$v"; }
is_g16() { [[ $(dmi product_name) == *GA605* || $(dmi board_name) == *GA605* ]]; }

# Mains power online? (0 = on battery)
on_ac() {
  local s t o
  for s in /sys/class/power_supply/*; do
    t='' o=''
    read -r t 2>/dev/null <"$s/type" || true
    [[ $t == Mains ]] || continue
    read -r o 2>/dev/null <"$s/online" || true
    [[ $o == 1 ]] && return 0
  done
  return 1
}

hwmon_by_name() {
  local h n
  for h in /sys/class/hwmon/hwmon*; do
    n=''
    read -r n 2>/dev/null <"$h/name" || true
    [[ $n == "$1" ]] && { printf '%s\n' "$h"; return 0; }
  done
  return 1
}

profile_of() {
  local d n p
  for d in /sys/class/platform-profile/platform-profile-*; do
    n='' p=''
    read -r n 2>/dev/null <"$d/name" || true
    [[ $n == "$1" ]] || continue
    read -r p 2>/dev/null <"$d/profile" || true
    printf '%s\n' "${p:-?}"
    return 0
  done
  printf 'absent\n'
}

# The NVIDIA dGPU's PCI sysfs dir.
dgpu_dir() {
  local d v c
  for d in /sys/bus/pci/devices/*; do
    v='' c=''
    read -r v 2>/dev/null <"$d/vendor" || true
    read -r c 2>/dev/null <"$d/class" || true
    [[ $v == 0x10de && $c == 0x03* ]] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# Kernel log of this boot (journal first: wheel can read it; dmesg needs root).
klog() {
  local out
  out=$(journalctl -k -b -o short-monotonic --no-pager 2>/dev/null)
  if [[ -z $out ]]; then out=$(root_read dmesg || true); fi
  printf '%s\n' "$out"
}

# Count kernel log lines per class. Prints key=value lines.
KLOG_CLASSES=(
  "oops|Oops|BUG:|kernel BUG|general protection|Call Trace|WARNING: CPU|------------\\[ cut here"
  "amdgpu|amdgpu.*([Ee]rror|[Ff]ail|timeout|ring .* timeout|\\*ERROR\\*)"
  "i2c|(i2c_designware|i2c-designware|i2c_hid|i2c-hid).*([Ee]rror|timed out|timeout|[Ff]ail)|controller timed out"
  "nvidia|(NVRM|nvidia).*([Ee]rror|[Ff]ail|Xid)"
  "hidasus|hid[-_]asus.*([Ee]rror|[Ff]ail)"
  "armoury|asus[-_]armoury.*([Ee]rror|[Ff]ail|No matching power limits)"
)
klog_counts() {
  local log entry key re
  log=$(klog)
  for entry in "${KLOG_CLASSES[@]}"; do
    key=${entry%%|*} re=${entry#*|}
    printf 'klog_%s=%s\n' "$key" "$(grep -cE -- "$re" <<<"$log" || true)"
  done
  printf 'klog_err=%s\n' "$(journalctl -k -b -p err -o cat --no-pager 2>/dev/null | wc -l)"
}
klog_lines() { # class -> matching lines (timestamps kept)
  local entry
  for entry in "${KLOG_CLASSES[@]}"; do
    [[ ${entry%%|*} == "$1" ]] && { klog | grep -E -- "${entry#*|}" || true; return; }
  done
}

ARMOURY=/sys/class/firmware-attributes/asus-armoury/attributes
ARMOURY_ATTRS=(ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt nv_dynamic_boost nv_temp_target)
armoury_read() { # attr -> "min-max cur=N" or the error
  local a=$ARMOURY/$1 mn mx cur
  [[ -d $a ]] || { printf 'absent'; return; }
  mn=$(cat "$a/min_value" 2>&1) mx=$(cat "$a/max_value" 2>&1) cur=$(cat "$a/current_value" 2>&1)
  mn=${mn##*: } mx=${mx##*: } cur=${cur##*: }
  printf '%s-%s cur=%s' "$mn" "$mx" "$cur"
}

panel_power_path() { compgen -G '/sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings' | head -n1; }
hfi_dir() { local f; f=$(compgen -G '/sys/bus/platform/drivers/amd_hfi/*/ranking' | head -n1); [[ -n $f ]] && dirname "$f"; }

# Touchpad: the event node and the DesignWare IRQ lines.
touchpad_event() {
  awk 'BEGIN{RS=""} /N: Name=.*[Tt]ouchpad/ { if (match($0, /event[0-9]+/)) { print "/dev/input/" substr($0, RSTART, RLENGTH); exit } }' /proc/bus/input/devices
}
dw_irq_counts() { # "irq total" per DesignWare / AMDI0010 line
  awk '/AMDI0010|designware|i2c_designware/ { s=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; else break; sub(":","",$1); print $1, s }' /proc/interrupts
}

# Strip personal information from text that leaves the machine: user name, host
# name, $HOME, MAC addresses, UUIDs and IP addresses.
redact() {
  local me host
  me=$(id -un 2>/dev/null || echo "${USER:-}")
  host=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
  python3 -I -c '
import re, sys
home, me, host = sys.argv[1:4]
t = sys.stdin.read()
if home and home != "/":
    t = t.replace(home, "~")
for word, mark in ((host, "<host>"), (me, "<user>")):
    if len(word) >= 2:
        t = re.sub(r"(?<![A-Za-z0-9_.-])" + re.escape(word) + r"(?![A-Za-z0-9_-])", mark, t)
t = re.sub(r"\b[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\b", "<mac>", t)
t = re.sub(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<uuid>", t)
t = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", t)
t = re.sub(r"\b[0-9a-f]{32}\b", "<id>", t)
sys.stdout.write(t)
' "$HOME" "$me" "$host"
}

# Show a report, then offer to post it (PR comment or issue comment).
offer_post() { # file kind(pr|issue) number
  local f=$1 kind=$2 num=$3 ans
  printf '\n%s----- report: %s -----%s\n' "$B" "${f/#$HOME/\~}" "$N"
  cat "$f"
  printf '%s----- end of report -----%s\n\n' "$B" "$N"
  if ! have gh; then note "gh is not installed: post it by hand with: gh $kind comment $num -R $GH_REPO --body-file ${f/#$HOME/\~}"; return; fi
  read -r -p "Post this report as a comment on $GH_REPO $([[ $kind == pr ]] && echo "PR" || echo "issue") #$num? [y/N] " ans || ans=n
  if [[ $ans == [yY]* ]]; then
    gh "$kind" comment "$num" -R "$GH_REPO" --body-file "$f" && say "posted"
  else
    note "not posted. Later: gh $kind comment $num -R $GH_REPO --body-file ${f/#$HOME/\~}"
  fi
}

# Win-lock: the keyboard's hidraw node that declares report 0x5D, or nothing.
winlock_hidraw() {
  python3 -I - <<'PY'
import glob, pathlib
def ids(d):
    out, i = set(), 0
    while i < len(d):
        p = d[i]
        if p == 0xFE:
            if i + 2 >= len(d): return out
            i += 3 + d[i + 1]; continue
        n = (0, 1, 2, 4)[p & 3]
        if p & 0xFC == 0x84 and n >= 1 and i + 1 < len(d): out.add(d[i + 1])
        i += 1 + n
    return out
for u in sorted(glob.glob("/sys/class/hidraw/hidraw*/device/uevent")):
    node = pathlib.Path(u).parents[1]
    try:
        if "00000B05:000019B6" not in pathlib.Path(u).read_text().upper(): continue
        if 0x5D in ids((node / "device" / "report_descriptor").read_bytes()):
            print("/dev/" + node.name); break
    except OSError:
        pass
PY
}

# One snapshot of everything the tests compare, as key=value lines.
collect_state() {
  local a v p d rs
  printf 'krel=%s\n' "$(uname -r)"
  printf 'pkg_linux_omarchy=%s\n' "$(pacman -Q linux-omarchy 2>/dev/null | cut -d' ' -f2)"
  printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
  printf 'on_ac=%s\n' "$(on_ac && echo 1 || echo 0)"
  klog_counts
  printf 'winlock_hidraw=%s\n' "$(winlock_hidraw || true)"
  if have g16-winlock; then
    v=$(g16-winlock status 2>&1 | grep -o 'locked=[A-Za-z]*' | head -n1)
    printf 'winlock_state=%s\n' "${v:-unknown}"
  else
    printf 'winlock_state=no-g16-winlock\n'
  fi
  printf 'hid_asus=%s\n' "$(modinfo -n hid_asus 2>/dev/null | sed "s|.*/modules/[^/]*/||")"
  for a in "${ARMOURY_ATTRS[@]}"; do printf 'armoury_%s=%s\n' "$a" "$(armoury_read "$a")"; done
  printf 'armoury_nv_tgp=%s\n' "$([[ -d $ARMOURY/nv_tgp ]] && echo present || echo absent)"
  printf 'armoury_nomatch=%s\n' "$(klog | grep -c 'No matching power limits' || true)"
  p=$(panel_power_path || true)
  if [[ -n $p ]]; then printf 'panel_power_savings=%s\n' "$(cat "$p" 2>&1)"; else printf 'panel_power_savings=absent\n'; fi
  d=$(hfi_dir || true)
  if [[ -n $d ]]; then
    for a in ranking wake_preferred wlc_track wake_pack; do printf 'hfi_%s=%s\n' "$a" "$(cat "$d/$a" 2>/dev/null || echo absent)"; done
  else
    printf 'hfi_ranking=absent\n'
  fi
  for a in success fail last_hw_sleep total_hw_sleep; do
    printf 'suspend_%s=%s\n' "$a" "$(cat "/sys/power/suspend_stats/$a" 2>/dev/null || echo absent)"
  done
  printf 'mem_sleep=%s\n' "$(cat /sys/power/mem_sleep 2>/dev/null)"
  d=$(dgpu_dir || true)
  rs=absent
  [[ -n $d ]] && rs=$(cat "$d/power/runtime_status" 2>/dev/null)
  printf 'dgpu_runtime=%s\n' "$rs"
  printf 'nvidia_module=%s\n' "$(cat /sys/module/nvidia/version 2>/dev/null || echo not-loaded)"
  printf 'profile_asus=%s\n' "$(profile_of asus-wmi)"
  printf 'profile_amd=%s\n' "$(profile_of amd-pmf)"
  printf 'dw_irqs=%s\n' "$(dw_irq_counts | tr '\n' ' ')"
}
state_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; } # file key
