# Clipboard bridge test: Windows -> Linux at connect, Linux -> Windows, Windows -> Linux live, with
# multi-line text (CRLF <-> LF). Saves and restores the Windows clipboard text.
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
    Start-Sleep -Seconds 10

    Check "windows->linux at connect" (InSession "wl-paste --no-newline") "from windows $tag`nsecond line"

    InSession "printf 'from linux $tag\nline two' | wl-copy" | Out-Null
    Start-Sleep -Milliseconds 800
    Check "linux->windows" (Get-Clipboard -Raw) "from linux $tag`r`nline two"

    Set-Clipboard -Value "live windows $tag"
    Start-Sleep -Milliseconds 800
    Check "windows->linux live" (InSession "wl-paste --no-newline") "live windows $tag"

    $p.Refresh(); [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(15000)) { "viewer did not exit"; $p.Kill(); $ok = $false }
    "viewer exit code: $($p.ExitCode)"
    Get-Content "$out\clip-stderr.log" | Select-String "clipboard"
    wsl -d $Distro --exec /usr/bin/bash -c "journalctl --user -b -u womarchy-clipd --no-pager -o cat | tail -5"
} finally {
    if ($null -ne $saved) { Set-Clipboard -Value $saved } else { Set-Clipboard -Value $null }
}
if ($ok) { "ALL PASS" } else { "SOME FAILED" }
