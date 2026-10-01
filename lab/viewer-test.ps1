# End-to-end dev test: run omarchy.exe windowed against the lab distro, dump a frame, then end the
# session and check omarchy.exe exits with the session's exit code.
#   -EndBy close: close the viewer window (what a user does; the viewer sends QUIT)
#   -EndBy kill:  SIGTERM Hyprland from the Linux side
#   -Session:     the in-distro entry point (the packaged one, or lab/run-session.sh for /opt dev builds)
param([int]$Seconds = 20, [string]$Size = "1280x720", [string]$Extra = "", [int]$DumpAfter = 8,
      [string]$Session = "/usr/bin/womarchy-session", [string]$EndBy = "close", [string]$Distro = "womarchy-lab")
$root = Split-Path -Parent $PSScriptRoot   # repo root
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out"
New-Item -ItemType Directory -Force $out | Out-Null
Remove-Item "$out\viewer-frame.bmp", "$out\viewer-stderr.log" -ErrorAction SilentlyContinue
$args = "--distro $Distro --session $Session --windowed $Size --stats --dump-frame $out\viewer-frame.bmp --dump-after $DumpAfter $Extra"
$p = Start-Process -FilePath $exe -ArgumentList $args -RedirectStandardError "$out\viewer-stderr.log" -RedirectStandardOutput "$out\viewer-stdout.log" -PassThru -NoNewWindow
Start-Sleep -Seconds $Seconds
if ($EndBy -eq "close") {
    $p.Refresh()
    if (-not $p.CloseMainWindow()) { "could not close the viewer window" }
} else {
    wsl -d $Distro -- bash -c "pkill -TERM -x Hyprland; sleep 2; pkill -KILL -x Hyprland" 2>$null
}
$exited = $p.WaitForExit(15000)
if (-not $exited) { "viewer did not exit; killing"; $p.Kill() }
"viewer exit code: $($p.ExitCode)"
"--- viewer stderr:"; Get-Content "$out\viewer-stderr.log" -ErrorAction SilentlyContinue | Select-Object -Last 25
if (Test-Path "$out\viewer-frame.bmp") { "frame dump: $((Get-Item "$out\viewer-frame.bmp").Length) bytes" } else { "no frame dump" }
