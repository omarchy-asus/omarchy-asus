#!/bin/bash
# bin/omarchy-asus-setup --dry-run --uninstall, offline (#84): pacman and the other
# commands it checks for are stubs, HOME and the pacman config are temp files.
# The stub pacman has the repo builds and the optional G16 packages installed;
# linux-omarchy and nvidia-open-dkms also have a stock build in core/extra.
#   a. it exits 0
#   b. it warns about the stock driver's hibernate hang (#1412) before the -Syuu prompt
#   c. a leftover step lists the installed repo-only packages, and only those
#   d. it offers to remove them with pacman -Rns (printed under --dry-run)
#   e. it calls out omarchy-asus-g16 and its HibernateMode=shutdown
# Usage: tests/ci/setup-uninstall.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/home"
cat >"$S/bin/pacman" <<'STUB'
#!/bin/bash
repo=(linux-omarchy nvidia-open-dkms omarchy-asus-g16 omarchy-asus-g16-apply asus-rog-nkey-winlock
    asus-zephyrus-g16-control hyprpm omarchy-asus-keyring)
installed=(linux-omarchy nvidia-open-dkms omarchy-asus-g16 omarchy-asus-g16-apply asus-rog-nkey-winlock
    hyprpm omarchy-asus-keyring bash)
case ${1:-} in
    -Slq) printf '%s\n' "${repo[@]}" ;;
    -Sl)
        printf 'omarchy-asus %s 1-1.1\n' "${repo[@]}"
        printf '%s\n' 'core linux-omarchy 1-1' 'extra nvidia-open-dkms 1-1'
        ;;
    -Qq) printf '%s\n' "${installed[@]}" ;;
    -Qmq) ;;
    -Q)
        shift
        for p in "$@"; do
            [[ " ${installed[*]} " == *" $p "* ]] || exit 1
            printf '%s 1-1\n' "$p"
        done
        ;;
esac
exit 0
STUB
for c in pacman-key gpg curl bsdtar vercmp sudo; do
    printf '#!/bin/bash\nexit 0\n' >"$S/bin/$c"
done
chmod +x "$S"/bin/*
printf '[options]\nHoldPkg = pacman glibc\n\n[omarchy]\nInclude = /etc/pacman.d/omarchy\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n' >"$S/pacman.conf"
# shellcheck disable=SC2016 # $arch is pacman's, written out verbatim
printf '[omarchy-asus]\nSigLevel = Required\nServer = https://example.invalid/$arch\n' >"$S/custom-repos.conf"
export PATH=$S/bin:$PATH HOME=$S/home
export OMARCHY_ASUS_PACMAN_CONF=$S/pacman.conf OMARCHY_ASUS_CUSTOM_REPOS=$S/custom-repos.conf
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }

"$W/bin/omarchy-asus-setup" --dry-run --uninstall >"$S/out" 2>&1
rc=$?

echo "== a. exit status"
expect "$rc" 0 "exits 0"

echo "== b. hibernate warning before the -Syuu prompt"
grep -q '#1412' "$S/out"; expect $? 0 "mentions #1412"
grep -q 'hibernate' "$S/out"; expect $? 0 "mentions hibernate"
warn_line=$(grep -nF '#1412' "$S/out" | head -n1 | cut -d: -f1)
prompt_line=$(grep -nF "Run 'pacman -Syuu' now?" "$S/out" | head -n1 | cut -d: -f1)
expect "$([[ -n $warn_line && -n $prompt_line ]] && ((warn_line < prompt_line)) && echo before)" before \
    "#1412 warning (line ${warn_line:-none}) before the -Syuu prompt (line ${prompt_line:-none})"

echo "== c. leftover step"
sed -n '/==> Packages only the omarchy-asus repo had/,$p' "$S/out" >"$S/left"
if [[ -s $S/left ]]; then r=0; else r=1; fi; expect "$r" 0 "has a leftover step"
for p in omarchy-asus-g16 omarchy-asus-g16-apply asus-rog-nkey-winlock hyprpm; do
    grep -qxE " +$p" "$S/left"; expect $? 0 "lists $p"
done
for p in linux-omarchy nvidia-open-dkms bash asus-zephyrus-g16-control omarchy-asus-keyring; do
    grep -qxE " +$p" "$S/left"; expect $? 1 "does not list $p"
done

echo "== d. pacman -Rns offer"
rns=$(grep -F '[dry-run] sudo' "$S/out" | grep -F 'pacman -Rns' | head -n1)
[[ -n $rns ]]; r=$?; expect "$r" 0 "prints a [dry-run] sudo ... pacman -Rns line"
for p in omarchy-asus-g16 omarchy-asus-g16-apply asus-rog-nkey-winlock hyprpm; do
    [[ "$rns " == *" $p "* ]]; r=$?; expect "$r" 0 "-Rns names $p"
done
for p in linux-omarchy nvidia-open-dkms bash asus-zephyrus-g16-control; do
    [[ "$rns " == *" $p "* ]]; r=$?; expect "$r" 1 "-Rns leaves out $p"
done

echo "== e. omarchy-asus-g16 / HibernateMode=shutdown"
grep -F 'omarchy-asus-g16' "$S/left" | grep -qF 'HibernateMode=shutdown'
expect $? 0 "calls out omarchy-asus-g16 and HibernateMode=shutdown"

((fail)) && { echo "FAILED"; cat "$S/out"; exit 1; }
echo "all passed"
