# Correlate per-frame timelines: Linux (send -> ack, from the Hyprland log) vs the viewer (recv -> ack).
param([int]$Seconds = 8, [int]$Skip = 10, [int]$Count = 14)
$env:OMARCHY_FRAME_TRACE = "1"
& "$PSScriptRoot\viewer-test.ps1" -Seconds $Seconds | Out-Null
$env:OMARCHY_FRAME_TRACE = $null

$viewer = @{}
foreach ($line in Get-Content "$PSScriptRoot\out\viewer-stderr.log") {
    if ($line -match '\[trace\] seq (\d+) recv ([\d.]+) acked ([\d.]+)') {
        $viewer[[int]$Matches[1]] = @([double]$Matches[2], [double]$Matches[3])
    }
}
$send = @{}; $ack = @{}
$linux = wsl -d womarchy-lab -e bash -c 'grep -E "send seq|ack seq" ~/.cache/womarchy/hypr-last.log | sed -E "s/\x1b\[[0-9;]*m//g; s/.*wsl-trace //"'
foreach ($line in $linux) {
    if ($line -match '^([\d.]+) \S+ send seq (\d+)') { $send[[int]$Matches[2]] = [double]$Matches[1] }
    elseif ($line -match '^([\d.]+) \S+ ack seq (\d+)') { $ack[[int]$Matches[2]] = [double]$Matches[1] }
}
"seq | linux send->ack ms | viewer recv->ack ms | viewer gap since prev recv ms | linux gap since prev send ms"
$prevV = $null; $prevL = $null
foreach ($seq in ($viewer.Keys | Sort-Object | Select-Object -Skip $Skip -First $Count)) {
    $v = $viewer[$seq]
    $gv = if ($null -ne $prevV) { "{0,7:N1}" -f ($v[0] - $prevV) } else { "" }
    $gl = if ($null -ne $prevL -and $send.ContainsKey($seq)) { "{0,7:N1}" -f ($send[$seq] - $prevL) } else { "" }
    $sa = if ($send.ContainsKey($seq) -and $ack.ContainsKey($seq)) { "{0,7:N1}" -f ($ack[$seq] - $send[$seq]) } else { "   n/a" }
    "{0,3} | {1} | {2,7:N2} | {3} | {4}" -f $seq, $sa, ($v[1] - $v[0]), $gv, $gl
    $prevV = $v[0]; if ($send.ContainsKey($seq)) { $prevL = $send[$seq] }
}
