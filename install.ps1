<#
.SYNOPSIS
    Installs Omarchy (Arch Linux + Hyprland) as a GPU-accelerated desktop on Windows 11, using WSL.

.DESCRIPTION
    Run it from PowerShell (no administrator rights needed; Windows asks for them once if WSL itself
    has to be installed or updated):

        irm https://raw.githubusercontent.com/sytelus/womarchy/main/install.ps1 | iex

    Before changing anything it explains what it will do and asks for confirmation:
      1. WSL: installs it, or updates it to the tested version or newer, if needed. This affects all
         your WSL distros (they keep their files), restarts WSL, and may need a Windows restart.
      2. Downloads omarchy.exe and the Omarchy WSL image (about 1.7 GB) from the latest release.
      3. Runs `omarchy install`: imports the image as a new WSL distro named "Omarchy", asks you to pick
         a user name and password, and adds a Start menu entry and the `omarchy` command.
    Undo everything with:  omarchy uninstall

.PARAMETER Distro
    Name of the WSL distro to create (default: Omarchy).
.PARAMETER Image
    Install from this .wsl file or https URL instead of the latest release.
.PARAMETER Exe
    Use this omarchy.exe instead of downloading it (for testing a build).
.PARAMETER Yes
    Don't ask for confirmation.
.PARAMETER NoLauncher
    Install only the distro: no Start menu entry, PATH entry or copy of omarchy.exe (for testing).
#>
param(
    [string]$Distro = "Omarchy",
    [string]$Image = "",
    [string]$Exe = "",
    [switch]$Yes,
    [switch]$NoLauncher
)

# Native commands are checked through $LASTEXITCODE; with "Stop", Windows PowerShell 5.1 would turn any
# stderr output of a redirected native command into a terminating error.
$ErrorActionPreference = "Continue"
$Release = "https://github.com/sytelus/womarchy/releases/latest/download"
$TestedWsl = [version]"3.0.1"   # the WSL version Omarchy is developed and tested on
$Docs = "https://github.com/sytelus/womarchy/blob/main/docs/TROUBLESHOOTING.md"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Stop-Install($text) {
    Say "`n$text" Red
    Say "Help: $Docs"
    # `irm | iex` runs in the caller's session: return to the prompt instead of closing the window
    throw "Omarchy was not installed."
}

# Installed WSL version, or $null when WSL is missing (or only the old Windows feature is present,
# which has no --version).
function Get-WslVersion {
    $old = $env:WSL_UTF8; $env:WSL_UTF8 = "1"
    try {
        $out = & wsl.exe --version 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $first = ($out | Select-Object -First 1) -replace "`0", ""
        if ($first -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
        return $null
    } catch {
        return $null
    } finally {
        $env:WSL_UTF8 = $old
    }
}

# Run wsl.exe with administrator rights (one UAC prompt) and return its exit code.
function Invoke-WslElevated($arguments) {
    try {
        $p = Start-Process -FilePath "wsl.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        return $p.ExitCode
    } catch {
        Stop-Install "Windows did not get permission to run 'wsl $arguments' (the administrator prompt was declined)."
    }
}

function Get-File($url, $dest) {
    & curl.exe -L --fail --proto "=https" --progress-bar -o $dest $url
    if ($LASTEXITCODE -ne 0) { Stop-Install "Download failed: $url" }
}

# --- what we are about to do -------------------------------------------------------------------------
Say "`nOmarchy for WSL installer`n" Cyan

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 22000) {
    Stop-Install "Omarchy needs Windows 11 (this is Windows build $build)."
}

$wsl = Get-WslVersion
$steps = @()
$wslAction = ""
if (-not $wsl) {
    $wslAction = "install"
    $steps += "Install WSL (Windows Subsystem for Linux). Windows asks for administrator permission and you will probably have to restart Windows, then run this installer again."
} elseif ($wsl -lt $TestedWsl) {
    $wslAction = "update"
    $steps += "Update WSL from $wsl to the latest version (at least $TestedWsl, which Omarchy is tested on). This applies to ALL your WSL distros: they keep their files, but WSL restarts (anything running in WSL stops) and Windows asks for administrator permission. See $Docs for known issues after the update."
}
if (-not $Exe) { $steps += "Download omarchy.exe from $Release." }
if (-not $Image) { $steps += "Download the Omarchy image (about 1.7 GB; it needs about 7 GB of disk once installed)." }
$steps += "Create a new WSL distro named '$Distro' (your other WSL distros are not touched), ask you for a user name and password, and add 'Omarchy' to the Start menu and the 'omarchy' command."

if ($wsl) { Say "WSL $wsl is installed." }
Say "This installer will:"
$i = 1
foreach ($s in $steps) { Say ("  {0}. {1}" -f $i, $s); $i++ }
Say "`nRequirements: a GPU driver with WSL support (current NVIDIA, AMD and Intel drivers have it)."
Say "To remove Omarchy later:  omarchy uninstall`n"

if (-not $Yes) {
    $answer = Read-Host "Continue? [y/N]"
    if ($answer -notmatch '^(y|yes)$') { Say "Nothing was changed."; return }
}

# --- 1. WSL ---------------------------------------------------------------------------------------------
if ($wslAction -eq "install") {
    Say "`nInstalling WSL (accept the administrator prompt) ..." Cyan
    $rc = Invoke-WslElevated "--install --no-distribution"
    $wsl = Get-WslVersion
    if (-not $wsl) {
        Say "`nWSL is installed, but Windows has to restart before it can be used." Yellow
        Say "Restart Windows, then run this installer again." Yellow
        return
    }
    if ($rc -ne 0) { Stop-Install "Installing WSL failed (wsl --install exited with $rc)." }
} elseif ($wslAction -eq "update") {
    Say "`nUpdating WSL (accept the administrator prompt) ..." Cyan
    $rc = Invoke-WslElevated "--update"
    $wsl = Get-WslVersion
    if (-not $wsl -or $wsl -lt $TestedWsl) {
        Stop-Install "WSL was not updated (it reports version '$wsl'; wsl --update exited with $rc). If it asked for a restart, restart Windows and run this installer again."
    }
}
Say "WSL $wsl is ready."

# --- 2. omarchy.exe -------------------------------------------------------------------------------------
$work = Join-Path $env:TEMP ("omarchy-install-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $work -ErrorAction Stop | Out-Null
try {
    if ($Exe) {
        if (-not (Test-Path $Exe)) { Stop-Install "$Exe not found." }
        Copy-Item $Exe (Join-Path $work "omarchy.exe") -ErrorAction Stop
    } else {
        Say "`nDownloading omarchy.exe ..." Cyan
        $exePath = Join-Path $work "omarchy.exe"
        Get-File "$Release/omarchy.exe" $exePath
        Get-File "$Release/omarchy.exe.sha256" "$exePath.sha256"
        $want = ((Get-Content "$exePath.sha256" -Raw) -split '\s+')[0].ToLower()
        $got = (Get-FileHash -Algorithm SHA256 $exePath).Hash.ToLower()
        if ($got -ne $want) { Stop-Install "The omarchy.exe download is corrupt (SHA-256 mismatch); try again." }
    }

    # --- 3. the distro, first-run setup, Start menu entry and PATH (all done by omarchy.exe) ------------
    Say "`nInstalling Omarchy ..." Cyan
    $installArgs = @("install")
    if ($Image) { $installArgs += $Image }
    if ($Distro -ne "Omarchy") { $installArgs += @("--distro", $Distro) }
    if ($NoLauncher) { $installArgs += "--no-launcher" }
    & (Join-Path $work "omarchy.exe") @installArgs
    if ($LASTEXITCODE -ne 0) { Stop-Install "omarchy install failed (exit code $LASTEXITCODE)." }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Say "`nDone. Start Omarchy from the Start menu, or type 'omarchy' in a new terminal." Green
Say "To come back to Windows, log out (Super+Escape opens the system menu); Ctrl+Alt+End minimises Omarchy." Green
