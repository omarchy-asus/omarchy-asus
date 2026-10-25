#!/bin/bash
# bin/old-path-inventory (#258), offline, against a fake system root (a chroot, the data dir of
# a user named after a denylist word, the runner's home, units, cron and sudoers), a fake repo
# tree, and stubs for pacman and ssh:
#   1. the expected rows: the chroot and its hand-added config and packages, the release ccache
#      and distcc key, bin/build-pkg's work dirs, keyrings and logs, a $DATA entry no tracked
#      file names, a unit and a crontab that call bin/build-pkg, sudoers that need root,
#      devtools, the helper's authorized_keys line, the repo's old-path files with their
#      references, the chroot sections of docs/distcc.md, the variables, old-path-only and mixed
#      tests, the issues the old path names, and the two ccaches and two distcc keys
#   2. safe to post: no home path, user name, runner name or helper target in the output, and
#      it passes the PII scan; a $DATA entry named after a denylist word makes it print nothing
#      and exit 1, unless --local
#   3. read-only: the fake trees are the same before and after, and the script holds no
#      destructive command
# Usage: tests/ci/old-path-inventory.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'chmod -R u+rwX "$S" 2>/dev/null; rm -rf "$S"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
has() { if grep -qF -- "$1" <<<"$out"; then ok "${2:-has: $1}"; else bad "${2:-missing: $1}"; fi; }
# hasre <ERE> [label]: SZ in it stands for a size column, which varies with the filesystem
SZ='[0-9.]+[KMG]?i?B'
hasre() { if grep -qE -- "$1" <<<"$out"; then ok "${2:-has: $1}"; else bad "${2:-missing: $1}"; fi; }
hasnt() { if grep -qiF -- "$1" <<<"$out"; then bad "${2:-unexpected: $1}"; else ok "${2:-not shown: $1}"; fi; }

SYS=$S/sys
U=zorbleplex                                  # the fake user: a denylist word
H=$SYS/home/$U
D=$H/.local/share/omarchy-asus
C=$SYS/var/lib/omarchy-asus/chroot
R=$SYS/var/lib/runnerz                        # the runner's home: a denylist word too
mkdir -p "$D"/{ccache,distcc,work-foo.AbCd,verify-gnupg/foo,logs,mystery-dir} "$S/stubs" "$S/ws"/{bin,build,ci,docs,tests/ci} \
    "$C/root/etc/makepkg.conf.d" "$C/$U" "$SYS/etc/systemd/system" "$SYS/etc/sudoers.d" "$SYS/var/spool/cron" \
    "$R"/{actions-runner/_work,ccache,distcc}
for p in base-devel:1-2 ccache:4.14-1 distcc:3.4-16 gcc:15.2-1:1 vim:9.1-1; do
    IFS=: read -r n v r <<<"$p"
    mkdir -p "$C/root/var/lib/pacman/local/$n-$v"
    printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%SIZE%%\n2048\n\n%s' "$n" "$v" "${r:+%REASON%
$r
}" >"$C/root/var/lib/pacman/local/$n-$v/desc"
done
printf 'DISTCC_HOSTS="someone@helper/8"\n' >"$C/root/etc/makepkg.conf.d/distcc.conf"
printf 'export CCACHE_DIR=/ccache\nexport CCACHE_MAXSIZE=40G\n' >"$C/root/etc/makepkg.conf.d/ccache.conf"
printf 'PACKAGER="omarchy-asus"\n' >"$C/root/etc/makepkg.conf.d/packager.conf"
: >"$C/$U.lock"
head -c 100000 /dev/zero >"$D/ccache/blob"
head -c 5000 /dev/zero >"$D/logs/foo-20261001-120000.log"
: >"$D/logs/foo-20261001-120000.log.verify"
: >"$D/logs/other.log"
printf 'ExecStart=%s/Work/repo/bin/build-pkg recipes/foo\n' "$H" >"$SYS/etc/systemd/system/old-build.service"
printf 'ExecStart=/usr/bin/true\n' >"$SYS/etc/systemd/system/unrelated.service"
printf '[Timer]\nOnCalendar=daily\n' >"$SYS/etc/systemd/system/old-build.timer"
printf '[Timer]\nOnCalendar=weekly\nUnit=old-build.service\n' >"$SYS/etc/systemd/system/weekly-build.timer"
printf '[Timer]\nOnCalendar=daily\n' >"$SYS/etc/systemd/system/unrelated.timer"
# same name as a unit that calls the old path, but it starts another one
mkdir -p "$SYS/etc/systemd/user" "$H/.config/systemd/user"
printf 'ExecStart=%s/Work/repo/bin/build-pkg recipes/bar\n' "$H" >"$H/.config/systemd/user/user-build.service"
printf '[Timer]\nOnCalendar=daily\nUnit=unrelated.service\n' >"$H/.config/systemd/user/user-build.timer"
# a user timer naming a system unit: another manager, not counted
printf '[Timer]\nOnCalendar=daily\nUnit=old-build.service\n' >"$H/.config/systemd/user/cross.timer"
# a timer for every user, starting this user's unit
printf '[Timer]\nOnCalendar=daily\nUnit=user-build.service\n' >"$SYS/etc/systemd/user/all-users.timer"
printf '0 3 * * * %s/Work/repo/bin/build-pkg recipes/foo\n' "$H" >"$SYS/var/spool/cron/$U"
printf 'OMARCHY_ASUS_CI_CCACHE=%s/ccache\nOMARCHY_ASUS_CI_DISTCC=%s/distcc\n' "$R" "$R" >"$R/actions-runner/.env"
head -c 30000 /dev/zero >"$R/ccache/blob"
keys=0
if command -v ssh-keygen >/dev/null; then
    ssh-keygen -q -t ed25519 -N '' -C "$U@laptop" -f "$D/distcc/id_ed25519" && \
        ssh-keygen -q -t ed25519 -N '' -C runner -f "$R/distcc/id_ed25519" && keys=1
fi
((keys)) || { [[ -n ${CI:-} ]] && { echo "FAIL: ssh-keygen missing on CI"; exit 1; }; echo "note: no ssh-keygen, key checks skipped"; }

# the fake repo tree
cat >"$S/ws/bin/build-pkg" <<'EOF'
#!/bin/bash
# chroot build; DISTCC_KEY_DIR and CCACHE_HOST_DIR (#237, #258)
makechrootpkg -c -u -r "$CHROOT"
EOF
printf '#!/bin/bash\n# make the chroot (#201)\nmkarchroot root base-devel\n' >"$S/ws/bin/mkchroot"
printf '#!/bin/bash\n# bwrap\n' >"$S/ws/bin/recipe-sandbox"
printf '#!/bin/bash\n# uses bin/recipe-sandbox\n' >"$S/ws/bin/rebase-recipe"
printf '# for CCACHE_HOST_DIR= (#237)\n' >"$S/ws/build/no-ccache.conf"
printf 'export CCACHE_MAXSIZE=15G\n' >"$S/ws/ci/build-recipe"
printf '#!/bin/bash\narch-nspawn "$copy" true\n' >"$S/ws/bin/revdep-check"
cat >"$S/ws/docs/distcc.md" <<'EOF'
# Distributed builds

## Requirements

Nothing about it here.

## Setup

```bash
# not a heading: a comment in a code block about the chroot
```

The chroot's distcc.conf (#163).

## Persistent ccache

Mount it in the chroot. Again the chroot.
EOF
printf '#!/bin/bash\n"$W/bin/build-pkg" --help\n' >"$S/ws/tests/ci/build-pkg-args.sh"
printf '#!/bin/bash\n"$W/bin/build-pkg" x; "$W/bin/publish" y\n' >"$S/ws/tests/ci/mixed.sh"
printf '#!/bin/bash\n"$W/bin/publish" y\n' >"$S/ws/tests/ci/unrelated.sh"

# stubs: pacman (devtools only), ssh (the helper's authorized_keys), gh (must not be called)
cat >"$S/stubs/pacman" <<'EOF'
#!/bin/bash
[[ $* == "-Qi devtools" ]] || { echo "unexpected pacman $*" >&2; exit 1; }
printf 'Name            : devtools\nVersion         : 1:1.5.3-1\nRequired By     : None\nInstalled Size  : 462.79 KiB\n'
EOF
cat >"$S/stubs/ssh" <<EOF
#!/bin/bash
echo "\$*" >>"$S/ssh.log"
cat "$S/authorized_keys"
EOF
printf '#!/bin/bash\necho "gh $*" >>"%s/gh.log"; exit 1\n' "$S" >"$S/stubs/gh"
chmod +x "$S/stubs"/*
{
    echo "ssh-ed25519 AAAAunrelated other"
    ((keys)) && echo "restrict,command=\"x\" $(cat "$D/distcc/id_ed25519.pub")"
    ((keys)) && echo "restrict $(cat "$R/distcc/id_ed25519.pub")"
} >"$S/authorized_keys"
printf '# test denylist\n%s\nrunnerz\nhelperbox\n' "$U" >"$S/deny"

snap() { find "$SYS" "$S/ws" -printf '%p %s %T@ %m\n' 2>/dev/null | sort; }
chmod 000 "$SYS/etc/sudoers.d"
before=$(snap)
run() {  # run [VAR=value...] [args]: the script in the fake world; VAR=value after the resets
    local a=()
    while [[ ${1:-} == [A-Z]*=* ]]; do a+=("$1"); shift; done
    env -u PII_SCAN -u RUNNER_USER -u OMARCHY_ASUS_RUNNER_USER -u BUILD_USER -u CCACHE_HOST_DIR -u DISTCC_KEY_DIR \
        HOME="$H" PATH="$S/stubs:$PATH" PII_DENYLIST="$S/deny" \
        OMARCHY_ASUS_SYSROOT="$SYS" OMARCHY_ASUS_DATA="$D" OMARCHY_ASUS_WORKSPACE="$S/ws" \
        OMARCHY_ASUS_CHROOT="$C" OMARCHY_ASUS_RUNNER_HOME="$R" "${a[@]}" "$W/bin/old-path-inventory" "$@"
}

echo "== 1. the expected rows"
out=$(run --helper helperbox --offline 2>"$S/err"); rc=$?
[[ $rc == 0 ]] && ok "exit 0" || { bad "exit $rc"; cat "$S/err"; }
after=$(snap)
[[ ${SHOW:-} == 1 ]] && echo "$out"
has '| /var/lib/omarchy-asus/chroot | chroot (quattro, rc) |'
has '| /var/lib/omarchy-asus/chroot/root | chroot root |'
has '| /var/lib/omarchy-asus/chroot/<copy 1> | build copy (makechrootpkg -c) |'
has '| /var/lib/omarchy-asus/chroot/*.lock | lock files (1) |'
has '/root/etc/makepkg.conf.d/distcc.conf | chroot makepkg config |'
has '| put there by hand (docs/distcc.md); names the helper, not shown |' "distcc.conf, contents not shown"
has 'Persistent ccache); CCACHE_MAXSIZE 40G |' "ccache.conf and its size limit"
has '| made by bin/mkchroot |' "packager.conf"
has '| chroot: ccache 4.14-1 | package in the chroot | 2.0KiB | added by hand (docs/distcc.md) (explicit) |'
has '| chroot: distcc 3.4-16 | package in the chroot |'
has '| chroot: vim 9.1-1 | package in the chroot | 2.0KiB | installed explicitly: not from bin/mkchroot (base-devel) (explicit) |'
hasnt 'chroot: gcc' "a dependency is not listed"
hasnt 'chroot: base-devel' "base-devel is not listed"
has '| ~/.local/share/omarchy-asus/ccache | release ccache |'
has '| ~/.local/share/omarchy-asus/distcc | release distcc key dir |'
has '| ~/.local/share/omarchy-asus/work-foo.AbCd | bin/build-pkg work dir |'
has '| ~/.local/share/omarchy-asus/verify-gnupg | bin/build-pkg recipe keyrings |'
has '| ~/.local/share/omarchy-asus/logs/<recipe>-<date>.log* | bin/build-pkg logs (2 files) |'
has '| <runner home>/actions-runner/_work | runner work dir (new path) |'
has '| ~/.local/share/omarchy-asus/mystery-dir | data dir entry |' "a stray data-dir entry"
has 'named by no tracked script: stray test or build output? |' "  ... named by no script"
hasre "^\\| /etc/systemd/system/old-build\\.service \\| systemd unit \\| $SZ \\| calls the old path \\|$" "the unit, sized"
has '| /etc/systemd/system/old-build.timer | systemd timer |' "the timer named after the unit"
has '| /etc/systemd/system/weekly-build.timer | systemd timer |' "a timer with Unit="
has '| starts old-build.service |'
hasnt 'unrelated.service'
hasnt 'unrelated.timer'
has '| ~/.config/systemd/user/user-build.service | systemd unit |' "a user unit"
hasnt 'user-build.timer' "a same-name timer whose Unit= starts another unit"
hasnt 'cross.timer' "a user timer naming a system unit"
has '| /etc/systemd/user/all-users.timer | systemd timer |' "a timer for every user, starting a user's unit"
hasre "^\\| /var/spool/cron/<a crontab> \\| sudoers/cron entry \\| $SZ \\|" "the crontab, sized"
if ((EUID)); then has '| /etc/sudoers.d | sudoers/cron | needs root | not read |'; fi
has '| devtools 1:1.5.3-1 | package | 462.79 KiB | required by: None; repo users besides the old path: bin/revdep-check |'
if ((keys)); then
    has '| authorized_keys line |  | present, line 2 |' "the release key's line on the helper"
    has '| authorized_keys line |  | stays; present, line 3 |' "the runner key's line on the helper"
    grep -qx 'BatchMode=yes.*helperbox cat .ssh/authorized_keys\|-o BatchMode=yes -o ConnectTimeout=10 -- helperbox cat .ssh/authorized_keys' "$S/ssh.log" &&
        ok "ssh only reads authorized_keys" || bad "ssh ran: $(cat "$S/ssh.log")"
    hasre "^\\| ~/\\.local/share/omarchy-asus/distcc \\| distcc key \\(release, old path\\) \\| $SZ \\| key SHA256:" "the release key dir, sized"
    hasre "^\\| <runner home>/distcc \\| distcc key \\(runner, new path\\) \\| $SZ \\| key SHA256:" "the runner key dir, sized"
fi
has '| bin/build-pkg | file (3 lines) |'
has '| bin/recipe-sandbox | file (2 lines) |' "recipe-sandbox listed"
has 'bin/rebase-recipe |' "recipe-sandbox's other user named"
has '| docs/distcc.md: Setup | doc section (lines 7-14, the chroot on 2 lines) |'
has '| docs/distcc.md: Persistent ccache | doc section (lines 15-17, the chroot on 1 line) |'
hasnt 'docs/distcc.md: Requirements' "a section without the chroot is left out"
hasnt 'docs/distcc.md: not a heading' "a code-block comment is no heading"
has '| DISTCC_KEY_DIR | variable |  | bin/build-pkg |'
has '| CCACHE_HOST_DIR | variable |  | bin/build-pkg, build/no-ccache.conf |'
hasre "^\\| tests/ci/build-pkg-args\\.sh \\| test \\(old path only\\) \\| $SZ \\|" "an old-path test, sized"
hasre "^\\| tests/ci/mixed\\.sh \\| test \\(both paths\\) \\| $SZ \\|" "a mixed test, sized"
hasnt 'tests/ci/unrelated.sh'
for n in 163 201 237; do has "| #$n | issue the old path names |  | state not looked up |"; done
hasnt '| #258 |' "#258 itself is not listed"
[[ ! -e $S/gh.log ]] && ok "--offline asks GitHub nothing" || bad "gh called: $(cat "$S/gh.log")"
has '| <runner home>/ccache | ccache (runner, new path) |' "the runner's ccache"
has 'ci/build-recipe sets 15G' "the runner's ccache limit"

echo "== 2. safe to post"
for w in "$H" "$U" runnerz helperbox "$S" laptop someone; do hasnt "$w" "output does not contain '${w/#$S/<temp dir>}'"; done
mkdir "$D/$U-notes"
out=$(run --offline 2>"$S/err"); rc=$?
[[ $rc == 1 && -z $out ]] && ok "a denylisted name: nothing printed, exit 1" || bad "a denylisted name: exit $rc, output ${#out} bytes"
grep -q 'failed the PII scan' "$S/err" && ok "says why" || bad "no reason given: $(cat "$S/err")"
grep -qi "$U" "$S/err" && bad "the refusal prints the word" || ok "the refusal does not print the word"
out=$(run --offline --local 2>/dev/null); rc=$?
[[ $rc == 0 ]] && grep -qF "$U-notes" <<<"$out" && ok "--local prints it anyway" || bad "--local: exit $rc"
rmdir "$D/$U-notes"
mkdir "$D/$U-notes"
out=$(run PII_SCAN=off --offline 2>/dev/null); rc=$?
[[ $rc == 1 && -z $out ]] && ok "an inherited PII_SCAN=off does not skip the scan" || bad "PII_SCAN=off: exit $rc, output ${#out} bytes"
rmdir "$D/$U-notes"
out=$(run --bogus 2>/dev/null); rc=$?
[[ $rc == 2 ]] && ok "unknown argument: exit 2" || bad "unknown argument: exit $rc"

echo "== 3. read-only"
[[ $after == "$before" ]] && ok "the fake trees are unchanged" || { bad "the fake trees changed"; diff <(echo "$before") <(echo "$after") | head; }
# no command that writes, moves, deletes, stops or uninstalls, anywhere in the script
pat='(^|[^[:alnum:]_.-])(rm|mv|rmdir|unlink|shred|truncate|dd|tee|cp|ln|mkdir|chmod|chown|install|systemctl|kill|pkill|userdel)([^[:alnum:]_-]|$)|pacman +-[A-Z]*[RSUD]|sed +-i|>>|> *"?/(etc|var|home|usr|tmp)|> *"\$'
if hits=$(grep -nE -- "$pat" "$W/bin/old-path-inventory"); then bad "destructive command or write in the script:"; echo "$hits"; else ok "no destructive command or write in the script"; fi
for w in "pacman -R" "systemctl stop" "systemctl disable" "rm -rf"; do
    grep -qF -- "$w" "$W/bin/old-path-inventory" && bad "contains '$w'" || ok "no '$w'"
done

echo "== 4. what cannot be read says so"
if ((EUID)); then
    chmod 000 "$C/root/etc" "$C/root/var/lib/pacman"
    # the logs behind an unsearchable data dir (the work-* rows say needs root there too)
    mkdir -p "$S/lockeddata/logs"; : >"$S/lockeddata/logs/foo-20261001-120000.log"; chmod 000 "$S/lockeddata"
    mkdir -p "$S/locked/cc" "$SYS/etc/cron.d"; chmod 000 "$S/locked"
    printf 'secret\n' >"$SYS/etc/cron.d/private"; chmod 000 "$SYS/etc/cron.d/private"
    out=$(run CCACHE_HOST_DIR="$S/locked/cc" --offline --local 2>/dev/null)
    has '| ~/.local/share/omarchy-asus/logs/<recipe>-<date>.log* | bin/build-pkg logs (2 files) |' "logs still listed beside the locked dirs"
    out2=$out
    out=$(run OMARCHY_ASUS_DATA="$S/lockeddata" --offline --local 2>/dev/null)
    has '/lockeddata/logs/<recipe>-<date>.log* | bin/build-pkg logs | needs root | not read |' "logs behind an unsearchable data dir"
    has '/lockeddata/work-*, verify-gnupg | bin/build-pkg scratch | needs root |' "scratch behind an unsearchable data dir"
    out=$out2
    has '/root/etc/makepkg.conf.d | chroot makepkg config | needs root | not read |' "the chroot config behind an unreadable dir"
    has '/root/var/lib/pacman/local | chroot package db | needs root | not read |' "the chroot package db behind an unreadable dir"
    has '/locked/cc | release ccache | needs root |' "a path behind an unsearchable dir is not 'absent'"
    has '| /etc/cron.d | sudoers/cron | needs root | some files could not be read |' "an unreadable file in a readable dir"
    chmod 755 "$C/root/etc" "$C/root/var/lib/pacman" "$S/locked" "$S/lockeddata"
else
    echo "skip: running as root, everything is readable"
fi

exit $fail
