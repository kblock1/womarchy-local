<#
.SYNOPSIS
    Installs Omarchy (Arch Linux + Hyprland) as a GPU-accelerated desktop on Windows 11, using WSL.

.DESCRIPTION
    Run it from PowerShell in your checkout (no administrator rights needed; Windows asks for them once
    if WSL itself has to be installed or updated), with what tools\local-build.ps1 built:

        .\install.ps1 -Image out\Omarchy-<version>-womarchy-<date>.wsl -Exe windows\omarchy\target\release\omarchy.exe

    This copy downloads nothing from upstream's releases (see LOCAL-BUILD.md).

    Before changing anything it explains what it will do and asks for confirmation:
      1. WSL: installs it, or updates it to the tested version or newer, if needed. This affects all
         your WSL distros (they keep their files), restarts WSL, and may need a Windows restart.
      2. Uses the omarchy.exe and Omarchy WSL image you built.
      3. Runs `omarchy install`: imports the image as a new WSL distro named "Omarchy", asks you to pick
         a user name and password, and adds a Start menu entry and the `omarchy` command.
    Undo everything with:  omarchy uninstall

.PARAMETER Distro
    Name of the WSL distro to create (default: Omarchy).
.PARAMETER Image
    The Omarchy .wsl image to install (out\Omarchy-*.wsl from tools\local-build.ps1). Required unless the
    distro already exists.
.PARAMETER Exe
    The omarchy.exe to install (windows\omarchy\target\release\omarchy.exe). Required.
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
$TestedWsl = [version]"3.0.1"   # the WSL version Omarchy is developed and tested on
$Docs = if ($PSScriptRoot) { Join-Path $PSScriptRoot "docs\TROUBLESHOOTING.md" } else { "docs\TROUBLESHOOTING.md in your checkout" }

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

# True when a WSL distro with this name exists (re-running the installer keeps it).
function Test-Distro($name) {
    $old = $env:WSL_UTF8; $env:WSL_UTF8 = "1"
    try {
        $names = (& wsl.exe --list --quiet 2>$null) | ForEach-Object { ($_ -replace "`0", "").Trim() }
        return $LASTEXITCODE -eq 0 -and ($names -contains $name)
    } catch {
        return $false
    } finally {
        $env:WSL_UTF8 = $old
    }
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
# Re-running the installer over an existing install keeps the distro and only updates omarchy.exe and
# its shortcuts (`omarchy install` skips the image when the distro exists).
$existing = $wsl -and (Test-Distro $Distro)
# This copy downloads nothing: omarchy.exe and the image come from tools\local-build.ps1 (LOCAL-BUILD.md).
if (-not $Exe) {
    Stop-Install "Pass the omarchy.exe you built: -Exe windows\omarchy\target\release\omarchy.exe (tools\local-build.ps1 prints the full command; see LOCAL-BUILD.md)."
}
if (-not $existing -and -not $Image) {
    Stop-Install "Pass the image you built: -Image out\Omarchy-<version>-womarchy-<date>.wsl (tools\local-build.ps1 prints the full command; see LOCAL-BUILD.md)."
}
$steps += "Use omarchy.exe from $Exe."
if ($existing) {
    $steps += "Keep your existing '$Distro' distro as it is, and update omarchy.exe, the Start menu entry and the 'omarchy' command. (To update the Linux side, run 'omarchy update'.)"
} else {
    $steps += "Install the Omarchy image $Image (it needs about 7 GB of disk once installed)."
    $steps += "Create a new WSL distro named '$Distro' (your other WSL distros are not touched), ask you for a user name and password, and add 'Omarchy' to the Start menu and the 'omarchy' command."
}

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
    if (-not (Test-Path $Exe)) { Stop-Install "$Exe not found." }
    Copy-Item $Exe (Join-Path $work "omarchy.exe") -ErrorAction Stop

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
