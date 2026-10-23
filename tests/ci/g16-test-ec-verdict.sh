#!/bin/bash
# recipes/linux-omarchy/g16-test (#185): the EC's fan-table byte decides a step.
#   1. ftbl_name maps FTBL (EC RAM 0x06) 0/1/2 to balanced/turbo/silent;
#   2. ec_verdict turns a load verdict into lost when the EC runs another table
#      than the asus-wmi profile's, and leaves it alone when the EC agrees or
#      can't be read;
#   3. --resume-profile's probe and --ec-table both use it;
#   4. --ec-table on a fake G16 (EC byte in a file, stubbed root and sysfs)
#      reports "disagree" for balanced under quiet and "agree" for silent.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
K=$W/recipes/linux-omarchy/g16-test
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq() { [[ $2 == "$3" ]] && ok "$1" || bad "$1: got '$2', want '$3'"; }

# shellcheck source=../../recipes/linux-omarchy/g16-test/lib.sh
G16_TEST_PR=1 source "$K/lib.sh"

eq "FTBL 0" "$(ftbl_name ' 0')" balanced
eq "FTBL 1" "$(ftbl_name '1')" turbo
eq "FTBL 2" "$(ftbl_name '   2')" silent
eq "FTBL empty" "$(ftbl_name '')" '?'
eq "FTBL other" "$(ftbl_name 7)" raw:7

eq "quiet load, EC balanced under quiet" "$(ec_verdict quiet balanced quiet)" lost
eq "quiet load, EC turbo under quiet" "$(ec_verdict quiet turbo quiet)" lost
eq "quiet load, EC silent under quiet" "$(ec_verdict quiet silent quiet)" quiet
eq "unclear load, EC silent" "$(ec_verdict unclear silent quiet)" unclear
eq "lost load, EC silent" "$(ec_verdict lost silent quiet)" lost
eq "quiet load, EC unreadable" "$(ec_verdict quiet '?' quiet)" quiet
eq "quiet load, EC raw value" "$(ec_verdict quiet raw:7 quiet)" lost
eq "balanced profile, EC balanced" "$(ec_verdict quiet balanced balanced)" quiet

grep -q 'PROBE=$(ec_verdict "${line%% \*}" "$ec" "$(profile_of asus-wmi)")' "$K/test" &&
  ok "the resume probe's verdict goes through ec_verdict" || bad "the resume probe ignores the EC table"

# ------------------------------------------------- 4. --ec-table on a fake G16
mkdir -p "$T/kit" "$T/hw/asus" "$T/hw/k10" "$T/home"
cp "$K"/* "$T/kit/"
cp "$K/../PKGBUILD" "$T/PKGBUILD"
echo 2100 >"$T/hw/asus/fan1_input"; echo 1800 >"$T/hw/asus/fan2_input"; echo 3800 >"$T/hw/asus/fan3_input"
echo 28500 >"$T/hw/k10/temp1_input"
# Run the kit's own code, minus the machine check and the mode dispatch.
sed -i "s|^source \"\$(dirname \"\$(readlink -f \"\$0\")\")/lib.sh\"|source $T/kit/lib.sh|; s/^is_g16 ||.*/true/; s/^case \$MODE in\$/case none in/" "$T/kit/test"
sed -i "s|^RECIPE_DIR=.*|RECIPE_DIR=$T|" "$T/kit/lib.sh"
cat >"$T/run.sh" <<EOF
set -u
export HOME=$T/home G16_TEST_PR=1
source $T/kit/test --ec-table </dev/null
hwmon_by_name() { case \$1 in asus) echo $T/hw/asus ;; k10temp) echo $T/hw/k10 ;; esac; }
profile_of() { case \$1 in asus-wmi) echo quiet ;; amd-pmf) echo balanced ;; esac; }
as_root() { return 0; }
root_read() { "\$@"; }
on_ac() { return 1; }
offer_post() { :; }
sleep() { :; }
EC_IO=$T/ecio
run_ectable
EOF
printf '\0\0\0\0\0\0\0\0' >"$T/ecio"
bash "$T/run.sh" >"$T/out1" 2>&1
grep -q 'Profile and EC fan table: \*\*disagree\*\*: the EC runs balanced while asus-wmi reports quiet' "$T"/home/*-ectable.md &&
  ok "--ec-table: balanced under quiet is a disagreement" || { bad "--ec-table did not flag balanced under quiet"; tail -5 "$T/out1"; }
rm -f "$T"/home/*.md
printf '\0\0\0\0\0\0\2\0' >"$T/ecio"
bash "$T/run.sh" >"$T/out2" 2>&1
grep -q 'Profile and EC fan table: agree' "$T"/home/*-ectable.md &&
  ok "--ec-table: silent under quiet agrees" || { bad "--ec-table did not agree on silent under quiet"; tail -5 "$T/out2"; }

((fails == 0)) && echo "all passed" || { echo "$fails failed"; exit 1; }
