# System health check after womarchy work: WSL settings untouched, every distro boots and reports its
# systemd state, nothing of ours left running. Distros that were stopped are stopped again afterwards.
param([string[]]$Distros = @())
$env:WSL_UTF8 = "1"
"=== WSL"
(wsl.exe --version) | Select-Object -First 3
foreach ($f in "$env:USERPROFILE\.wslconfig", "$env:USERPROFILE\.wslgconfig") {
    if (Test-Path $f) { "{0}: present, last modified {1}" -f $f, (Get-Item $f).LastWriteTime } else { "${f}: absent" }
}
Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform' OR Name='Microsoft-Windows-Subsystem-Linux'" |
    ForEach-Object { "feature {0}: {1}" -f $_.Name, @{1 = 'enabled'; 2 = 'disabled'; 3 = 'absent'}[[int]$_.InstallState] }
"reboot pending (CBS): $(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')"

"=== distros"
$running = @(wsl.exe --list --running --quiet | Where-Object { $_ })
$all = @(wsl.exe --list --quiet | Where-Object { $_ })
if ($Distros.Count -eq 0) { $Distros = $all }
foreach ($d in $Distros) {
    $was = $running -contains $d
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $state = (wsl.exe -d $d --exec sh -c 'systemctl is-system-running 2>/dev/null || echo no-systemd') -join " "
    $failed = (wsl.exe -d $d --exec sh -c 'systemctl --failed --no-legend --plain 2>/dev/null | cut -d" " -f1 | tr "\n" " "') -join " "
    "{0,-16} systemd: {1,-10} failed: [{2}] ({3} ms){4}" -f $d, $state, $failed.Trim(), $sw.ElapsedMilliseconds, $(if ($was) { "" } else { "  (was stopped; stopping again)" })
    if (-not $was) { wsl.exe --terminate $d | Out-Null }
}

"=== leftovers"
"omarchy.exe processes: $(@(Get-Process omarchy -ErrorAction SilentlyContinue).Count)"
$vm = Get-Process vmmem* -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum
"WSL VM (vmmem) working set: {0:N0} MB" -f ($vm.Sum / 1MB)
"running distros now: $((wsl.exe --list --running --quiet | Where-Object { $_ }) -join ', ')"
