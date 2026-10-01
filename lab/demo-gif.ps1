# Record the README's demo GIF: runs lab/scripts-omarchy-demo.txt in a 1920x1080 window, records the
# desktop from inside the session (lab/demo-record.sh: grim, ~10 frames/s), then turns that into
# docs/img/demo.gif with lab/make-demo-gif.py (captions per scene, a title card).
#   pwsh lab\demo-gif.ps1 -Distro <distro with mesa-utils + vulkan-tools>
# Use a throwaway distro: the GIF shows its desktop, so nothing personal may be on it (set its
# hostname in /etc/wsl.conf, [network] hostname=...; fastfetch prints it).
param([Parameter(Mandatory = $true)][string]$Distro, [string]$Gif = "", [string]$Size = "1920x1080")
$root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\assert-desktop.ps1"   # stops if Windows is locked
$exe  = "$root\windows\omarchy\target\release\omarchy.exe"
$run  = "$root\lab\out\demo"
if (-not $Gif) { $Gif = "$root\docs\img\demo.gif" }
if (Test-Path $run) { Get-ChildItem $run -File | Remove-Item }
New-Item -ItemType Directory -Force $run | Out-Null
$wslRun = "/mnt/" + $run.Substring(0, 1).ToLower() + ($run.Substring(2) -replace '\\', '/')
$wslRecorder = "/mnt/" + $root.Substring(0, 1).ToLower() + ($root.Substring(2) -replace '\\', '/') + "/lab/demo-record.sh"

$recorder = Start-Process wsl.exe -PassThru -WindowStyle Hidden -ArgumentList "-d $Distro --exec bash $wslRecorder"
$p = Start-Process -FilePath $exe -PassThru -NoNewWindow -RedirectStandardError "$run\viewer.log" `
    -ArgumentList "--distro $Distro --windowed $Size --input-script $root\lab\scripts-omarchy-demo.txt"
if (-not $p.WaitForExit(300000)) { "viewer did not exit; killing"; $p.Kill() }
wsl -d $Distro --exec bash -c "touch /tmp/womarchy-demo/stop; sleep 1; cp /tmp/womarchy-demo/frame-*.png '$wslRun/'"
[void]$recorder.WaitForExit(15000)
"viewer exit: $($p.ExitCode); $((Get-ChildItem $run -Filter 'frame-*.png').Count) frames"
python "$root\lab\make-demo-gif.py" $run $Gif
