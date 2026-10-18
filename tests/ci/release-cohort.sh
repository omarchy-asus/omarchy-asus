#!/bin/bash
# bin/release-cohort keeps a release cohort (build/cohorts.conf) together: patched
# omarchy is never published without the patched omarchy-settings of the same
# pkgver-pkgrel (#83), and the recipes pin each other to the release. Offline: empty package
# files and a hand-made repo db; needs bash, python3 and GNU tar only.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
RC="$W/bin/release-cohort"
printf '# test cohorts\nomarchy omarchy-settings\n' >"$T/cohorts.conf"
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
status() {  # status <release-cohort args...>: the exit code
    "$RC" --cohorts "$T/cohorts.conf" "$@" >/dev/null 2>&1
    echo $?
}
members() {  # members <args...>: the printed names on one line
    "$RC" --cohorts "$T/cohorts.conf" members "$@" 2>/dev/null | paste -sd' '
}
mkdb() {  # mkdb <db file> <name-pkgver-pkgrel>...
    local db=$1 d e
    shift
    d=$(mktemp -d "$T/db.XXXXXX")
    for e in "$@"; do
        mkdir -p "$d/$e"
        : >"$d/$e/desc"
    done
    tar -czf "$db" -C "$d" "$@"
}
pkg() {  # pkg <file name>: an empty package file, printed with its path
    : >"$T/pkgs/$1"
    echo "$T/pkgs/$1"
}
mkws() {  # mkws <name>: a workspace with copies of the cohort's PKGBUILDs
    local ws=$T/$1 r
    for r in omarchy omarchy-settings; do
        mkdir -p "$ws/recipes/$r"
        cp "$W/recipes/$r/PKGBUILD" "$ws/recipes/$r/PKGBUILD"
    done
    echo "$ws"
}
mkdir -p "$T/pkgs"

expect "members omarchy: omarchy, then omarchy-settings" "$(members omarchy)" "omarchy omarchy-settings"
expect "members hyprland: hyprland only" "$(members hyprland)" "hyprland"
mkdb "$T/no-settings.db.tar.gz" omarchy-4.0.5-1.2 hyprland-0.50-1.1
expect "members --db without omarchy-settings: omarchy only" \
    "$(members --db "$T/no-settings.db.tar.gz" omarchy)" "omarchy"
# bin/unpublish: a member a partner's withdrawal already took out is skipped
expect "members --db --present, both asked, settings gone: omarchy only" \
    "$(members --db "$T/no-settings.db.tar.gz" --present omarchy-settings omarchy)" "omarchy"
expect "members --db --present, settings gone: its partner omarchy still goes" \
    "$(members --db "$T/no-settings.db.tar.gz" --present omarchy-settings)" "omarchy"
mkdb "$T/no-cohort.db.tar.gz" hyprland-0.50-1.1
expect "members --db --present, the whole cohort gone: nothing" \
    "$(members --db "$T/no-cohort.db.tar.gz" --present omarchy omarchy-settings)" ""
expect "members --present without --db: usage error" "$(status members --present omarchy)" 64

om=$(pkg omarchy-4.0.5-1.2-x86_64.pkg.tar.zst)
st=$(pkg omarchy-settings-4.0.5-1.2-x86_64.pkg.tar.zst)
st_old=$(pkg omarchy-settings-4.0.5-1.1-x86_64.pkg.tar.zst)
hy=$(pkg hyprland-0.50-1.1-x86_64.pkg.tar.zst)
mkdb "$T/settings.db.tar.gz" omarchy-settings-4.0.5-1.2
mkdb "$T/stock-settings.db.tar.gz" omarchy-settings-4.0.5-1
expect "check-publish omarchy alone, no db: refused" "$(status check-publish "$om")" 1
expect "check-publish omarchy with omarchy-settings: ok" "$(status check-publish "$om" "$st")" 0
expect "check-publish omarchy with an older omarchy-settings: refused" "$(status check-publish "$om" "$st_old")" 1
expect "check-publish omarchy alone, settings of the same version in the db: ok" \
    "$(status check-publish --db "$T/settings.db.tar.gz" "$om")" 0
expect "check-publish omarchy alone, stock settings of the same pkgver in the db: refused" \
    "$(status check-publish --db "$T/stock-settings.db.tar.gz" "$om")" 1
expect "check-publish hyprland alone: ok" "$(status check-publish "$hy")" 0

expect "check-recipes on the real recipes: ok" \
    "$("$RC" --workspace "$W" check-recipes >/dev/null 2>&1; echo $?)" 0
ws=$(mkws ws-same)
expect "check-recipes on unedited copies: ok" "$(status --workspace "$ws" check-recipes)" 0
ws=$(mkws ws-pkgrel)
sed -i 's/^pkgrel=.*/pkgrel=1.9/' "$ws/recipes/omarchy-settings/PKGBUILD"
# auto-update rebases each member in its own PR, so one may lag the other on main
expect "check-recipes, omarchy-settings at another pkgrel: a warning" "$(status --workspace "$ws" check-recipes)" 0
expect "check-recipes --strict, omarchy-settings at another pkgrel: refused" \
    "$(status --workspace "$ws" check-recipes --strict)" 1
ws=$(mkws ws-pin)
# The PKGBUILD's own ${pkgver}, not ours:
# shellcheck disable=SC2016
sed -i 's/"omarchy-settings=${pkgver}-${pkgrel}"/"omarchy-settings=${pkgver}"/' "$ws/recipes/omarchy/PKGBUILD"
expect "check-recipes, omarchy pins omarchy-settings to pkgver only: refused" \
    "$(status --workspace "$ws" check-recipes)" 1
ws=$(mkws ws-build-pin)
# The exact pin as a build dependency: the clean chroot and CI only have stock omarchy-settings.
# shellcheck disable=SC2016
sed -i 's/^  "omarchy-settings=${pkgver}"$/  "omarchy-settings=${pkgver}-${pkgrel}"/' "$ws/recipes/omarchy/PKGBUILD"
expect "check-recipes, the exact pin in the global depends: refused" \
    "$(status --workspace "$ws" check-recipes)" 1
exit $fails
