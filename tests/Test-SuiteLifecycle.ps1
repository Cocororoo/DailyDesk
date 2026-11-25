$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $project 'runner/Configuration.psm1') -Force
$fixture = New-DailyRunDirectory ([IO.Path]::GetTempPath())
try {
    Copy-Item -LiteralPath (Join-Path $project 'runner') -Destination $fixture -Recurse
    $adapters = Join-Path $fixture 'adapters'
    $native = @'
param([switch]$PreflightOnly, [switch]$QuitAfterRun, [string]$DataDirectory, [string]$AutomationDisplayMode)
$kind = switch -Wildcard ($MyInvocation.MyCommand.Name) {
    '*BetterGI*' { 'Genshin' }
    '*StarRail*' { 'StarRail' }
    '*MaaEnd*' { 'Endfield' }
}
if ($kind -eq 'Genshin' -and $AutomationDisplayMode -ne 'Windowed') { throw 'Local adapter arguments were not passed.' }
if ($PreflightOnly) { [pscustomobject]@{Ready=$true}; return }
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$log = Join-Path $root 'stage-events.txt'
Add-Content -LiteralPath $log -Value "$($kind):start"
$dir = Join-Path $root ('data/' + $kind)
New-Item -ItemType Directory -Path $dir -Force | Out-Null
switch ($kind) {
    'Genshin' {
        [pscustomobject]@{SessionDirectory=$dir}
        @{RunDirectory=$dir;NativeEnded=$true;GameClosed=$true;BetterGIClosed=$true;DisplayPreferenceRestored=$true} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'session.json') -Encoding UTF8
        $result = @{ProfileStarted=$true;NativeEnded=$true;DailyRewardClaimed=$true;ResinExhausted=$true;Issues=@()}
    }
    'StarRail' {
        [pscustomobject]@{SessionDirectory=$dir}
        $result = @{NativeTasksSucceeded=$true;GameClosed=$true;DailyRewardClaimVerifiedInLog=$true;PowerStopEvidence=$true;Issues=@()}
    }
    'Endfield' {
        [pscustomobject]@{run_dir=$dir}
        if (!$QuitAfterRun) { throw 'Native quit-after-run flag was omitted.' }
        @{quit_after_run_requested=$true;maaend_exited=$true} | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $dir 'assistant-exit-receipt.json') -Encoding UTF8
        $result = @{native_tasks_complete=$true}
    }
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding UTF8
Add-Content -LiteralPath $log -Value "$($kind):end"
if ($kind -eq 'Genshin' -and (Test-Path -LiteralPath (Join-Path $root 'cancel-control.txt'))) {
    $control = [IO.File]::ReadAllText((Join-Path $root 'cancel-control.txt'))
    [IO.File]::WriteAllText((Join-Path $control 'cancel-request.json'), '{}')
}
'@
    foreach ($entry in @('genshin/Invoke-BetterGIDailySession.ps1','starrail/Invoke-StarRailDailySession.ps1','endfield/Invoke-MaaEndDailySession.ps1')) {
        $target = Join-Path $adapters $entry
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Set-Content -LiteralPath $target -Value $native -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $adapters 'genshin/Get-BetterGIDailyResult.ps1') -Value 'param([string]$RunDirectory)' -Encoding UTF8
    $config = Join-Path $fixture 'config.local.json'
    Write-DailyJson $config @{
        SchemaVersion=1; DataDirectory='data'; GameTimeZone='China Standard Time'; ResetHour=4
        Sequence=@('Genshin','StarRail','Endfield')
        Genshin=@{Directory='apps/BetterGI';LocalScripts='adapters/genshin'}
        StarRail=@{Directory='apps/March7th'}
        Endfield=@{Directory='apps/MaaEnd';Instance='Daily';ApiPort=12701}
    }
    $entry = Join-Path $fixture 'runner/Invoke-GameDailySuite.ps1'
    $control = (New-Item -ItemType Directory -Path (Join-Path $fixture 'control')).FullName
    $suite = & $entry -ConfigPath $config -ControlDirectory $control
    if ($suite.Status -ne 'native_sequence_completed_requires_reward_review' -or @($suite.Stages | Where-Object { !$_.ExitVerified }).Count) {
        throw 'Suite did not verify each stage and exit.'
    }
    $events = Join-Path $fixture 'stage-events.txt'
    if ((Get-Content -LiteralPath $events) -join ',' -ne 'Genshin:start,Genshin:end,StarRail:start,StarRail:end,Endfield:start,Endfield:end') {
        throw 'The three games did not run in sequence.'
    }
    & (Join-Path $fixture 'runner/Get-GameDailyReport.ps1') -ConfigPath $config -ControlDirectory $control | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $control 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.Games.Count -ne 3 -or $report.ReadErrors.Count) { throw 'Suite report is incomplete.' }

    Clear-Content -LiteralPath $events
    [IO.File]::WriteAllText((Join-Path $fixture 'cancel-control.txt'), $control)
    $cancelled = $false
    try { & $entry -ConfigPath $config -ControlDirectory $control | Out-Null }
    catch {
        $exception = $_.Exception
        while ($exception) {
            if ($exception -is [OperationCanceledException]) { $cancelled = $true; break }
            $exception = $exception.InnerException
        }
    }
    if (!$cancelled -or (Get-Content -LiteralPath $events) -join ',' -ne 'Genshin:start,Genshin:end') {
        throw 'Cancellation did not prevent later games from starting.'
    }
    Write-Output 'Verified all three stages, local Genshin integration, report and cancellation.'
} finally {
    $path = (Resolve-Path -LiteralPath $fixture).Path
    $temp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path.TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($path) -eq $temp -and (Split-Path $path -Leaf) -match '^\d{8}-\d{6}-\d{3}-[a-f0-9]{6}$') {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
