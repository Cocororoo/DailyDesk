[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MaaRoot,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$DataDirectory,
    [ValidateRange(1024,65535)][int]$ApiPort = 12701,
    [ValidateRange(60,14400)][int]$TimeoutSeconds = 10800,
    [switch]$PreflightOnly,
    [switch]$QuitAfterRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../runner/Configuration.psm1') -Force
$script = Join-Path $PSScriptRoot 'Start-MaaEndDaily.ps1'
$startArgs = @{MaaRoot=$MaaRoot;InstanceName=$InstanceName;DataDirectory=$DataDirectory;ApiPort=$ApiPort;QuitAfterRun=[bool]$QuitAfterRun}
if ($PreflightOnly) { return (& $script @startArgs -PreflightOnly) }
& $script @startArgs | ForEach-Object { $runDir = $_.run_dir; $_ }
$metadata = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $runDir 'run-metadata.json') -Raw | ConvertFrom-Json
$watcherScript = Join-Path $PSScriptRoot 'Watch-MaaEndEvidence.ps1'
$watcherArguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RunDir "{1}" -TimeoutSeconds {2}' -f $watcherScript,$runDir,$TimeoutSeconds
$watcher = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $watcherArguments -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $runDir 'evidence-watcher.stdout.log') -RedirectStandardError (Join-Path $runDir 'evidence-watcher.stderr.log')
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$startDeadline = (Get-Date).AddMinutes(5)
$seenRunning = $false
$runtime = $null
$lastStatus = ''
$missingProcessPolls = 0
$monitorOutcome = 'timeout'
try {
    while ((Get-Date) -lt $deadline) {
        if (Get-Process MaaEnd -ErrorAction SilentlyContinue) { $missingProcessPolls = 0 } else { $missingProcessPolls++ }
        $state = $null
        try { $state = Invoke-RestMethod ($metadata.api_base + '/api/maa/state') -TimeoutSec 4 } catch { Write-Verbose $_.Exception.Message }
        if ($state) {
            $runtime = $state.instances.($metadata.instance_id)
            if ($runtime) {
                Write-DailyJson (Join-Path $runDir 'native-state-latest.json') $state
                $active = @($metadata.expected_tasks | Where-Object { $runtime.task_run_state.statuses.($_.id) -eq 'running' })
                if ($runtime.is_running -and $active.Count) { $seenRunning = $true }
                $status = $runtime.task_run_state.statuses | ConvertTo-Json -Compress
                if ($status -ne $lastStatus) {
                    @{at=(Get-Date).ToString('o');running=$runtime.is_running;statuses=$runtime.task_run_state.statuses} |
                        ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $runDir 'state-history.jsonl') -Encoding UTF8
                    Write-Verbose $status
                    $lastStatus = $status
                }
                if ($seenRunning -and !$runtime.is_running) {
                    $monitorOutcome = 'native-run-ended'
                    Write-DailyJson (Join-Path $runDir 'native-state-final.json') $state
                    break
                }
            }
        }
        if ($missingProcessPolls -ge 3) {
            $monitorOutcome = 'maaend-exited-before-verification'
            break
        }
        if (!$seenRunning -and (Get-Date) -ge $startDeadline) {
            $monitorOutcome = 'native-start-timeout'
            break
        }
        Start-Sleep -Seconds 5
    }
} finally {
    if (!$watcher.HasExited) {
        if (!$watcher.WaitForExit(12000)) { $watcher.Kill(); $null=$watcher.WaitForExit(2000) }
    }
}
Write-DailyJson (Join-Path $runDir 'monitor-outcome.json') @{at=(Get-Date).ToString('o');outcome=$monitorOutcome;seen_running=$seenRunning}
$result = & (Join-Path $PSScriptRoot 'Get-MaaEndDailyResult.ps1') -RunDir $runDir | ConvertFrom-Json
$exitDeadline = (Get-Date).AddSeconds(20)
if ($QuitAfterRun -and $monitorOutcome -eq 'native-run-ended') {
    while ((Get-Process MaaEnd -ErrorAction SilentlyContinue) -and (Get-Date) -lt $exitDeadline) { Start-Sleep -Milliseconds 250 }
}
Write-DailyJson (Join-Path $runDir 'assistant-exit-receipt.json') @{
    at=(Get-Date).ToString('o');quit_after_run_requested=[bool]$QuitAfterRun
    native_tasks_complete=[bool]$result.native_tasks_complete
    maaend_exited=!(Get-Process MaaEnd -ErrorAction SilentlyContinue)
}
[pscustomobject]@{run_dir=$runDir;Result=$result}
