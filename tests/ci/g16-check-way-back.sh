#!/bin/bash
# bin/g16-check's "4. Way back" section (#85): before the switch, check that the
# fallback kernel has headers, an NVIDIA DKMS build, a Limine entry and a boot
# record, and that a snapshot is newer than the last pacman transaction. It only
# ever reports PASS/WARN. Offline: stub pacman, dkms, last, snapper and sudo.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin" "$T/src"
cat >"$T/bin/pacman" <<'EOF'
#!/bin/bash
case ${1:-} in
    -Q)
        [[ -n ${2:-} && -f $STUB_DIR/installed ]] || exit 1
        while read -r name ver; do
            [[ $name == "$2" ]] && { echo "$name $ver"; exit 0; }
        done <"$STUB_DIR/installed"
        echo "error: package '$2' was not found" >&2
        exit 1
        ;;
    -Qlq)
        case ${2:-} in
            linux) echo /usr/lib/modules/7.2.8-arch1-1/vmlinuz ;;
            linux-lts) echo /usr/lib/modules/6.12.50-1-lts/vmlinuz ;;
            *) exit 1 ;;
        esac
        echo /usr/share/licenses/x/LICENSE
        exit 0
        ;;
esac
exit 1
EOF
cat >"$T/bin/dkms" <<'EOF'
#!/bin/bash
[[ ${1:-} == status ]] || exit 1
[[ -f $STUB_DIR/dkms-status ]] && cat "$STUB_DIR/dkms-status"
exit 0
EOF
cat >"$T/bin/last" <<'EOF'
#!/bin/bash
[[ -f $STUB_DIR/last ]] && cat "$STUB_DIR/last"
exit 0
EOF
cat >"$T/bin/snapper" <<'EOF'
#!/bin/bash
[[ -f $STUB_DIR/snapper.csv ]] || exit 1
cat "$STUB_DIR/snapper.csv"
EOF
cat >"$T/bin/sudo" <<'EOF'
#!/bin/bash
[[ ${1:-} == -n ]] || exit 1
shift
exec "$@"
EOF
chmod +x "$T/bin/pacman" "$T/bin/dkms" "$T/bin/last" "$T/bin/snapper" "$T/bin/sudo"
export STUB_DIR=$T
export PATH="$T/bin:$PATH"

run() {
    G16_CHECK_SRC_ROOT=$T/src G16_CHECK_LIMINE_CONF=$T/limine.conf G16_CHECK_PACMAN_LOG=$T/pacman.log \
        "$W/bin/g16-check" --no-color --no-redact 2>&1 || true
}
# The text after the section 4 header up to the Summary (which counts every
# section's WARNs), so other sections' output doesn't matter.
way_back() {
    awk '/^== 4\. Way back/ { on = 1 } /^Summary:/ { on = 0 } on' <<<"$1"
}
expect() {  # expect <name> <output> <substring> [absent]
    local has=0
    [[ $2 == *"$3"* ]] && has=1
    if [[ ${4:-} == absent ]]; then
        if ((has)); then echo "not ok - $1: output has '$3'"; fails=1; else echo "ok - $1"; fi
    else
        if ((has)); then echo "ok - $1"; else echo "not ok - $1: no '$3' in the output"; fails=1; fi
    fi
}
fail_line() {  # the FAIL lines of an output
    grep -E '^ *FAIL ' <<<"$1"
}

cat >"$T/pacman.log" <<'EOF'
[2026-10-18T11:59:00+0000] [ALPM] transaction started
[2026-10-18T12:00:00+0000] [ALPM] upgraded linux (7.2.7-arch1-1 -> 7.2.8-arch1-1)
[2026-10-18T12:00:30+0000] [ALPM] transaction completed
[2026-10-18T12:01:00+0000] [PACMAN] synchronizing package lists
EOF

# (a) linux with nothing behind it, and only an older snapshot.
printf 'linux 7.2.8.arch1-1\n' >"$T/installed"
: >"$T/dkms-status"
printf 'timeout: 3\n/Omarchy\n    protocol: linux\n    path: boot():/abc/linux-omarchy/vmlinuz-linux-omarchy\n' >"$T/limine.conf"
: >"$T/last"
printf 'number,date\n0,\n1,2026-10-17 10:00:00\n' >"$T/snapper.csv"
out=$(way_back "$(run)")
expect "a: section 4 present" "$out" "== 4. Way back"
expect "a: headers WARN" "$out" "WARN  linux: linux-headers not installed"
expect "a: nvidia-open-dkms not installed: info" "$out" "linux: nvidia-open-dkms not installed"
expect "a: Limine WARN (linux-omarchy is not linux)" "$out" "WARN  linux: no Limine entry for vmlinuz-linux "
expect "a: never booted WARN" "$out" "WARN  linux: 7.2.8-arch1-1 has never booted here"
expect "a: no snapshot newer WARN" "$out" "WARN  no snapshot is newer than the last pacman transaction"
expect "a: no FAIL in section 4" "$(fail_line "$out")" "FAIL" absent
# nvidia-open-dkms installed, but no DKMS build for this kernel.
printf 'linux 7.2.8.arch1-1\nnvidia-open-dkms 580.82.09-1\n' >"$T/installed"
printf 'nvidia/580.82.09, 7.2.8-9.1-omarchy, x86_64: installed\nnvidia/580.82.09, 7.2.8-arch1-1, x86_64: built\n' >"$T/dkms-status"
out=$(way_back "$(run)")
expect "a: NVIDIA DKMS WARN" "$out" "WARN  linux: no NVIDIA DKMS build installed for 7.2.8-arch1-1"
expect "a: no FAIL in section 4 (dkms)" "$(fail_line "$out")" "FAIL" absent

# (b) everything in place, snapshot newer than the last transaction.
printf 'linux 7.2.8.arch1-1\nlinux-headers 7.2.8.arch1-1\nnvidia-open-dkms 580.82.09-1\n' >"$T/installed"
printf 'nvidia/580.82.09, 7.2.8-9.1-omarchy, x86_64: installed\nnvidia/580.82.09, 7.2.8-arch1-1, x86_64: installed\n' >"$T/dkms-status"
printf '%s\n' 'timeout: 3' '/Omarchy' '    path: boot():/abc/linux-omarchy/vmlinuz-linux-omarchy' \
    '/Linux' '    path: boot():/abc/linux/vmlinuz-linux' >"$T/limine.conf"
printf 'reboot   system boot  7.2.8-arch1-1    Sat Oct 17 09:00   still running\n' >"$T/last"
printf 'number,date\n0,\n1,2026-10-17 10:00:00\n2,2026-10-18 12:30:00\n' >"$T/snapper.csv"
out=$(way_back "$(run)")
expect "b: headers PASS" "$out" "PASS  linux: linux-headers installed"
expect "b: NVIDIA DKMS PASS" "$out" "PASS  linux: NVIDIA DKMS build installed for 7.2.8-arch1-1"
expect "b: Limine PASS" "$out" "PASS  linux: Limine entry for vmlinuz-linux "
expect "b: booted PASS" "$out" "PASS  linux: 7.2.8-arch1-1 has booted before"
expect "b: snapshot PASS" "$out" "PASS  a snapshot (#2) is newer than the last pacman transaction"
expect "b: no WARN in section 4" "$out" "WARN  " absent
expect "b: no FAIL in section 4" "$(fail_line "$out")" "FAIL" absent
# A boot of 7.2.8-arch1-10 is not a boot of 7.2.8-arch1-1.
printf 'reboot   system boot  7.2.8-arch1-10   Sat Oct 17 09:00   still running\n' >"$T/last"
out=$(way_back "$(run)")
expect "b: a longer release is not a boot record" "$out" "WARN  linux: 7.2.8-arch1-1 has never booted here"

# (c) only linux-lts; limine.conf has only vmlinuz-linux, which is not linux-lts.
printf 'linux-lts 6.12.50-1\nlinux-lts-headers 6.12.50-1\n' >"$T/installed"
printf '%s\n' '/Linux' '    path: boot():/abc/linux/vmlinuz-linux' >"$T/limine.conf"
out=$(way_back "$(run)")
expect "c: Limine WARN for linux-lts" "$out" "WARN  linux-lts: no Limine entry for vmlinuz-linux-lts"
expect "c: linux not reported" "$out" "linux: " absent
expect "c: no FAIL in section 4" "$(fail_line "$out")" "FAIL" absent

# (d) no fallback kernel at all.
printf 'linux-omarchy 7.2.8.9.1-1\n' >"$T/installed"
out=$(way_back "$(run)")
expect "d: no fallback WARN" "$out" "WARN  no fallback kernel installed"
exit $fails
