#!/bin/bash
# bin/g16-check names a hid-asus DKMS source dir and says whether a package owns
# it (#87): Arch's DKMS hook registers every /usr/src/*/dkms.conf again on each
# kernel transaction, so after `dkms remove` an unowned source brings it back.
# Offline: stub dkms and pacman, a fake source root.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0

mkdir -p "$T/bin" "$T/src/hid-asus-winlock-1" "$T/src/other-1"
cat >"$T/bin/dkms" <<'EOF'
#!/bin/bash
[[ ${1:-} == status ]] || exit 1
[[ -f $STUB_DIR/dkms-status ]] && cat "$STUB_DIR/dkms-status"
exit 0
EOF
cat >"$T/bin/pacman" <<'EOF'
#!/bin/bash
if [[ ${1:-} == -Qqo && -n ${2:-} ]]; then
    if [[ -f $STUB_DIR/owned ]]; then
        while read -r p pkg; do
            [[ $p == "$2" ]] && { echo "$pkg"; exit 0; }
        done <"$STUB_DIR/owned"
    fi
    echo "error: No package owns $2" >&2
    exit 1
fi
exit 1
EOF
chmod +x "$T/bin/dkms" "$T/bin/pacman"
printf 'PACKAGE_NAME=hid-asus-winlock\nPACKAGE_VERSION=1\nBUILT_MODULE_NAME[0]=hid-asus\n' >"$T/src/hid-asus-winlock-1/dkms.conf"
printf 'PACKAGE_NAME=other\nPACKAGE_VERSION=1\nBUILT_MODULE_NAME[0]=other\n' >"$T/src/other-1/dkms.conf"
export STUB_DIR=$T
export PATH="$T/bin:$PATH"

run() {
    G16_CHECK_SRC_ROOT=$T/src "$W/bin/g16-check" --no-color --no-redact 2>&1 || true
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
# Lines that mention hid-asus or DKMS must never name the unrelated source.
no_other() {  # no_other <name> <output>
    if grep -iE 'hid[-_.]asus|dkms' <<<"$2" | grep -q 'other-1'; then
        echo "not ok - $1: other-1 in a hid-asus line"; fails=1
    else
        echo "ok - $1"
    fi
}
fail_line() {  # the FAIL lines of an output
    grep -E '^ *FAIL ' <<<"$1"
}

# (a) registered with DKMS, unowned source.
echo 'hid-asus-winlock/1: added' >"$T/dkms-status"
out=$(run)
expect "a: registered: FAIL" "$(fail_line "$out")" "DKMS still registers a hid-asus module"
expect "a: registered: source is unowned" "$out" "hid-asus-winlock-1 is not owned by any package"
no_other "a: other-1 not reported" "$out"

# (b) right after `dkms remove`: nothing registered, unowned source still there.
: >"$T/dkms-status"
out=$(run)
expect "b: removed, source left: FAIL names the source" "$(fail_line "$out")" "hid-asus-winlock-1 is not owned by any package"
expect "b: removed, source left: hint says unowned" "$out" "not owned by any package, so the DKMS hook adds it again"
expect "b: removed, source left: no PASS" "$out" "PASS  no hid-asus module registered with DKMS" absent
no_other "b: other-1 not reported" "$out"

# (c) the source belongs to a package.
echo "$T/src/hid-asus-winlock-1 hid-asus-winlock-dkms" >"$T/owned"
out=$(run)
expect "c: owned source: FAIL names the package" "$(fail_line "$out")" "(package hid-asus-winlock-dkms)"
expect "c: owned source: hint names the package" "$out" "owned by package hid-asus-winlock-dkms"
no_other "c: other-1 not reported" "$out"

# (d) source moved away, nothing registered.
rm -rf "$T/src/hid-asus-winlock-1" "$T/owned"
out=$(run)
expect "d: clean: PASS" "$out" "PASS  no hid-asus module registered with DKMS"
expect "d: clean: no source reported" "$out" "hid-asus-winlock-1" absent
no_other "d: other-1 not reported" "$out"
exit $fails
