# On a hybrid laptop whose iGPU drives the display, video players and browsers
# that let libva or Chromium choose a render node can decode on the NVIDIA GPU
# instead: render nodes are numbered in PCI order, which puts the dGPU first on
# some machines, and the numbers can change between boots. Each video then
# wakes the runtime-suspended dGPU for work the iGPU's video engine does at a
# fraction of the power. Pin mpv and Chromium-family browsers to the iGPU by
# the stable path omarchy-hw-igpu-render-node prints. Every other machine is
# left alone, and so is any setting the user already has.

HYBRID_VIDEO_CHROMIUM_FLAGS_FILES=(
  "$HOME/.config/chromium-flags.conf"
  "$HOME/.config/chrome-flags.conf"
  "$HOME/.config/microsoft-edge-stable-flags.conf"
  "$HOME/.config/brave-flags.conf"
  "$HOME/.config/brave-origin-flags.conf"
)

HYBRID_VIDEO_MPV_CONF="$HOME/.config/mpv/mpv.conf"

# Appends --render-node-override to the flags files given, or to every
# Chromium-family flags file Omarchy seeds. Only files the user already has.
hybrid_video_pin_chromium() {
  local node conf
  local -a confs=("$@")

  (( ${#confs[@]} )) || confs=("${HYBRID_VIDEO_CHROMIUM_FLAGS_FILES[@]}")

  node=$(omarchy-hw-igpu-render-node) || return 0

  for conf in "${confs[@]}"; do
    [[ -f $conf ]] || continue
    grep -q -- '^[[:space:]]*--render-node-override=' "$conf" && continue
    [[ -s $conf && -n $(tail -c1 "$conf") ]] && echo >>"$conf"
    echo "--render-node-override=$node" >>"$conf"
  done
}

# Whether mpv.conf sets an option outside any [profile] section.
hybrid_video_mpv_sets() {
  [[ -f $HYBRID_VIDEO_MPV_CONF ]] &&
    awk -v option="$1" '
      /^[[:space:]]*\[/ { exit }
      $0 ~ "^[[:space:]]*(--)?" option "[[:space:]]*=" { found = 1; exit }
      END { exit !found }
    ' "$HYBRID_VIDEO_MPV_CONF"
}

# Decodes through VA-API on the iGPU. hwdec=auto-safe from /etc/mpv/mpv.conf
# can settle on NVDEC, which loads CUDA and wakes the dGPU. The options go at
# the top of ~/.config/mpv/mpv.conf, ahead of any [profile] section, and only
# those the user has not set.
hybrid_video_pin_mpv() {
  local node existing=""
  local -a options=()

  node=$(omarchy-hw-igpu-render-node) || return 0

  hybrid_video_mpv_sets hwdec || options+=("hwdec=vaapi")
  hybrid_video_mpv_sets vaapi-device || options+=("vaapi-device=$node")
  (( ${#options[@]} )) || return 0

  mkdir -p "$(dirname "$HYBRID_VIDEO_MPV_CONF")"
  if [[ -f $HYBRID_VIDEO_MPV_CONF ]]; then
    existing=$(<"$HYBRID_VIDEO_MPV_CONF")
  fi

  # Rewrite in place, which keeps a symlinked config pointing where it did.
  local comment="# Decode video on the integrated GPU that drives the display, so the NVIDIA GPU can stay asleep."
  {
    [[ $existing == *"$comment"* ]] || echo "$comment"
    printf '%s\n' "${options[@]}"
    if [[ -n $existing ]]; then
      printf '\n%s\n' "$existing"
    fi
  } >"$HYBRID_VIDEO_MPV_CONF"
}

# Whether a pinned /dev/dri/by-path/pci-<address>-render node still belongs to
# a display device that is not the NVIDIA GPU. A MUX switch to the dGPU, an
# iGPU turned off in firmware or a BIOS update that moves the PCI address
# leaves a pin pointing at nothing, and decode silently falls back to software.
# Reads only cached sysfs IDs, never the device.
hybrid_video_node_valid() {
  local name=${1##*/} vendor="" class="" dev
  [[ $name == pci-*-render ]] || return 0
  name=${name#pci-}
  dev="${OMARCHY_PCI_DEVICES_PATH:-/sys/bus/pci/devices}/${name%-render}"
  read -r vendor 2>/dev/null <"$dev/vendor" || return 1
  read -r class 2>/dev/null <"$dev/class" || return 1
  [[ $vendor != "0x10de" && $class == 0x03* ]]
}

# Drops render node pins (by-path only) that no longer name the iGPU, from the
# Chromium-family flags files and from the top of mpv.conf. Pins the user set to
# any other path are left alone.
hybrid_video_unpin_stale() {
  local conf line node changed out
  for conf in "${HYBRID_VIDEO_CHROMIUM_FLAGS_FILES[@]}" "$HYBRID_VIDEO_MPV_CONF"; do
    [[ -f $conf ]] || continue
    changed=0 out=""
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^[[:space:]]*(--render-node-override=|(--)?vaapi-device[[:space:]]*=[[:space:]]*)([^[:space:]]*/by-path/pci-[^[:space:]]+-render) ]]; then
        node=${BASH_REMATCH[3]}
        if ! hybrid_video_node_valid "$node"; then
          changed=1
          continue
        fi
      fi
      out+="$line"$'\n'
    done <"$conf"
    # Rewrite in place, which keeps a symlinked config pointing where it did.
    (( changed )) && printf '%s' "$out" >"$conf"
  done
  return 0
}

# Drops stale pins, then pins again where an iGPU is found.
hybrid_video_refresh() {
  hybrid_video_unpin_stale
  hybrid_video_pin_mpv
  hybrid_video_pin_chromium
}
