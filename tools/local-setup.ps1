<#
.SYNOPSIS
    One-time setup for building womarchy locally: the womarchy-build WSL distro and your own
    [womarchy] repository signing key. See LOCAL-BUILD.md.

.DESCRIPTION
    1. Creates the womarchy-build WSL distro from the official Arch Linux WSL image, unless it exists.
       Without -ArchImage the image is downloaded from Arch's mirrors and checked against the SHA-256
       that two mirrors publish.
    2. Runs linux/image/setup-build-distro.sh in it (build tools, the unprivileged builder user).
    3. Moves it to Omarchy's frozen Arch snapshot (stable-mirror.omarchy.org): the packages must be
       built against the same libraries the image gets.
    4. Runs linux/packages/local-key.sh as builder: your own signing key (the private key stays in the
       build distro), its public key in womarchy-keyring, its fingerprint pinned, and the image's
       WOMARCHY_REPO_URL pointed at this checkout's out\repo.
    Safe to run again. Then build with tools\local-build.ps1.

.EXAMPLE
    tools\local-setup.ps1
    tools\local-setup.ps1 -ArchImage C:\Downloads\archlinux.wsl
#>
param(
    # An official Arch Linux .wsl image to use instead of downloading one
    [string]$ArchImage = "",
    [string]$BuildDistro = "womarchy-build",
    # Where the build distro's virtual disk goes (about 15 GB once packages and the image are built)
    [string]$Location = "C:\WSL\womarchy-build"
)
# Native commands are checked through $LASTEXITCODE (as in install.ps1): with "Stop", Windows PowerShell
# 5.1 turns any stderr output of a redirected native command into a terminating error.
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$LinuxRoot = "/mnt/" + $Root.Substring(0, 1).ToLower() + ($Root.Substring(2) -replace '\\', '/')
$Mirrors = @("https://fastly.mirror.pkgbuild.com/wsl/latest", "https://geo.mirror.pkgbuild.com/wsl/latest")
$MinWsl = [version]"3.0.1"
$env:WSL_UTF8 = "1"

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Wsl([string]$user, [string]$command) {
    & wsl.exe -d $BuildDistro -u $user -e bash -c $command
    if ($LASTEXITCODE -ne 0) { throw "failed in ${BuildDistro} (exit $LASTEXITCODE): $command" }
}

if ($LinuxRoot -notmatch '^/mnt/[a-z](/[A-Za-z0-9._~%+-]+)*$') {
    throw "This checkout's path ($Root) has characters the image's repo URL can't hold (spaces?). Clone it to a plain path, e.g. C:\dev\womarchy-local."
}

$wslVersion = $null
# capture first: Select-Object -First in the pipeline stops wsl.exe early and $LASTEXITCODE reads -1
$out = & wsl.exe --version 2>$null
$first = ($out | Select-Object -First 1) -replace "`0", ""
if ($LASTEXITCODE -eq 0 -and $first -match '(\d+\.\d+\.\d+)') { $wslVersion = [version]$Matches[1] }
if (-not $wslVersion -or $wslVersion -lt $MinWsl) {
    throw "womarchy needs WSL $MinWsl or later (found: $(if ($wslVersion) { $wslVersion } else { 'none' })). Run 'wsl --update' (or 'wsl --install --no-distribution'), then run this again."
}

$distros = @(& wsl.exe -l -q 2>$null | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ })
if ($distros -contains $BuildDistro) {
    Step "$BuildDistro exists; keeping it"
} else {
    if (-not $ArchImage) {
        Step "Downloading the official Arch Linux WSL image"
        $sums = foreach ($m in $Mirrors) { ((& curl.exe -fsSL "$m/archlinux.wsl.SHA256") -split '\s+')[0].ToLower() }
        if ($LASTEXITCODE -ne 0 -or ($sums | Select-Object -Unique).Count -ne 1 -or $sums[0] -notmatch '^[0-9a-f]{64}$') {
            throw "the Arch mirrors' SHA-256 for archlinux.wsl are missing or differ: $($sums -join ', ')"
        }
        $ArchImage = Join-Path $env:TEMP "archlinux.wsl"
        & curl.exe -fL --progress-bar -o $ArchImage "$($Mirrors[0])/archlinux.wsl"
        if ($LASTEXITCODE -ne 0) { throw "download failed" }
        $got = (Get-FileHash -Algorithm SHA256 $ArchImage).Hash.ToLower()
        if ($got -ne $sums[0]) { Remove-Item $ArchImage; throw "archlinux.wsl SHA-256 $got does not match the mirrors' $($sums[0])" }
        Write-Host "SHA-256 matches both mirrors: $got"
    }
    Step "Creating the $BuildDistro distro in $Location"
    & wsl.exe --install --from-file $ArchImage --name $BuildDistro --location $Location --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install --from-file failed" }
}

Step "Setting up $BuildDistro (build tools, builder user)"
Wsl root "bash '$LinuxRoot/linux/image/setup-build-distro.sh'"

Step "Moving $BuildDistro to Omarchy's Arch snapshot"
Wsl root "echo 'Server = https://stable-mirror.omarchy.org/`$repo/os/`$arch' > /etc/pacman.d/mirrorlist && nice -n 10 pacman -Syyuu --noconfirm"

Step "Your [womarchy] signing key and repo URL"
Wsl builder "bash '$LinuxRoot/linux/packages/local-key.sh'"

Write-Host "`nReady. Build everything with:  tools\local-build.ps1" -ForegroundColor Green
