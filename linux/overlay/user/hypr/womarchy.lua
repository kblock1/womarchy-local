-- womarchy (Omarchy on WSL): adjustments for Windows.
-- Managed by womarchy-provision-user and overwritten on re-provisioning; put your
-- own changes in ~/.config/hypr/bindings.lua or input.lua instead.

-- Keybindings. Windows always consumes Super+L (lock) and Ctrl+Alt+Del (secure
-- attention sequence): no application, RDP client or keyboard hook ever
-- receives them. Move the Omarchy actions bound to them.
if _G.omarchy_default_bindings ~= false then
  hl.unbind("SUPER + L")
  hl.unbind("CTRL + ALT + DELETE")
  -- "Laptop display mirroring" contains Ctrl+Alt+Del, and WSL has no laptop panel.
  hl.unbind("SUPER + CTRL + ALT + Delete")
end

o.bind("SUPER + ALT + L", "Toggle workspace layout", "omarchy-hyprland-workspace-layout-toggle")
o.bind("SUPER + CTRL + ALT + BACKSPACE", "Close all windows", "omarchy-hyprland-window-close-all")

-- Keyboard options. Omarchy reads XKBLAYOUT/XKBVARIANT from /etc/vconsole.conf
-- but keeps its own kb_options; the first-run setup records extra options there
-- as XKBOPTIONS (e.g. grp:alt_shift_toggle when Windows has several keyboard
-- layouts). Append them to whatever kb_options is in effect.
local function vconsole_value(key)
  local file = io.open("/etc/vconsole.conf", "r")
  if not file then
    return nil
  end
  local value
  for line in file:lines() do
    local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k == key then
      value = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
    end
  end
  file:close()
  return value
end

local extra = vconsole_value("XKBOPTIONS")
if extra and extra ~= "" then
  local ok, current = pcall(hl.get_config, "input.kb_options")
  if not ok or type(current) ~= "string" then
    current = "compose:caps,shift:both_capslock_cancel" -- Omarchy's default
  end
  local options, seen = {}, {}
  for opt in (current .. "," .. extra):gmatch("[^,]+") do
    if not seen[opt] then
      seen[opt] = true
      options[#options + 1] = opt
    end
  end
  hl.config({ input = { kb_options = table.concat(options, ",") } })
end
