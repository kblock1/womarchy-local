# Install a built womarchy .wsl as a throwaway distro, run the real WSL OOBE
# unattended, and verify it (system + user + Windows Start menu). Does not start Hyprland.
#   pwsh linux/image/test-image.ps1 -Image out\Omarchy-4.0.4-womarchy-20260930-lite.wsl [-Name omarchy-test-2] [-Location D:\WSL\omarchy-test-2] [-Keep]
# Test distros must be named omarchy-test*. They are unregistered at the end, also
# when the test fails, unless -Keep is given. The OOBE uses the TEST-ONLY defaults
# (user omarchy / password omarchy).
param(
  [Parameter(Mandatory = $true)][string]$Image,
  [string]$Name = "omarchy-test",
  [string]$Location = (Join-Path $env:LOCALAPPDATA "womarchy-test\omarchy-test"),
  [switch]$Keep
)
$ErrorActionPreference = "Stop"
if ($Name -notlike "omarchy-test*") { throw "test distros must be named omarchy-test*" }
if (-not $PSBoundParameters.ContainsKey('Location')) { $Location = Join-Path $env:LOCALAPPDATA "womarchy-test\$Name" }
$distros = (wsl.exe --list --quiet) -replace "`0", "" | Where-Object { $_ }
if ($distros -contains $Name) { throw "$Name already exists; run: wsl --unregister $Name" }

$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$verify = "/mnt/" + $repo.Substring(0, 1).ToLower() + ($repo.Substring(2) -replace '\\', '/') + "/linux/image/verify-image.sh"
$menu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$Name"
$savedEnv = @{ WOMARCHY_OOBE_DEFAULTS = $env:WOMARCHY_OOBE_DEFAULTS; WSLENV = $env:WSLENV }
$installed = $false
$keepAlive = $null
$rc = 1

function Count-Links { if (Test-Path $menu) { @(Get-ChildItem $menu -Filter *.lnk).Count } else { 0 } }
function Wait-For([scriptblock]$cond, [int]$seconds) {
  for ($i = 0; $i -lt $seconds; $i++) { if (& $cond) { return $true }; Start-Sleep 1 }; return $false
}

try {
  # --from-file: never triggers wsl --install's optional-component (DISM) path.
  wsl.exe --install --from-file $Image --name $Name --location $Location --no-launch
  if ($LASTEXITCODE) { throw "install failed" }
  $installed = $true

  # The real OOBE runs when the default shell is launched; WSLENV hands it the
  # TEST-ONLY defaults. These variables are restored in `finally`.
  $env:WOMARCHY_OOBE_DEFAULTS = "1"
  $env:WSLENV = (@($savedEnv.WSLENV, "WOMARCHY_OOBE_DEFAULTS") | Where-Object { $_ }) -join ":"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # stdin at EOF: after the OOBE the default shell exits right away.
  cmd.exe /d /c "wsl.exe -d $Name < NUL"
  Write-Host "OOBE + first shell: $([int]$sw.Elapsed.TotalSeconds) s (exit $LASTEXITCODE)"
  $env:WOMARCHY_OOBE_DEFAULTS = $savedEnv.WOMARCHY_OOBE_DEFAULTS
  $env:WSLENV = $savedEnv.WSLENV

  wsl.exe -d $Name -u root -e bash $verify
  $rootRc = $LASTEXITCODE
  wsl.exe -d $Name -e bash $verify
  $userRc = $LASTEXITCODE
  Write-Host "verify: system rc=$rootRc user rc=$userRc"

  # Windows Start menu: WSLg publishes the distro's apps as "<Name> (<distro>)"
  # shortcuts; the image hides them all. Keep the distro up, count them, then
  # prove the mechanism live: drop Foot's override and replace its system entry
  # the way a package update does (the shortcut must appear), then run the pacman
  # hook's script (it must go away). Deleting an override alone is not enough:
  # WSLg treats that as the app being removed.
  $keepAlive = Start-Process wsl.exe -ArgumentList "-d $Name -e sleep 300" -WindowStyle Hidden -PassThru
  Start-Sleep 20
  $menuRc = 0
  Write-Host "Start menu entries for ${Name}: $(Count-Links)"
  if ((Count-Links) -ne 0) { $menuRc = 1 }
  wsl.exe -d $Name -u root -e bash -c 'rm -f /usr/local/share/applications/foot.desktop; sleep 1; cd /usr/share/applications && cp -p foot.desktop .foot.tmp && mv -f .foot.tmp foot.desktop'
  $lnk = Join-Path $menu "Foot ($Name).lnk"
  $shown = Wait-For { Test-Path $lnk } 30
  wsl.exe -d $Name -u root -e /usr/lib/womarchy/wslg-hide-apps
  $hidden = Wait-For { -not (Test-Path $lnk) } 30
  Write-Host "live check: Foot shortcut appeared without override=$shown, removed after re-hide=$hidden"
  if (-not ($shown -and $hidden)) { $menuRc = 1 }

  $rc = [int](($rootRc -ne 0) -or ($userRc -ne 0) -or ($menuRc -ne 0))
}
finally {
  $env:WOMARCHY_OOBE_DEFAULTS = $savedEnv.WOMARCHY_OOBE_DEFAULTS
  $env:WSLENV = $savedEnv.WSLENV
  if ($keepAlive) { Stop-Process -Id $keepAlive.Id -ErrorAction SilentlyContinue }
  if ($installed -and -not $Keep) {
    wsl.exe --unregister $Name | Out-Null
    Write-Host "unregistered $Name"
    # WSLg's per-distro Start-menu folder survives --unregister: remove it when it
    # holds nothing but this distro's own "(<name>).lnk" shortcuts.
    if (Test-Path $menu) {
      $other = Get-ChildItem $menu -Force | Where-Object { $_.Name -notlike "*($Name).lnk" }
      if (-not $other) { Remove-Item $menu -Recurse -Force; Write-Host "removed $menu" }
    }
  }
}
# Dot-sourced (". test-image.ps1"): return, do not close the caller's shell.
if ($MyInvocation.InvocationName -eq '.') { return $rc } else { exit $rc }
