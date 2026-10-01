# Dot-source at the top of a test that shows the desktop: . "$PSScriptRoot\assert-desktop.ps1"
# While Windows is locked, presents stall (Hyprland falls back to its 250 ms frame timeout, ~4 FPS)
# and the Windows clipboard can't be opened, so frame-rate and clipboard results would be false
# failures. Stop early with a clear message instead (docs/JOURNEY.md, story 14). `throw`, because
# `exit` in a dot-sourced file only leaves this file, not the test.
if (Get-Process LogonUI -ErrorAction SilentlyContinue) {
    throw "Windows is locked (the lock screen is up): frame rates and the clipboard can't be tested now. Unlock it and run again."
}
