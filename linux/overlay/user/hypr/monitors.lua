-- womarchy (Omarchy on WSL): monitors follow Windows.
-- womarchy-session writes one hl.monitor rule per Windows monitor (outputs
-- WSL-1, WSL-2, ...: mode, position and scale from Windows DPI, plus GDK_SCALE)
-- to $XDG_RUNTIME_DIR/womarchy/monitors.lua before Hyprland starts.
-- Without it (e.g. another backend), fall back to Omarchy's default rule.
local gen = (os.getenv("XDG_RUNTIME_DIR") or "") .. "/womarchy/monitors.lua"
local f = io.open(gen, "r")
if f then
  f:close()
  dofile(gen)
else
  hl.env("GDK_SCALE", "1")
  hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end

-- Your own overrides go below; they win over the generated rules.
-- List current monitors with: hyprctl monitors all
-- hl.monitor({ output = "WSL-1", mode = "2560x1440@144", position = "0x0", scale = 1 })
