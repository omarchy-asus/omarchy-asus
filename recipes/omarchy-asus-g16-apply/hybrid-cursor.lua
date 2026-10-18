-- On a hybrid laptop the iGPU renders every frame, but some ports (HDMI on most
-- gaming laptops) are wired to the NVIDIA GPU. A hardware cursor on such an
-- output has to be copied across GPUs on every update, and with the NVIDIA
-- driver that copy fails ("cursor blit failed", hundreds a minute) while each
-- failed attempt leaks GPU buffers in aquamarine, so Hyprland's memory grows
-- for as long as the monitor is plugged in. Hyprland's own "auto" only picks a
-- software cursor when NVIDIA is the renderer, which it is not here.
--
-- no_hardware_cursors is global, so use a software cursor only while an output
-- on the NVIDIA card is connected and go back to auto when it is unplugged; the
-- laptop panel keeps its hardware cursor the rest of the time. A value the user
-- sets themselves is left alone.

local drm_path = os.getenv("OMARCHY_DRM_PATH")
if drm_path == nil or drm_path == "" then
  drm_path = "/sys/class/drm"
end

local NVIDIA_VENDOR = "0x10de"
local AUTO = 2
local SOFTWARE = 1

-- Reads cached sysfs only: the PCI vendor ID never resumes a sleeping GPU.
local function card_vendor(card)
  local file = io.open(drm_path .. "/" .. card .. "/device/vendor", "r")
  if not file then
    return nil
  end
  local vendor = file:read("*l")
  file:close()
  return vendor
end

local function connector_card(connector)
  for index = 0, 15 do
    local file = io.open(drm_path .. "/card" .. index .. "-" .. connector .. "/status", "r")
    if file then
      file:close()
      return "card" .. index
    end
  end
  return nil
end

-- Hybrid: an NVIDIA card next to a display card from another vendor.
local function hybrid()
  local nvidia, other = false, false
  for index = 0, 15 do
    local vendor = card_vendor("card" .. index)
    if vendor == NVIDIA_VENDOR then
      nvidia = true
    elseif vendor then
      other = true
    end
  end
  return nvidia and other
end

if not hybrid() then
  return
end

local function nvidia_output_connected()
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    local card = monitor.name and connector_card(monitor.name)
    if card and card_vendor(card) == NVIDIA_VENDOR then
      return true
    end
  end
  return false
end

local applied = nil

local function apply()
  local current = tonumber(hl.get_config("cursor.no_hardware_cursors"))
  if applied == nil and current ~= nil and current ~= AUTO then
    return
  end
  if applied ~= nil and current ~= applied then
    return
  end

  local wanted = nvidia_output_connected() and SOFTWARE or AUTO
  if wanted ~= current then
    hl.config({ cursor = { no_hardware_cursors = wanted } })
  end
  applied = wanted
end

-- A removed monitor can still be listed while its event runs, so look again a
-- moment later.
local function on_monitor_change()
  apply()
  hl.timer(apply, { timeout = 1000, type = "oneshot" })
end

hl.on("monitor.added", on_monitor_change)
hl.on("monitor.removed", on_monitor_change)
-- A reload puts every option back to what the config files say, so whatever
-- is set then is the user's own choice (or auto).
local function on_reload()
  applied = nil
  apply()
end

hl.on("hyprland.start", apply)
hl.on("config.reloaded", on_reload)
