#!/bin/bash
# A reinstall of the auto-update copy starts a run when the timer was already enabled (#217):
# while the copy was stale every run published nothing, and the next timer slot can be a day
# away. bin/install-auto-update runs in its plan mode (no --apply) against a fake systemctl:
#   1. timer enabled: the plan starts one run, without blocking (--no-block)
#   2. timer enabled, --no-run: no run, and it says so
#   3. timer not enabled (a first install): no run; the "first run by hand" advice stays
#   4. timer not enabled, --enable: still no run (the first run is watched by hand)
#   5. --uninstall: no run
# Offline: no network, no sudo.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
has() {  # has <name> <output> <text>
    if grep -qF -- "$3" <<<"$2"; then echo "ok - $1"; else echo "not ok - $1: no '$3' in:"; sed 's/^/    /' <<<"$2"; fails=1; fi
}
lacks() {
    if grep -qF -- "$3" <<<"$2"; then echo "not ok - $1: unexpected '$3' in:"; sed 's/^/    /' <<<"$2"; fails=1; else echo "ok - $1"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
# Fake: only the read-only query answers; anything else would be a real change.
if [[ $1 == is-enabled ]]; then [[ $FAKE_TIMER == enabled ]]; exit; fi
echo "fake systemctl: unexpected call: $*" >&2
exit 99
EOF
chmod +x "$T/bin/systemctl"
inst() { PATH="$T/bin:$PATH" FAKE_TIMER=$1 SUDO_USER=$(id -un) "$W/bin/install-auto-update" "${@:2}" 2>&1; }
start='would run: systemctl start --no-block omarchy-asus-auto-update.service'

out=$(inst enabled)
has "1. enabled: starts a run" "$out" "$start"
lacks "1. enabled: no first-run advice" "$out" "first run by hand"
lacks "1. enabled: no 'timer not enabled'" "$out" "timer not enabled"

out=$(inst enabled --no-run)
lacks "2. --no-run: no run" "$out" "systemctl start"
has "2. --no-run: says so" "$out" "no run started (--no-run)"

out=$(inst disabled)
lacks "3. first install: no run" "$out" "--no-block"
has "3. first install: first-run advice" "$out" "first run by hand"

out=$(inst disabled --enable)
lacks "4. first install --enable: no run" "$out" "--no-block"
has "4. first install --enable: enables the timer" "$out" "would run: systemctl enable --now omarchy-asus-auto-update.timer"

out=$(inst enabled --uninstall)
lacks "5. --uninstall: no run" "$out" "systemctl start"

exit "$fails"
