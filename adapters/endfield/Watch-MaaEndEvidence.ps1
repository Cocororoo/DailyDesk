[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunDir,
    [ValidateRange(10,300)][int]$ScreenshotIntervalSeconds = 30,
    [ValidateRange(30,14400)][int]$TimeoutSeconds = 10800
)
$ErrorActionPreference = 'Stop'
$metadata = Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $RunDir 'run-metadata.json') | ConvertFrom-Json
$directory = Join-Path $RunDir 'evidence\screenshots'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$lastCapture = [datetime]::MinValue
$lastStatus = ''
$ready = $false
while (-not $ready -and (Get-Date) -lt $deadline) {
    try {
        $state = Invoke-RestMethod ($metadata.api_base + '/api/maa/state') -TimeoutSec 4
        $runtime = $state.instances.($metadata.instance_id)
        $currentTasks = @($metadata.expected_tasks | Where-Object {
            $runtime.task_run_state.statuses.($_.id) -eq 'running'
        })
        $ready = $runtime -and $runtime.resource_loaded -and $runtime.tasker_inited -and
            $runtime.is_running -and $currentTasks.Count -gt 0
    } catch { Write-Verbose $_.Exception.Message }
    if (-not $ready) {
        if (([datetimeoffset]::Now-[datetimeoffset]$metadata.started_at).TotalSeconds -gt 60 -and -not (Get-Process MaaEnd -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 2
    }
}
if (-not $ready) { return }
try {
    # All readers share MXU's screenshot service; this does not send game input.
    $subscription = @{subscriber_id='daily-evidence';interval_ms=1000} | ConvertTo-Json
    Invoke-RestMethod ($metadata.api_base + '/api/maa/instances/' + $metadata.instance_id + '/screenshot/subscribe') `
        -Method Post -ContentType 'application/json' -Body $subscription -TimeoutSec 5 | Out-Null
    while ((Get-Date) -lt $deadline) {
        try {$state = Invoke-RestMethod ($metadata.api_base + '/api/maa/state') -TimeoutSec 5}
        catch {
            if(-not (Get-Process MaaEnd -ErrorAction SilentlyContinue)){break}
            Write-Warning ('Evidence state temporarily unavailable: '+$_.Exception.Message)
            Start-Sleep -Seconds 2
            continue
        }
        $runtime = $state.instances.($metadata.instance_id)
        $status = $runtime.task_run_state.statuses | ConvertTo-Json -Compress
        if ($status -ne $lastStatus -or ((Get-Date)-$lastCapture).TotalSeconds -ge $ScreenshotIntervalSeconds) {
            $tasks = @($metadata.expected_tasks | Where-Object {$runtime.task_run_state.statuses.($_.id) -eq 'running'} | ForEach-Object {$_.taskName})
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $name = $stamp + '-' + $(if($tasks.Count){$tasks -join '_'}else{'idle'}) + '.png'
            $path = Join-Path $directory $name
            try {
                Invoke-WebRequest ($metadata.api_base + '/api/maa/instances/' + $metadata.instance_id + '/screenshot') -OutFile $path -TimeoutSec 12
                [ordered]@{at=(Get-Date).ToString('o');file=$name;running_tasks=$tasks;statuses=$runtime.task_run_state.statuses} |
                    ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath (Join-Path $directory 'index.jsonl') -Encoding UTF8
            } catch { Write-Warning ('Screenshot unavailable: ' + $_.Exception.Message) }
            $lastCapture = Get-Date
        }
        $lastStatus = $status
        if (-not $runtime.is_running) { break }
        Start-Sleep -Seconds 10
    }
} finally {
    try {
        Invoke-RestMethod ($metadata.api_base + '/api/maa/instances/' + $metadata.instance_id + '/screenshot/unsubscribe') `
            -Method Post -ContentType 'application/json' -Body '{"subscriber_id":"daily-evidence"}' -TimeoutSec 5 | Out-Null
    } catch { Write-Verbose $_.Exception.Message }
}
