# Full-screen test on the real monitors (takes over every screen for about a minute, then quits by
# itself). Runs lab/scripts-omarchy-fullscreen.txt; once its apps are open (its 02-apps shot exists),
# captures the actual Windows screen from a separate DPI-aware process; reports frame rates and the
# viewer's CPU use.
#   pwsh lab\fullscreen-test.ps1 -Distro <distro with mesa-utils + vulkan-tools>
param([Parameter(Mandatory = $true)][string]$Distro)
$root = Split-Path -Parent $PSScriptRoot
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out\fullscreen"
New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item "$out\*" -ErrorAction SilentlyContinue

$capture = Start-Job -ArgumentList $out -ScriptBlock {
    param($out)
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Path "$out\02-apps.png")) {
        if ((Get-Date) -gt $deadline) { return "no Windows capture: the script never reached its 02-apps shot" }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 1
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    Add-Type 'using System; using System.Runtime.InteropServices; public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
    [void][Dpi]::SetProcessDpiAwarenessContext([IntPtr]-4)   # per-monitor v2: physical pixels
    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($v.Width, $v.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($v.X, $v.Y, 0, 0, $bmp.Size)
    $small = New-Object System.Drawing.Bitmap($bmp, [int]($v.Width / 4), [int]($v.Height / 4))
    $small.Save("$out\windows-screen.png"); $g.Dispose(); $bmp.Dispose(); $small.Dispose()
    "virtual screen $($v.X),$($v.Y) $($v.Width)x$($v.Height)"
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $exe -PassThru -NoNewWindow -RedirectStandardError "$out\viewer.log" `
    -ArgumentList "--distro $Distro --stats --input-script $root\lab\scripts-omarchy-fullscreen.txt --shot-dir $out"
if (-not $p.WaitForExit(240000)) { "viewer did not exit; killing"; $p.Kill() }
$cpu = $p.TotalProcessorTime.TotalSeconds
"exit: $($p.ExitCode) after $([int]$sw.Elapsed.TotalSeconds) s; viewer CPU time $([math]::Round($cpu, 1)) s"
Receive-Job $capture -Wait; Remove-Job $capture
Get-Content "$out\viewer.log" | Select-String "output \d is|frames/s|slow frame|shot .* (ok|FAILED)" | Select-Object -First 40
