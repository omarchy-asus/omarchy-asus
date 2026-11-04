#!/bin/bash
# Offline check for linux-omarchy's 9911 (default-off raw four-channel internal mic
# capture PCM on the G16's ALC285, #403):
#   1. recipe: 9911 is in source=() right after 9910, with a b2sum and a sha256sum
#      that match the file; DELTA re-applies it at the end; pkgrel is in the RC
#      channel's range; docs/deltas.md and NOTES.md describe it;
#   2. shape (the patch's added lines): it only touches the ALC269-family realtek
#      codec driver (and at most the generic HDA parser); the ga605k_raw_mic
#      parameter is read-only and off by default; it is scoped to codec 10ec0285
#      with subsystem 1043:1314; the raw PCM is four channels, set up on ADC 0x07 at
#      channel offset 0 and ADC 0x09 at offset 2 and cleaned up on both, advertising
#      what both converters support; it refuses a conflicting open with -EBUSY; it
#      writes no vendor coefficients; the existing GA605K fixups and quirk line are
#      unchanged; channels are not named by position;
#   3. build (the build host only): on the exact recipe tree (linux-<pkgver> plus
#      every source=() patch before 9911, at fuzz 0, with config.x86_64), the realtek
#      and generic objects compile with W=1 and have no ga605k_raw_mic parameter
#      (RED baseline); with 9911 applied at fuzz 0 they compile with no new warning
#      and carry the parameter (GREEN); checkpatch reports no ERROR. Elsewhere (CI's
#      hosted runner, which has no kernel tarball) step 3 says SKIP; the package build
#      compiles the whole kernel.
# What this cannot check: one DMA stream filling offsets 0/2, the extra channels being
# independent of the stereo pair, and stereo capture, the headset mic and the speakers
# unchanged with the parameter off are hardware behaviour, verified only by the G16
# test card (#404).
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/linux-omarchy
N=9911-EXPERIMENTAL-alsa-hda-realtek-ga605k-raw-mic-capture-default-off.patch
P=$R/$N
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# ------------------------------------------------------------ 1. recipe
[[ -f $P ]] || { echo "FAIL $P missing"; exit 1; }
src=$(bash -c 'source "$1"; printf "%s\n" "${source[@]}"' _ "$R/PKGBUILD")
b2=$(bash -c 'source "$1"; printf "%s\n" "${b2sums[@]}"' _ "$R/PKGBUILD")
sha=$(bash -c 'source "$1"; printf "%s\n" "${sha256sums[@]}"' _ "$R/PKGBUILD")
pkgver=$(bash -c 'source "$1"; echo "$pkgver"' _ "$R/PKGBUILD")
pkgrel=$(bash -c 'source "$1"; echo "$pkgrel"' _ "$R/PKGBUILD")
i=$(grep -n -x "$N" <<<"$src" | cut -d: -f1)
if [[ -n $i ]]; then
  prev=$(sed -n "$((i - 1))p" <<<"$src")
  [[ $prev == 9910-* ]] && ok "9911 follows 9910 in source=()" || bad "9911 position: after '$prev'"
  [[ $(sed -n "${i}p" <<<"$b2") == "$(b2sum "$P" | cut -d' ' -f1)" ]] && ok "b2sum matches" || bad "b2sum mismatch"
  [[ $(sed -n "${i}p" <<<"$sha") == "$(sha256sum "$P" | cut -d' ' -f1)" ]] && ok "sha256sum matches" || bad "sha256sum mismatch"
else
  bad "9911 is not in source=()"
fi
grep -q "^patch $N end" "$R/DELTA" && ok "DELTA re-applies 9911 at the end" || bad "DELTA has no 9911 line"
if out=$("$W/ci/check-pkgrel" rc "$pkgrel"); then ok "pkgrel $pkgrel is in the RC range"; else bad "pkgrel: $out"; fi
grep -q 'kernel-9911-ga605k-raw-mic' "$W/docs/deltas.md" && ok "docs/deltas.md has kernel-9911-ga605k-raw-mic" ||
  bad "docs/deltas.md has no kernel-9911-ga605k-raw-mic entry"
grep -q 'EXPERIMENTAL: 9911' "$R/NOTES.md" && ok "NOTES.md has an EXPERIMENTAL: 9911 section" ||
  bad "NOTES.md has no EXPERIMENTAL: 9911 section"

# ------------------------------------------------------------ 2. shape
added=$(grep '^+' "$P" | grep -v '^+++ ')
removed=$(grep '^-' "$P" | grep -v '^--- ')
# The added code as one line, so a call wrapped over several lines still matches.
flat=$(sed 's/^+//' <<<"$added" | tr -s '[:space:]' ' ')

files=$(sed -n -E 's#^(\+\+\+ b|--- a)/##p' "$P" | sort -u)
grep -qx 'sound/hda/codecs/realtek/alc269.c' <<<"$files" && ok "touches sound/hda/codecs/realtek/alc269.c" ||
  bad "does not touch sound/hda/codecs/realtek/alc269.c"
others=$(grep -vxE 'sound/hda/codecs/realtek/alc269\.c|sound/hda/codecs/generic\.[ch]' <<<"$files")
[[ -z $others ]] && ok "touches nothing beyond alc269.c and generic.[ch]" || bad "touches other files: $(tr '\n' ' ' <<<"$others")"

grep -q '^+module_param(ga605k_raw_mic, bool, 0444);' "$P" && ok "ga605k_raw_mic is a read-only bool parameter" ||
  bad "no module_param(ga605k_raw_mic, bool, 0444)"
# Code lines only: the doc comment names the opt-in as "ga605k_raw_mic=1".
code=$(grep -vE '^\+[[:space:]]*(/\*|\*|//)' <<<"$added")
if grep -q '^+static bool ga605k_raw_mic;' "$P" && ! grep -qE '^\+.*ga605k_raw_mic[[:space:]]*=[[:space:]]*(true|1)\b' <<<"$code"; then
  ok "ga605k_raw_mic defaults off"
else
  bad "ga605k_raw_mic is not 'static bool ga605k_raw_mic;' off by default"
fi
grep -qi '0x10ec0285' <<<"$added" && grep -qi '0x10431314' <<<"$added" &&
  ok "scoped to codec 0x10ec0285, subsystem 0x10431314" || bad "scope check lacks 0x10ec0285 or 0x10431314"

# The numeric value of an argument: a literal, or a constant this patch defines.
val() {
  local t=${1//[[:space:]]/} v
  if [[ $t =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then printf '%d\n' "$t"; return; fi
  [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return
  v=$(grep -oE "#define[[:space:]]+${t}[[:space:]]+\(?(0[xX][0-9a-fA-F]+|[0-9]+)" <<<"$added" | grep -oE '(0[xX][0-9a-fA-F]+|[0-9]+)$' | head -1)
  [[ -n $v ]] || v=$(grep -oE "(^|[^A-Za-z0-9_])${t}[[:space:]]*=[[:space:]]*(0[xX][0-9a-fA-F]+|[0-9]+)" <<<"$added" |
    grep -oE '(0[xX][0-9a-fA-F]+|[0-9]+)$' | head -1)
  [[ -n $v ]] && printf '%d\n' "$v"
}

# snd_hda_codec_setup_stream(codec, nid, stream_tag, channel_id, format)
pairs=' '
while IFS= read -r call; do
  args=${call#*(}
  IFS=, read -r _ nid _ ch _ <<<"$args"
  pairs+="$(val "$nid"):$(val "$ch") "
done < <(grep -oE 'snd_hda_codec_setup_stream\([^,]+,[^,]+,[^,]+,[^,]+,[^)]+\)' <<<"$flat")
[[ $pairs == *' 7:0 '* ]] && ok "ADC 0x07 is set up at channel offset 0" || bad "no setup of ADC 0x07 at offset 0 (found:$pairs)"
[[ $pairs == *' 9:2 '* ]] && ok "ADC 0x09 is set up at channel offset 2" || bad "no setup of ADC 0x09 at offset 2 (found:$pairs)"

# snd_hda_query_supported_pcm(codec, nid, ...) and snd_hda_codec_cleanup_stream(codec, nid)
nids_of() {
  local call args nid out=' '
  while IFS= read -r call; do
    args=${call#*(}
    IFS=, read -r _ nid _ <<<"${args%)}"
    out+="$(val "$nid") "
  done < <(grep -oE "$1" <<<"$flat")
  echo "$out"
}
q=$(nids_of 'snd_hda_query_supported_pcm\([^,]+,[^,)]+[,)]')
[[ $q == *' 7 '* && $q == *' 9 '* ]] && ok "rates/formats queried on both 0x07 and 0x09" ||
  bad "snd_hda_query_supported_pcm not called for both converters (found:$q)"
c=$(nids_of 'snd_hda_codec_cleanup_stream\([^,]+,[^,)]+\)')
[[ $c == *' 7 '* && $c == *' 9 '* ]] && ok "both 0x07 and 0x09 are cleaned up" ||
  bad "snd_hda_codec_cleanup_stream not called for both converters (found:$c)"

grep -q -- '-EBUSY' <<<"$added" && ok "a conflicting open returns -EBUSY" || bad "no -EBUSY added"
# channels_min/channels_max: a literal, or a constant this patch defines (val above).
rhs() { grep -oE "${1}[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+" <<<"$added" | sed -E 's/.*=[[:space:]]*//' | head -1; }
cmin=$(val "$(rhs channels_min)")
cmax=$(val "$(rhs channels_max)")
[[ $cmin == 4 && $cmax == 4 ]] && ok "raw PCM is 4 channels (min and max)" ||
  bad "channels_min/channels_max are not both 4 (found: ${cmin:-?}/${cmax:-?})"
coef=$(grep -E 'alc_write_coef|alc_update_coef|AC_VERB_SET_COEF_INDEX|AC_VERB_SET_PROC_COEF|alc_process_coef_fw' <<<"$added")
[[ -z $coef ]] && ok "no vendor coefficient writes added" || { bad "adds vendor coefficient writes:"; echo "$coef" | head -5; }
grep -qE '0x03a11050|0x03a11c30' <<<"$removed" && bad "removes a GA605K headset mic pin value" ||
  ok "GA605K headset mic pin values untouched"
grep -q 'GA605K' <<<"$removed" && bad "removes or edits a line naming a GA605K fixup" || ok "GA605K fixup lines untouched"
grep -qE '^[-+].*SND_PCI_QUIRK\(0x1043, *0x1314' "$P" && bad "edits the SND_PCI_QUIRK(0x1043, 0x1314, ...) line" ||
  ok "SND_PCI_QUIRK(0x1043, 0x1314, ...) unchanged"
# Comments and strings on the added lines: channels are raw/aux, never placed.
text=$({ grep -oE '"[^"]*"' <<<"$added"; grep -oE '(/\*|//).*' <<<"$added"; grep -E '^\+[[:space:]]*\*' <<<"$added"; })
pos=$(grep -iwE 'front|rear|left|right' <<<"$text")
[[ -z $pos ]] && ok "no front/rear/left/right channel naming" || { bad "positional naming in comments or strings:"; echo "$pos" | head -5; }

# ------------------------------------------------------------ 3. build
# Plain gcc on a plain PATH: a distcc masquerade on PATH would send this out.
export PATH=/usr/bin:/bin
tar=''
for d in "${SRCDEST:-}" "$HOME/.local/share/omarchy-asus/srcdest" "$R"; do
  [[ -n $d && -f $d/linux-$pkgver.tar.xz ]] && { tar=$d/linux-$pkgver.tar.xz; break; }
done
[[ -n $tar ]] || { echo "SKIP build: needs linux-$pkgver.tar.xz (the build host has it)"; exit "$fail"; }
missing=''
for t in gcc make flex bison bc perl nm patch; do command -v "$t" >/dev/null || missing+=" $t"; done
[[ -f /usr/include/libelf.h ]] || missing+=' libelf.h'
[[ -f /usr/include/openssl/opensslv.h ]] || missing+=' openssl headers'
[[ -z $missing ]] || { echo "SKIP build: missing$missing"; exit "$fail"; }
((fail)) && { echo "FAIL static checks failed; not building"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tar -xJf "$tar" -C "$T" || { bad "extract ${tar##*/}"; exit 1; }
cd "$T/linux-$pkgver" || exit 1

# The source=() patches in prepare()'s order, split around 9911.
before=() after=() seen=0
while IFS= read -r s; do
  s=${s%%::*}; s=${s##*/}; s=${s%.zst}
  [[ $s == *.patch ]] || continue
  if [[ $s == "$N" ]]; then seen=1
  elif ((seen)); then after+=("$s")
  else before+=("$s")
  fi
done <<<"$src"
for s in "${before[@]}"; do
  patch -Np1 --fuzz=0 --no-backup-if-mismatch -s <"$R/$s" >"$T/patch.log" 2>&1 ||
    { tail -20 "$T/patch.log"; bad "$s does not apply at fuzz 0"; exit 1; }
done
ok "${#before[@]} recipe patches before 9911 apply at fuzz 0"
cp "$R/config.x86_64" .config
make -s olddefconfig >"$T/config.log" 2>&1 || { tail -20 "$T/config.log"; bad "make olddefconfig"; exit 1; }

objs=(sound/hda/codecs/realtek/alc269.o sound/hda/codecs/generic.o)
build() {
  make -j"$(nproc)" CC=/usr/bin/gcc W=1 "${objs[@]}" >"$1" 2>&1 || { tail -20 "$1"; bad "$2: W=1 build failed"; exit 1; }
}
# Warnings without line numbers, so the patch moving code down doesn't count as new.
warns() { grep -E 'warning:' "$1" | sed -E 's/:[0-9]+:[0-9]+:/:/; s/:[0-9]+:/:/' | sort -u; }
param() { nm "${objs[0]}" | grep -q '__param_ga605k_raw_mic' || grep -aq 'parm=ga605k_raw_mic:' "${objs[0]}"; }

build "$T/before.log" "before 9911"
if param; then bad "before 9911: alc269.o already has a ga605k_raw_mic parameter"; else
  ok "before 9911: no ga605k_raw_mic parameter (RED baseline)"; fi

patch -Np1 --fuzz=0 --no-backup-if-mismatch -s <"$P" >"$T/patch.log" 2>&1 ||
  { tail -20 "$T/patch.log"; bad "9911 does not apply at fuzz 0"; exit 1; }
ok "9911 applies at fuzz 0"
build "$T/after.log" "with 9911"
new=$(comm -13 <(warns "$T/before.log") <(warns "$T/after.log"))
[[ -z $new ]] && ok "alc269.o and generic.o build with W=1 and no new warnings" ||
  { bad "new W=1 warnings with 9911:"; echo "$new" | head -20; }
param && ok "with 9911: alc269.o has the ga605k_raw_mic parameter" || bad "with 9911: no ga605k_raw_mic parameter in alc269.o"

# MISSING_SIGN_OFF: like every local 99xx carry, the patch is not submitted; a
# Signed-off-by is the submitter's to add when it goes upstream.
cp=$(scripts/checkpatch.pl --no-tree --strict --ignore FILE_PATH_CHANGES,GIT_COMMIT_ID,COMMIT_LOG_LONG_LINE,EMAIL_SUBJECT,MISSING_SIGN_OFF "$P" 2>&1)
grep -E '^(WARNING|CHECK):' <<<"$cp" | head -20
if grep -q '^ERROR:' <<<"$cp"; then
  bad "checkpatch errors:"; grep -A3 '^ERROR:' <<<"$cp" | head -20
else
  ok "checkpatch: no errors"
fi

for s in "${after[@]}"; do
  patch -Np1 --fuzz=0 --no-backup-if-mismatch -s <"$R/$s" >"$T/patch.log" 2>&1 ||
    { tail -20 "$T/patch.log"; bad "$s does not apply after 9911 at fuzz 0"; }
done
((${#after[@]})) && ok "${#after[@]} later recipe patches apply after 9911"
exit "$fail"
