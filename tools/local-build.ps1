<#
.SYNOPSIS
    Build womarchy locally: packages, your signed [womarchy] repo, the Omarchy image, omarchy.exe.
    Run tools\local-setup.ps1 once first. See LOCAL-BUILD.md.

.EXAMPLE
    tools\local-build.ps1                          # everything: all packages, sign, image, exe
    tools\local-build.ps1 -Packages mesa-womarchy  # rebuild one package and re-sign (e.g. after an LLVM bump)
    tools\local-build.ps1 -Sync -Packages mesa-womarchy   # the same, after moving to Omarchy's current snapshot
    tools\local-build.ps1 -Image -Lite             # just a new (lite) image from the current repo
    tools\local-build.ps1 -Exe                     # just omarchy.exe
#>
param(
    # Packages to build (default when no step is chosen: all of them). Signing always follows.
    [string[]]$Packages,
    [switch]$Image,
    [switch]$Lite,
    [switch]$Exe,
    [switch]$Sync,   # first move the build distro to Omarchy's current Arch snapshot (pacman -Syyuu)
    [string]$BuildDistro = "womarchy-build"
)
# Native commands are checked through $LASTEXITCODE (as in install.ps1): with "Stop", Windows PowerShell
# 5.1 turns stderr output of native commands (cargo's progress) into a terminating error when redirected.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$LinuxRoot = "/mnt/" + $Root.Substring(0, 1).ToLower() + ($Root.Substring(2) -replace '\\', '/')
$all = -not ($PSBoundParameters.ContainsKey("Packages") -or $Image -or $Exe -or $Sync)
$UpstreamKey = "EB71032617BBA1C4C8EE77C3047A25C1135F969D"   # sytelus/womarchy's CI key: not yours to sign with

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Wsl([string]$user, [string]$command) {
    & wsl.exe -d $BuildDistro -u $user -e bash -c $command
    if ($LASTEXITCODE -ne 0) { throw "failed in ${BuildDistro} (exit $LASTEXITCODE): $command" }
}

if ($all -or $Image -or $PSBoundParameters.ContainsKey("Packages")) {
    $keyEnv = Get-Content (Join-Path $Root "linux\image\omarchy-key.env") -Raw
    $config = Get-Content (Join-Path $Root "linux\image\rootfs\etc\womarchy\config") -Raw
    if ($keyEnv -match "WOMARCHY_KEY_FPR=$UpstreamKey" -or $config -notmatch '(?m)^WOMARCHY_REPO_URL=file://') {
        throw "This checkout still has upstream's repo key or repo URL. Run tools\local-setup.ps1 first."
    }
}

if ($Sync) {
    Step "Moving $BuildDistro to Omarchy's current Arch snapshot"
    Wsl root "nice -n 10 pacman -Syyuu --noconfirm"
}
if ($all -or $PSBoundParameters.ContainsKey("Packages")) {
    $names = ($Packages | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ }) -join " "
    Step "Building packages: $(if ($names) { $names } else { 'all' })"
    Wsl builder "cd '$LinuxRoot' && MAKEFLAGS=-j`$(nproc) bash linux/packages/build-all.sh $names"
    Step "Signing out/repo"
    Wsl builder "bash '$LinuxRoot/linux/packages/sign-repo.sh'"
}
if ($all -or $Image) {
    Step "Building the Omarchy image$(if ($Lite) { ' (lite)' })"
    Wsl root "LITE=$([int][bool]$Lite) bash '$LinuxRoot/linux/image/build-image.sh'"
}
if ($all -or $Exe) {
    Step "Building omarchy.exe"
    Push-Location (Join-Path $Root "windows\omarchy")
    try {
        cargo build --release; if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
        cargo test --release; if ($LASTEXITCODE -ne 0) { throw "cargo test failed" }
    } finally { Pop-Location }
}

Write-Host "`nDone." -ForegroundColor Green
$img = Get-ChildItem (Join-Path $Root "out") -Filter "Omarchy-*.wsl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
$exePath = Join-Path $Root "windows\omarchy\target\release\omarchy.exe"
if ($img -and (Test-Path $exePath)) {
    Write-Host "First install (keeps an existing Omarchy distro and only updates omarchy.exe):"
    Write-Host "  & `"$(Join-Path $Root 'install.ps1')`" -Image `"$($img.FullName)`" -Exe `"$exePath`""
    Write-Host "Already installed: new packages reach it with  omarchy update"
}
