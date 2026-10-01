# Live display-layout changes, without touching the real display settings: run the full-screen code
# path on small fake "monitors" (OMARCHY_FAKE_MONITORS_FILE), change the layout, send WM_DISPLAYCHANGE,
# and check the viewer windows, the compositor outputs and the regenerated monitor rules follow.
param([string]$Distro = "womarchy-lab",
      [string]$Session = "")
$root = Split-Path -Parent $PSScriptRoot   # repo root
# default: this checkout's womarchy-session (it has --update-monitors), as WSL sees the repo
if (-not $Session) { $Session = "/mnt/" + $root.Substring(0, 1).ToLower() + ($root.Substring(2) -replace '\\', '/') + "/linux/packages/womarchy-session/womarchy-session" }
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out"
$layout = "$out\fake-monitors.txt"
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class DC { [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l); }
"@
function Layout($spec) { Set-Content -Path $layout -Value $spec -NoNewline }
function Monitors() {
    $sh = 'i=$(ls -td $XDG_RUNTIME_DIR/hypr/*/ | head -1); HYPRLAND_INSTANCE_SIGNATURE=$(basename $i) hyprctl monitors | grep -E "^Monitor|^\s+[0-9]+x[0-9]+@"'
    (wsl -d $Distro --exec /usr/bin/bash -c $sh) -join " | "
}
function Poke($p) { $p.Refresh(); [void][DC]::PostMessageW($p.MainWindowHandle, 0x007E, [IntPtr]::Zero, [IntPtr]::Zero) }

Layout "1:100:100:640:360:60000:1000:1:FAKE1"
$env:OMARCHY_FAKE_MONITORS_FILE = $layout
$p = Start-Process -FilePath $exe -ArgumentList "--distro $Distro --session $Session --stats" -PassThru -NoNewWindow `
    -RedirectStandardError "$out\display-change-stderr.log"
Start-Sleep -Seconds 9
"A (1 monitor):  $(Monitors)"

Layout "1:100:100:800:450:60000:1000:1:FAKE1;2:950:100:640:360:60000:1250:0:FAKE2"
Poke $p; Start-Sleep -Seconds 5
"B (2 monitors): $(Monitors)"
"   rules: " + ((wsl -d $Distro --exec /usr/bin/bash -c 'grep WSL- $XDG_RUNTIME_DIR/womarchy/monitors.lua') -join " / ")

Layout "1:100:100:640:360:60000:1000:1:FAKE1"
Poke $p; Start-Sleep -Seconds 5
"C (back to 1):  $(Monitors)"

$p.Refresh(); [void]$p.CloseMainWindow(); [void]$p.WaitForExit(15000)
Remove-Item Env:\OMARCHY_FAKE_MONITORS_FILE
"viewer exit: $($p.ExitCode)"
Get-Content "$out\display-change-stderr.log" | Select-String "layout changed|output \d is|goodbye"
