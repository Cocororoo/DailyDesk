[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunDir)
$ErrorActionPreference = 'Stop'
$metadata = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $RunDir 'run-metadata.json') -Raw | ConvertFrom-Json
$evidence = Join-Path $RunDir 'evidence'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$monitorPath = Join-Path $RunDir 'monitor-outcome.json'
$monitor = if (Test-Path -LiteralPath $monitorPath) { Get-Content -Encoding UTF8 -LiteralPath $monitorPath -Raw | ConvertFrom-Json } else { $null }
$ended = $monitor -and $monitor.outcome -eq 'native-run-ended'
$exited = $monitor -and $monitor.outcome -eq 'maaend-exited-before-verification'
$closed = $ended -or $exited
$previousResult=$null
$previousResultPath=Join-Path $RunDir 'result.json'
if(Test-Path -LiteralPath $previousResultPath){$previousResult=Get-Content -Raw -Encoding UTF8 -LiteralPath $previousResultPath|ConvertFrom-Json}
# A progress inspection also writes result.json. Only a prior terminal collection
# freezes evidence; the first closed inspection must still collect the final log tail.
$alreadyCollected=$closed -and $previousResult -and $previousResult.monitor_outcome -in @('native-run-ended','maaend-exited-before-verification')
$evidenceFrozenAt=if($closed){if($alreadyCollected -and $previousResult.evidence_frozen_at){$previousResult.evidence_frozen_at}else{(Get-Date).ToString('o')}}else{$null}
$apiAvailable = $false
$state = $null
$stateSource = 'unavailable'
if ($closed) {
    # The live instance may already contain a later retry. Use this run's saved
    # terminal snapshot, never another run's statuses or new log bytes.
    foreach ($name in @('native-state-final.json','native-state-latest.json','evidence\maa-state.json')) {
        $savedPath = Join-Path $RunDir $name
        if (Test-Path -LiteralPath $savedPath) {
            $state = Get-Content -Encoding UTF8 -LiteralPath $savedPath -Raw | ConvertFrom-Json
            $stateSource = $name
            break
        }
    }
}
foreach ($endpoint in $(if($closed){@()}else{@('maa/state','logs')})) {
    try {
        # Windows PowerShell 5.1 otherwise decodes charset-less JSON as Latin-1.
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($metadata.api_base + '/api/' + $endpoint) -TimeoutSec 4
        $response.RawContentStream.Position = 0
        $reader = New-Object IO.StreamReader($response.RawContentStream,[Text.Encoding]::UTF8,$true,1024,$true)
        try { $data = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if (-not $alreadyCollected) {
            $data | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $evidence ($endpoint.Replace('/','-') + '.json')) -Encoding UTF8
        }
        if ($endpoint -eq 'maa/state') {
            $apiAvailable=$true
            if (-not $ended) { $state=$data; $stateSource='live-api' }
        }
    } catch { Write-Verbose $_.Exception.Message }
}
$deltaFiles = @()
$logRoot = Join-Path $metadata.maaend_root 'debug'
$startUtc = ([datetimeoffset]$metadata.started_at).UtcDateTime
$filesToCollect = if ($alreadyCollected) { @() } else { @(Get-ChildItem -LiteralPath $logRoot -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue) }
foreach ($file in $filesToCollect) {
    $baseline = $metadata.log_baselines | Where-Object path -eq $file.FullName | Select-Object -First 1
    $offset = 0L
    $baselineCreationTicks = if ($baseline.created_utc_ticks) { [long]$baseline.created_utc_ticks }
        elseif ($baseline) { ([datetimeoffset]$baseline.created_utc).UtcDateTime.Ticks } else { 0L }
    if ($baseline -and $file.Length -ge $baseline.length -and $file.CreationTimeUtc.Ticks -eq $baselineCreationTicks) {
        $offset = [long]$baseline.length
    } elseif ($file.LastWriteTimeUtc -lt $startUtc) { continue }
    if ($file.Length -le $offset) { continue }
    $relativeLogPath = $file.FullName.Substring($logRoot.TrimEnd('\').Length).TrimStart('\')
    $destination = Join-Path $evidence ($relativeLogPath + '.delta.log')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    $source = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$source.Seek($offset, [System.IO.SeekOrigin]::Begin)
        $target = [System.IO.File]::Create($destination)
        try { $source.CopyTo($target) } finally { $target.Dispose() }
    } finally { $source.Dispose() }
    $deltaFiles += $destination
}
# Retain captured rotations even if the native logger has since removed its copy.
$deltaFiles = @(Get-ChildItem -LiteralPath $evidence -Filter '*.delta.log' -File -Recurse | ForEach-Object FullName)
$runtime = if ($state) { $state.instances.($metadata.instance_id) } else { $null }
# Automatic launches and explicitly observed native UI starts both need this run's trace.
$hasNativeStart = $false
$startReceiptPath = Join-Path $RunDir 'native-start-receipt.json'
if (Test-Path -LiteralPath $startReceiptPath) {
    $startReceipt = Get-Content -Encoding UTF8 -LiteralPath $startReceiptPath -Raw | ConvertFrom-Json
    $startRuntime = $startReceipt.state.instances.($metadata.instance_id)
    $hasNativeStart = $startReceipt.instance_id -eq $metadata.instance_id -and
        [datetimeoffset]$startReceipt.observed_at -ge [datetimeoffset]$metadata.started_at -and
        $startRuntime.is_running -and
        @($metadata.expected_tasks | Where-Object { $startRuntime.task_run_state.statuses.($_.id) -eq 'running' }).Count -gt 0
}
$hasRunTrace = ($metadata.launched -or $hasNativeStart) -and (Test-Path -LiteralPath (Join-Path $RunDir 'state-history.jsonl'))
Import-Module (Join-Path $PSScriptRoot 'MaaEndTerminalEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MaaEndStartupEvidence.psm1') -Force
$hasFailedTask = $runtime -and @($metadata.expected_tasks | Where-Object {
    $runtime.task_run_state.statuses.($_.id) -eq 'failed'
}).Count -gt 0
$framework=if($hasRunTrace -and ($exited -or ($ended -and $hasFailedTask))){Get-MaaEndFrameworkTaskEvidence -Metadata $metadata -State $state -DeltaFiles $deltaFiles -FinishedAt ([datetimeoffset]$monitor.at)}else{$null}
$recovered=$exited -and $framework -and $framework.AllSucceeded -and $metadata.quit_after_run
$startupBlock = if ($framework -and !$framework.AllSucceeded) { Get-MaaEndStartupBlock -FrameworkEvidence $framework }
if($framework){$framework|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $RunDir 'framework-terminal-evidence.json') -Encoding UTF8}
$perTask = @(foreach ($task in $metadata.expected_tasks) {
    $status = if ($hasRunTrace -and $runtime) { $runtime.task_run_state.statuses.($task.id) } else { $null }
    $verifiedEvent=@($framework.PerTask|Where-Object{$_.id -eq $task.id -and $_.status -in @('succeeded','failed')})|Select-Object -Last 1
    if($verifiedEvent){$status=$verifiedEvent.status}
    [ordered]@{id=$task.id; task=$task.taskName; status=$(if($status){$status}else{'unverified'})}
})
$overallStatus = if ($runtime) { $runtime.task_run_state.overall_status } else { $null }
if($recovered){$overallStatus='Succeeded';$stateSource='current-run-framework-events'}
$subtaskFailures = @(foreach ($file in $deltaFiles) {
    if ((Split-Path $file -Leaf) -ne 'go-service.log.delta.log') { continue }
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($file)) {
        $lineNumber++
        if ($line -notmatch 'FailureCollector (recovery )?subtask failed') { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.level -ne 'error') { continue }
        [ordered]@{task=$event.task; at=$event.time; message=$event.message; file=$file; line=$lineNumber}
    }
})
$plannedSkips = @(foreach ($file in $deltaFiles) {
    if ((Split-Path $file -Leaf) -ne 'go-service.log.delta.log') { continue }
    $lineNumber=0
    foreach ($line in [IO.File]::ReadLines($file)) {
        $lineNumber++
        if ($line -notmatch 'today is not in schedule, skip task') { continue }
        try { $event=$line|ConvertFrom-Json; $at=[datetimeoffset]$event.time } catch { continue }
        if ($event.component -ne 'ScheduleRecognition' -or $event.node -ne 'AutoCollectScheduleEnabled' -or
            $event.message -ne 'today is not in schedule, skip task' -or $at -lt [datetimeoffset]$metadata.started_at -or
            !$monitor.at -or $at -gt [datetimeoffset]$monitor.at) { continue }
        if (!@($perTask|Where-Object{$_.task -eq 'AutoCollect' -and $_.status -eq 'succeeded'}).Count) { continue }
        [ordered]@{task='AutoCollect';reason='not-in-weekly-schedule';weekday=$event.weekday;at=$event.time;file=$file;line=$lineNumber}
    }
})
$nativeComplete = $hasRunTrace -and $runtime -and (-not $runtime.is_running -or $recovered) -and
    ($monitor.outcome -eq 'native-run-ended' -or $recovered) -and $perTask.Count -gt 0 -and
    $overallStatus -eq 'Succeeded' -and $subtaskFailures.Count -eq 0 -and
    @($perTask | Where-Object status -ne 'succeeded').Count -eq 0
$review = [ordered]@{
    sanity_before=$null; sanity_after=$null
    medication_before=$null; medication_after=$null
    engraving_permits_before=$null; engraving_permits_after=$null
    essence_reward_verified=$false
    dijiang_intel_forge_cultivation_verified=$false
    wuling_trading_vouchers_verified=$false
    credit_shopping_verified=$false
    daily_and_pass_rewards_verified=$false
    evidence_notes=''
}
$reviewPath = Join-Path $RunDir 'resource-and-reward-review.json'
if (-not (Test-Path -LiteralPath $reviewPath)) { $review | ConvertTo-Json | Set-Content -LiteralPath $reviewPath -Encoding UTF8 }
$result = [ordered]@{
    checked_at=(Get-Date).ToString('o')
    evidence_frozen_at=$evidenceFrozenAt
    run_dir=$RunDir
    api_available=$apiAvailable
    task_state_source=$stateSource
    terminal_recovered_from_framework_events=[bool]$recovered
    current_run_trace_present=[bool]$hasRunTrace
    native_overall_status=$overallStatus
    observed_subtask_failures=$subtaskFailures
    startup_block=$startupBlock
    planned_skips=$plannedSkips
    native_tasks_complete=[bool]$nativeComplete
    monitor_outcome=$(if($monitor){$monitor.outcome}else{'not-monitored'})
    per_task=$perTask
    current_log_deltas=$deltaFiles
    resource_policy=$metadata.resource_policy
    manual_review_required=$true
    review_file=$reviewPath
    review_reason='Check native success against resource and reward evidence. A process exit or old success log is insufficient.'
}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $RunDir 'result.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 12
