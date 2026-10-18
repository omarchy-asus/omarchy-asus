-- omarchy-asus-g16-apply: hybrid-video. Loaded from ~/.config/hypr/hyprland.lua
-- (after Omarchy's defaults) by the line omarchy-asus-g16-apply adds there.
--
-- Stock Omarchy 4.0.5 sets LIBVA_DRIVER_NAME=nvidia when its display check says
-- NVIDIA drives the display. On the G16 GA605 the AMD Krackan iGPU is a non-VGA
-- display controller (class 0x0380) with no boot_vga, so the check answers
-- NVIDIA, and every VA-API video wakes the runtime-suspended RTX. The
-- omarchy-asus fork (branch asus/hybrid-video-decode) skips that line when
-- omarchy-hw-igpu-render-node finds the iGPU. This file can't edit Omarchy's
-- default/hypr/nvidia.lua, and Hyprland can't unset a variable from a later
-- config file, so it sets the iGPU's own VA-API driver instead, under the same
-- check. NVIDIA's GLX stays as it is, so OpenGL games keep the RTX.

local detector = "/usr/lib/omarchy-asus-g16-apply/bin/omarchy-hw-igpu-render-node"
local devices = os.getenv("OMARCHY_PCI_DEVICES_PATH") or "/sys/bus/pci/devices"

-- The detector reads cached sysfs IDs only; it never opens or wakes a GPU.
local pipe = io.popen("'" .. detector .. "' 2>/dev/null")
if not pipe then
  return
end
local node = pipe:read("*l")
pipe:close()

-- /dev/dri/by-path/pci-<address>-render: the iGPU that drives the panel.
local address = node and node:match("/pci%-(.-)%-render$")
if not address then
  return
end

local file = io.open(devices .. "/" .. address .. "/vendor", "r")
if not file then
  return
end
local vendor = file:read("*l")
file:close()

-- radeonsi is Mesa's VA-API driver for AMD GPUs. Any other iGPU vendor is left
-- alone: the G16 GA605 only has the AMD one.
if vendor == "0x1002" then
  hl.env("LIBVA_DRIVER_NAME", "radeonsi")
end
