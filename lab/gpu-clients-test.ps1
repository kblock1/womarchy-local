# GPU clients inside the session: run GL (es2gears) and Vulkan (vkcube, Dozen) Wayland clients in a
# windowed omarchy session and report their frame rates / errors, plus a frame dump.
param([string]$Distro = "womarchy-lab", [int]$Seconds = 12)
$root = Split-Path -Parent $PSScriptRoot   # repo root
. "$PSScriptRoot\assert-desktop.ps1"   # stops if Windows is locked
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out"
$p = Start-Process -FilePath $exe -ArgumentList "--distro $Distro --windowed 1280x720 --stats --dump-frame $out\gpu-clients.bmp --dump-after 480" `
    -RedirectStandardError "$out\gpu-clients-stderr.log" -PassThru -NoNewWindow
Start-Sleep -Seconds 6
$sh = @'
d=$(systemctl --user show-environment | sed -n "s/^WAYLAND_DISPLAY=//p"); [ -n "$d" ] || { echo NO-SESSION-DISPLAY; exit 1; }
export WAYLAND_DISPLAY=$d GALLIUM_DRIVER=d3d12; unset DISPLAY
cd ~/.cache/womarchy
timeout SECS stdbuf -oL es2gears_wayland >gl-client.log 2>&1 &
timeout SECS stdbuf -oL vkcube --wsi wayland >vk-client.log 2>&1 &
wait
echo "--- es2gears"; grep -E "GL_RENDERER|FPS|rror" gl-client.log | tail -3
echo "--- vkcube"; grep -iE "device|error|fail|select" vk-client.log | head -5; echo "(vkcube exit: see above; timeout = still running = ok)"
'@
$sh = $sh.Replace("SECS", "$Seconds")
wsl -d $Distro --exec /usr/bin/bash -c $sh
Start-Sleep -Seconds 1
$p.Refresh(); [void]$p.CloseMainWindow(); [void]$p.WaitForExit(15000)
"viewer exit: $($p.ExitCode)"
Get-Content "$out\gpu-clients-stderr.log" | Select-String "frames/s" | Select-Object -Last 3
if (Test-Path "$out\gpu-clients.bmp") {
    Add-Type -AssemblyName System.Drawing
    $b = [System.Drawing.Image]::FromFile("$out\gpu-clients.bmp"); $s = New-Object System.Drawing.Bitmap($b, 960, 540)
    $s.Save("$out\gpu-clients.png", [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose(); $s.Dispose(); "frame: $out\gpu-clients.png"
}
