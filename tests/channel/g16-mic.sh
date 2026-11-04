#!/bin/bash
# omarchy-asus-g16-mic (#401, #400), offline: static checks of the recipe (HOLD, LOCAL_ONLY,
# every source listed with its real sha256, the RC pkgrel, both echo-cancel fragments' keys and
# distinct node names, nothing installed under /etc, pipewire.conf.d or systemd), then, where the
# toolchain and the PipeWire, FFTW and WebRTC dev files are present, the meson build, its tests
# (synthetic signals, and test_pw_live against a private PipeWire, which must not skip where the
# pipewire and wireplumber binaries are present) and the exact list of installed files. Where they
# are missing the build is skipped: the PR's Build check runs the same tests in the PKGBUILD's
# check() in the clean chroot.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/omarchy-asus-g16-mic
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- HOLD and LOCAL_ONLY ---------------------------------------------------------------------
hold1=$(head -n 1 "$R/HOLD" 2>/dev/null)
if [[ -n $hold1 && $hold1 == *"#400"* ]]; then ok "HOLD names its reason (#400)"; else fail "HOLD: first line empty or without #400"; fi
if [[ -f $R/LOCAL_ONLY ]]; then ok "LOCAL_ONLY present"; else fail "LOCAL_ONLY missing"; fi

# --- sources and checksums -------------------------------------------------------------------
pkgvar() { (cd "$R" && bash -c 'source ./PKGBUILD >/dev/null 2>&1 || exit 1; eval "printf \"%s\n\" \"\${$1[@]}\""' _ "$1"); }
mapfile -t srcs < <(pkgvar source)
mapfile -t sums < <(pkgvar sha256sums)
pkgrel=$(pkgvar pkgrel)
((${#srcs[@]} > 0)) || fail "PKGBUILD: no source=() entries (does it source?)"
for f in "${srcs[@]}"; do
  [[ -f $R/$f ]] || fail "source $f is not in the recipe"
done
while IFS= read -r f; do
  case $f in PKGBUILD | HOLD | LOCAL_ONLY) continue ;; esac
  listed=0
  for s in "${srcs[@]}"; do [[ $s == "$f" ]] && listed=1 && break; done
  ((listed)) || fail "$f is in the recipe but not in source=()"
done < <(cd "$R" && find . -maxdepth 1 -type f -printf '%P\n' | sort)
if ((${#sums[@]} != ${#srcs[@]})); then
  fail "sha256sums has ${#sums[@]} entries for ${#srcs[@]} sources"
else
  bad=0
  for i in "${!srcs[@]}"; do
    f=${srcs[i]} want=${sums[i]}
    if [[ $want == SKIP ]]; then fail "sha256sums: SKIP for $f"; bad=1; continue; fi
    if [[ $want =~ ^0+$ ]]; then fail "sha256sums: placeholder for $f (run updpkgsums)"; bad=1; continue; fi
    [[ -f $R/$f ]] || { bad=1; continue; }
    got=$(sha256sum "$R/$f" | cut -d' ' -f1)
    [[ $got == "$want" ]] || { fail "sha256sums: $f is $got, PKGBUILD says $want"; bad=1; }
  done
  ((bad)) || ok "every source is listed with its sha256"
fi
if out=$("$W/ci/check-pkgrel" rc "$pkgrel" 2>&1); then ok "pkgrel $pkgrel is in the RC range"; else fail "pkgrel: $out"; fi

# --- the echo-cancel fragments ---------------------------------------------------------------
# g16-mic-aec.conf, the default: echo cancellation only (noise suppression and gain control off).
# g16-mic-aec-ns-high.conf, opt-in: the same plus noise suppression at PipeWire's high level.
C=$R/g16-mic-aec.conf
CNS=$R/g16-mic-aec-ns-high.conf
frag_has() { # FILE WANT...
  local f=$1 n want
  n=$(basename "$f")
  shift
  if [[ ! -f $f ]]; then fail "$n is missing"; return; fi
  for want in "$@"; do
    if grep -qF -- "$want" "$f"; then ok "$n: $want"; else fail "$n lacks: $want"; fi
  done
}
frag_has "$C" 'libpipewire-module-echo-cancel' 'aec/libspa-aec-webrtc' 'webrtc.noise_suppression = false' \
  'webrtc.gain_control = false' 'monitor.mode = true' 'target.object = "g16_mic_processed"' \
  'node.name = "g16_mic_clean"'
frag_has "$CNS" 'libpipewire-module-echo-cancel' 'aec/libspa-aec-webrtc' 'webrtc.noise_suppression = true' \
  'webrtc.gain_control = false' 'monitor.mode = true' 'target.object = "g16_mic_processed"' \
  'node.name = "g16_mic_clean_ns"'
node_names() { sed -n 's/^[[:space:]]*node\.name[[:space:]]*=[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}.*/\1/p' "$1" | sort -u; }
if [[ -f $C && -f $CNS ]]; then
  shared=$(comm -12 <(node_names "$C") <(node_names "$CNS") | paste -sd' ')
  if [[ -z $shared ]]; then ok "the two fragments share no node.name"; else fail "the two fragments share node.name: $shared"; fi
fi
if command -v spa-json-dump >/dev/null 2>&1; then
  for f in "$C" "$CNS"; do
    [[ -f $f ]] || continue
    if spa-json-dump "$f" >"$T/json" 2>&1; then ok "$(basename "$f") parses (spa-json-dump)"; else
      fail "$(basename "$f") does not parse:"; tail -n 20 "$T/json"
    fi
  done
else
  echo "skip: spa-json-dump not here, the fragments' syntax is not parsed"
fi

# --- nothing installed into active config or units -------------------------------------------
if sed 's/#.*//' "$R/meson.build" | grep -nE 'sysconfdir|/etc|pipewire\.conf\.d|systemd'; then
  fail "meson.build installs under /etc, pipewire.conf.d or systemd (lines above)"
else
  ok "meson.build installs nothing under /etc, pipewire.conf.d or systemd"
fi

# --- the build, its tests and the installed files --------------------------------------------
have_build=1
for t in meson ninja pkg-config; do command -v "$t" >/dev/null 2>&1 || have_build=0; done
{ command -v cc || command -v gcc; } >/dev/null 2>&1 || have_build=0
{ command -v c++ || command -v g++; } >/dev/null 2>&1 || have_build=0
if ((have_build)); then
  pkg-config --exists libpipewire-0.3 fftw3f webrtc-audio-processing-1 2>/dev/null || have_build=0
fi
if ((have_build)); then
  if ! meson setup "$T/build" "$R" --prefix=/usr -Daec_tests=enabled >"$T/log" 2>&1; then
    fail "meson setup:"; tail -n 40 "$T/log"
  elif ! meson test -C "$T/build" --print-errorlogs >"$T/test.log" 2>&1; then
    fail "meson test:"; tail -n 80 "$T/test.log"
  else
    ok "meson test"; grep -E '^(Ok|Fail|Expected Fail|Unexpected Pass|Skipped|Timeout):' "$T/test.log"
    # The live PipeWire test may skip only where its binaries are missing.
    if command -v pipewire >/dev/null 2>&1 && command -v wireplumber >/dev/null 2>&1; then
      live=$(grep -E '^ *[0-9]+/[0-9]+ +([^ ]+:)?test_pw_live +' "$T/test.log" | tail -n 1)
      if [[ $live =~ [[:space:]]OK[[:space:]] ]]; then
        ok "test_pw_live ran and passed (pipewire and wireplumber are here)"
      else
        # A load skip prints SKIP-LOAD; meson keeps every test's stdout in its own log.
        skipload=$(grep -h -m1 '^SKIP-LOAD ' "$T/build/meson-logs/testlog.txt" "$T/test.log" 2>/dev/null | head -n 1)
        if [[ -n $skipload ]]; then
          fail "test_pw_live skipped: SKIP-LOAD (the host is already loaded by other work: $skipload); a skip does not pass: rerun on a quieter host or with G16MIC_LIVE_STRICT=1 to wait for the load to drop"
        else
          fail "test_pw_live did not pass on a host with pipewire and wireplumber: ${live:-no result line}"
        fi
      fi
    else
      echo "skip: no pipewire/wireplumber here, test_pw_live skipped"
    fi
    if ! meson install -C "$T/build" --destdir "$T/pkg" >"$T/install.log" 2>&1; then
      fail "meson install:"; tail -n 20 "$T/install.log"
    else
      got=$(cd "$T/pkg" && find . \( -type f -o -type l \) | LC_ALL=C sort | paste -sd' ')
      want="./usr/bin/g16-mic ./usr/share/omarchy-asus-g16-mic/calibration.example.conf ./usr/share/omarchy-asus-g16-mic/pipewire/g16-mic-aec-ns-high.conf ./usr/share/omarchy-asus-g16-mic/pipewire/g16-mic-aec.conf"
      if [[ $got == "$want" ]]; then ok "meson install files"; else fail "installed files: $got"; fi
    fi
  fi
else
  echo "skip: meson build and tests (toolchain or dev packages missing here; the PR build runs them in check())"
fi

((fails == 0)) && echo "==> g16-mic: all passed" || { echo "==> g16-mic: $fails failed"; exit 1; }
