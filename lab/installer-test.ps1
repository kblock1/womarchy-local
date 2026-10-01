# End-to-end installer test on a throwaway distro (omarchy-test-e2e), never touching the user's PATH or
# Start menu (--no-launcher). First-run setup runs unattended (WOMARCHY_OOBE_DEFAULTS via WSLENV).
#   A: omarchy install IMAGE -> desktop tour -> status -> uninstall --yes
#   B: wsl --install --from-file (no setup) -> omarchy (detects missing setup, runs it, relaunches) -> uninstall
param([Parameter(Mandatory = $true)][string]$Image, [switch]$OnlyA, [switch]$OnlyB)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot   # repo root
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$out  = "$root\lab\out\installer"
$name = "omarchy-test-e2e"
$loc  = Join-Path $env:LOCALAPPDATA "womarchy-tests\$name"
New-Item -ItemType Directory -Force $out | Out-Null
$env:WSL_UTF8 = "1"
$env:WOMARCHY_OOBE_DEFAULTS = "1"
$env:WSLENV = (@($env:WSLENV, "WOMARCHY_OOBE_DEFAULTS") | Where-Object { $_ }) -join ":"
Set-Content "$out\tour.txt" "sleep 10000`nshot desktop.png`nkey super+Return`nsleep 3000`ntype echo installed-ok`nkey Return`nsleep 1000`nshot terminal.png`nquit"

function Gone() {
    $listed = (wsl.exe --list --quiet) -contains $name
    $menu = Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\$name"
    "distro listed: $listed, location exists: $(Test-Path $loc), start-menu folder: $menu"
}

if (-not $OnlyB) {
    "=== A: omarchy install"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $exe install $Image --distro $name --location $loc --no-launcher
    "install exit: $LASTEXITCODE after $([int]$sw.Elapsed.TotalSeconds) s"
    & $exe status --distro $name
    $p = Start-Process -FilePath $exe -ArgumentList "--distro $name --windowed 1280x720 --input-script $out\tour.txt --shot-dir $out" -PassThru -NoNewWindow -RedirectStandardError "$out\a-stderr.log"
    if (-not $p.WaitForExit(120000)) { "desktop did not exit"; $p.Kill() }
    "desktop exit: $($p.ExitCode)"; Get-Content "$out\a-stderr.log" | Select-String "shot"
    & $exe uninstall --distro $name --yes
    Gone
}

if (-not $OnlyA) {
    "=== B: plain import, then omarchy runs the first-run setup itself"
    wsl.exe --install --from-file $Image --name $name --location $loc --no-launch
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList "--distro $name --windowed 1280x720 --input-script $out\tour.txt --shot-dir $out" -PassThru -NoNewWindow -RedirectStandardError "$out\b-stderr.log" -RedirectStandardOutput "$out\b-stdout.log"
    if (-not $p.WaitForExit(240000)) { "did not exit"; $p.Kill() }
    "setup + desktop exit: $($p.ExitCode) after $([int]$sw.Elapsed.TotalSeconds) s"
    Get-Content "$out\b-stderr.log", "$out\b-stdout.log" | Select-String "Setting up|setup|shot|goodbye" | Select-Object -First 8
    & $exe uninstall --distro $name --yes
    Gone
}
