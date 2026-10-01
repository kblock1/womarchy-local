-- womarchy (Omarchy on WSL): keybinding changes for Windows.
-- Managed by womarchy-provision-user and overwritten on re-provisioning; put your
-- own changes in ~/.config/hypr/bindings.lua instead.
--
-- Windows always consumes Super+L (lock) and Ctrl+Alt+Del (secure attention
-- sequence): no application, RDP client or keyboard hook ever receives them.
-- Move the Omarchy actions bound to them.

if _G.omarchy_default_bindings ~= false then
  hl.unbind("SUPER + L")
  hl.unbind("CTRL + ALT + DELETE")
  -- "Laptop display mirroring" contains Ctrl+Alt+Del, and WSL has no laptop panel.
  hl.unbind("SUPER + CTRL + ALT + Delete")
end

o.bind("SUPER + ALT + L", "Toggle workspace layout", "omarchy-hyprland-workspace-layout-toggle")
o.bind("SUPER + CTRL + ALT + BACKSPACE", "Close all windows", "omarchy-hyprland-window-close-all")
