# Clipboard bridge test: Windows -> Linux at connect, Linux -> Windows, Windows -> Linux live, with
# multi-line text (CRLF <-> LF); then images both ways. Saves and restores the Windows clipboard text.
param([string]$Distro = "womarchy-lab")
$root = Split-Path -Parent $PSScriptRoot   # repo root
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out"
$saved = Get-Clipboard -Raw -ErrorAction SilentlyContinue
$tag = Get-Random
$ok = $true
function Check($name, $got, $want) {
    if ($got -eq $want) { "PASS $name" } else { "FAIL $name`n  got:  [$got]`n  want: [$want]"; $script:ok = $false }
}
# run a command inside the session (WAYLAND_DISPLAY comes from the user manager, published by the
# compositor; never fall back to WSLg's wayland-0, whose clipboard WSLg syncs with Windows by itself)
function InSession($cmd) {
    $sh = 'd=$(systemctl --user show-environment | sed -n "s/^WAYLAND_DISPLAY=//p"); [ -n "$d" ] || { echo NO-SESSION-DISPLAY; exit 1; }; export WAYLAND_DISPLAY=$d; ' + $cmd
    return (wsl -d $Distro --exec /usr/bin/bash -c $sh) -join "`n"
}

try {
    Set-Clipboard -Value "from windows $tag`r`nsecond line"
    $p = Start-Process -FilePath $exe -ArgumentList "--distro $Distro --windowed 960x540" `
        -RedirectStandardError "$out\clip-stderr.log" -RedirectStandardOutput "$out\clip-stdout.log" -PassThru -NoNewWindow
    # wait for the clipboard channel (a distro's first session takes longer), then a moment for the
    # initial Windows -> Linux copy
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Select-String -Path "$out\clip-stderr.log" -Pattern "clipboard: connected" -Quiet -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { "FAIL clipboard never connected"; $ok = $false; break }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2

    Check "windows->linux at connect" (InSession "wl-paste --no-newline") "from windows $tag`nsecond line"

    InSession "printf 'from linux $tag\nline two' | wl-copy" | Out-Null
    Start-Sleep -Milliseconds 800
    Check "linux->windows" (Get-Clipboard -Raw) "from linux $tag`r`nline two"

    Set-Clipboard -Value "live windows $tag"
    Start-Sleep -Milliseconds 800
    Check "windows->linux live" (InSession "wl-paste --no-newline") "live windows $tag"

    # images: a bitmap put on the Windows clipboard arrives as a PNG of the same size ...
    # (Windows Forms' clipboard needs an STA thread: Windows PowerShell 5.1 has one)
    powershell.exe -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms, System.Drawing; `$b = New-Object System.Drawing.Bitmap 64, 48; [System.Drawing.Graphics]::FromImage(`$b).Clear([System.Drawing.Color]::Orange); [System.Windows.Forms.Clipboard]::SetImage(`$b)"
    Start-Sleep -Milliseconds 1200
    Check "windows->linux image" ((InSession "wl-paste --type image/png | file -b -") -replace ',.*?(\d+ x \d+).*', ' $1') "PNG image data 64 x 48"

    # ... and a PNG copied in Linux (a 40x30 screenshot) arrives as an image of the same size, with the
    # PNG itself on the clipboard too
    InSession "grim -g '0,0 40x30' - | wl-copy --type image/png" | Out-Null
    Start-Sleep -Milliseconds 1200
    $img = powershell.exe -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; `$i = [System.Windows.Forms.Clipboard]::GetImage(); if (`$i) { '{0}x{1} png={2}' -f `$i.Width, `$i.Height, [System.Windows.Forms.Clipboard]::ContainsData('PNG') }"
    Check "linux->windows image" "$img" "40x30 png=True"

    $p.Refresh(); [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(15000)) { "viewer did not exit"; $p.Kill(); $ok = $false }
    "viewer exit code: $($p.ExitCode)"
    Get-Content "$out\clip-stderr.log" | Select-String "clipboard"
    wsl -d $Distro --exec /usr/bin/bash -c "journalctl --user -b -u womarchy-clipd --no-pager -o cat | tail -5"
} finally {
    if ($null -ne $saved) { Set-Clipboard -Value $saved } else { Set-Clipboard -Value $null }
}
if ($ok) { "ALL PASS" } else { "SOME FAILED" }
