[CmdletBinding()]
param(
    [ValidateSet('All','Genshin','StarRail','Endfield')][string]$Game = 'All',
    [string]$ConfigPath,
    [string]$ResumeRunDirectory,
    [string]$ControlDirectory,
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
$config = Read-DailyConfig $ConfigPath
$ConfigPath = $config.ConfigPath
$sequence = if ($Game -eq 'All') { @($config.Sequence) } else { @($Game) }
if ($Game -ne 'All' -and $Game -notin $config.Sequence) { throw "$Game is not configured." }
$adapters = Join-Path (Split-Path $PSScriptRoot -Parent) 'adapters'
$genshinScripts = if ($config.Genshin.LocalScripts) { $config.Genshin.LocalScripts } else { Join-Path $adapters 'genshin' }
$entries = @{
    Genshin = Join-Path $genshinScripts 'Invoke-BetterGIDailySession.ps1'
    StarRail = Join-Path $adapters 'starrail\Invoke-StarRailDailySession.ps1'
    Endfield = Join-Path $adapters 'endfield\Invoke-MaaEndDailySession.ps1'
}
function Get-AdapterArguments($Name) {
    $settings = $config.$Name
    $data = Join-Path $config.DataRoot $Name
    switch ($Name) {
        'Genshin' {
            if ($settings.LocalScripts) {
                @{BgiRoot=$settings.Directory; AutomationDisplayMode=$(if($settings.AutomationFullscreen){'Fullscreen'}else{'Windowed'})}
            } else {
                @{BgiRoot=$settings.Directory; Profile=$settings.Profile; ManageDisplay=[bool]$settings.ManageDisplay; AutomationWidth=[int]$settings.AutomationWidth; AutomationHeight=[int]$settings.AutomationHeight; AutomationFullscreen=[bool]$settings.AutomationFullscreen; DataDirectory=$data; GameDay=(Get-DailyGameDay $config).DayOfWeek.ToString()}
            }
        }
        'StarRail' { @{InstallDirectory=$settings.Directory; DataDirectory=$data} }
        'Endfield' { @{MaaRoot=$settings.Directory; InstanceName=$settings.Instance; ApiPort=$settings.ApiPort; DataDirectory=$data} }
    }
}
function Test-NativeCompletion($Name, $Result, $Session, $EvidenceDirectory) {
    switch ($Name) {
        'Genshin' {
            $unexpected = @($Result.Issues | Where-Object {$_ -notmatch '未检测到退出按钮.*跳过本轮奖励识别'})
            return [bool]($Session.NativeEnded -and $Session.GameClosed -and $Session.BetterGIClosed -and $Session.DisplayPreferenceRestored -and $Result.NativeEnded -and $Result.ProfileStarted -and $Result.ResinExhausted -and $Result.DailyRewardClaimed -and !$unexpected.Count)
        }
        'StarRail' {
            $rewardResolved = $Result.DailyRewardClaimVerifiedInLog -or ($Result.Daily500Observed -and $Result.DailyRewardNotAvailableObserved)
            $powerResolved = $Result.PowerStopEvidence -or $Result.PowerBelowInstanceCostObserved
            return [bool]($Result.NativeTasksSucceeded -and $Result.GameClosed -and $rewardResolved -and $powerResolved -and !@($Result.Issues | Where-Object {$_}).Count)
        }
        'Endfield' {
            $exitReceiptPath = Join-Path $EvidenceDirectory 'assistant-exit-receipt.json'
            if (!(Test-Path -LiteralPath $exitReceiptPath)) { return $false }
            $exitReceipt = Get-Content -LiteralPath $exitReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            return [bool]($Result.native_tasks_complete -and $exitReceipt.quit_after_run_requested -and $exitReceipt.maaend_exited)
        }
    }
    return $false
}
$resumeState = $null
$completedPrefix = @()
if ($ResumeRunDirectory) {
    if ($Game -ne 'All') { throw 'Resume uses the original full sequence; omit -Game.' }
    $ResumeRunDirectory = (Resolve-Path -LiteralPath $ResumeRunDirectory).Path
    $resumeState = Get-Content -LiteralPath (Join-Path $ResumeRunDirectory 'suite-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($resumeState.Schema -ne 'three-game-daily-suite-v1' -or ($resumeState.Sequence -join ',') -ne ($sequence -join ',')) { throw 'Resume manifest does not match this suite.' }
    if ((Get-DailyGameDay $config).Date -ne (Get-DailyGameDay $config ([datetimeoffset]$resumeState.StartedAt)).Date) {
        throw 'Cannot resume a previous game day; start a fresh suite.'
    }
    $seen=@()
    foreach ($savedStage in $resumeState.Stages) {
        if ($savedStage.Game -notin $sequence -or $savedStage.Game -in $seen) { throw 'Invalid or duplicate saved stage; resume refused.' }
        $seen+=@($savedStage.Game)
        if ($savedStage.Status -ne 'native_completed_requires_reward_review') { continue }
        if (!$savedStage.NativeCompleted -or !$savedStage.ResultFile -or !(Test-Path -LiteralPath $savedStage.ResultFile -PathType Leaf)) {
            throw 'Saved completion evidence is missing; resume refused.'
        }
        $savedResult = Get-Content -LiteralPath $savedStage.ResultFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $savedSession = if ($savedStage.Game -eq 'Genshin') {
            Get-Content -LiteralPath (Join-Path $savedStage.EvidenceDirectory 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (!(Test-NativeCompletion $savedStage.Game $savedResult $savedSession $savedStage.EvidenceDirectory)) {
            throw 'Saved completion evidence failed verification; resume refused.'
        }
        $completedPrefix += $savedStage
    }
    if ($completedPrefix.Count -eq $sequence.Count) { throw 'This suite is already complete; no stage was started.' }
    $sequence = @($sequence | Where-Object {$_ -notin @($completedPrefix | ForEach-Object {$_.Game})})
}
function Test-SuiteReady([string[]]$Names = $sequence) {
    $items = @(foreach ($name in $Names) {
        if (!(Test-Path -LiteralPath $entries[$name])) { [pscustomobject]@{Game=$name;Ready=$false;Reason='Entry script missing';Detail=$entries[$name]}; continue }
        try {
            $arguments = Get-AdapterArguments $name
            $detail = & $entries[$name] @arguments -PreflightOnly
            $ready = [bool]$detail.Ready
            [pscustomobject]@{Game=$name;Ready=$ready;Reason=$(if($ready){''}else{'Native preflight needs attention'});Detail=$detail}
        } catch {
            # Parser messages may include an entire native config. Keep the entry readable.
            $reason = ($_.Exception.Message -split '\r?\n')[0]
            if ($reason.Length -gt 300) { $reason = $reason.Substring(0,300) + '…' }
            [pscustomobject]@{Game=$name;Ready=$false;Reason=$reason;Detail=$null}
        }
    })
    $conflicts = @(Get-DailyProcesses)
    [pscustomobject]@{Ready=(@($items | Where-Object {!$_.Ready}).Count -eq 0 -and $conflicts.Count -eq 0);Checks=$items;ConflictingProcesses=@($conflicts | Select-Object ProcessName,Id)}
}
if ($PreflightOnly) { Test-SuiteReady; return }
$mutex = New-Object Threading.Mutex($false,'Local\ThreeGameDailyAutomation')
$locked = $false
$runDirectory = $null
$state = $null
function Save-Suite {
    $path=Join-Path $runDirectory 'suite-result.json'
    $temp=$path+'.tmp'
    [IO.File]::WriteAllText($temp,($state | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
}
function Test-Cancellation {
    if($ControlDirectory -and (Test-Path -LiteralPath (Join-Path $ControlDirectory 'cancel-request.json'))){throw [OperationCanceledException]::new('User closed the daily window.')}
}
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another integrated daily entry is running. Duplicate launch refused.' }
    if (@(Get-DailyProcesses).Count) { throw 'A game or automation process is already active; daily sequence was not started.' }
    Test-Cancellation
    if ($resumeState) {
        $runDirectory = $ResumeRunDirectory
        $attemptDirectory = Join-Path $runDirectory 'attempts'
        New-Item -ItemType Directory -Path $attemptDirectory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $runDirectory 'suite-result.json') -Destination (Join-Path $attemptDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-before-resume.json'))
        $state = $resumeState
        $state.Stages = @($completedPrefix); $state.Status = 'running'; $state.Error = $null; $state.FinishedAt = $null
        $state | Add-Member NoteProperty ResumedAt (Get-Date).ToString('o') -Force
    } else {
        $runDirectory = Join-Path $config.RunRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $state = [pscustomobject][ordered]@{Schema='three-game-daily-suite-v1';StartedAt=(Get-Date).ToString('o');FinishedAt=$null;Status='running';Sequence=$sequence;Stages=@();Error=$null;RewardReviewRequired=$true}
    }
    Save-Suite
    if($ControlDirectory){[IO.File]::WriteAllText((Join-Path $ControlDirectory 'suite-run.txt'),$runDirectory,(New-Object Text.UTF8Encoding($false)))}
    foreach ($name in $sequence) {
        Test-Cancellation
        if (@(Get-DailyProcesses).Count) { throw 'A game or automation process is still active; next stage was not started.' }
        $stage = [pscustomobject][ordered]@{Game=$name;StartedAt=(Get-Date).ToString('o');FinishedAt=$null;Status='running';EvidenceDirectory=$null;ResultFile=$null;NativeCompleted=$false;RewardReviewRequired=$true;Error=$null}
        $state.Stages += $stage
        Save-Suite
        if($ControlDirectory){[IO.File]::WriteAllText((Join-Path $ControlDirectory 'current-stage.txt'),$name,(New-Object Text.UTF8Encoding($false)))}
        $ready = Test-SuiteReady -Names @($name)
        if ($ready.ConflictingProcesses.Count) { throw 'A game or automation process became active during preflight; no stage was started.' }
        if (!$ready.Ready) {
            $check = @($ready.Checks | Where-Object {$_.Game -eq $name}) | Select-Object -First 1
            $stage.Status = 'preflight_failed'
            $stage.Error = 'Daily preflight failed: ' + $check.Reason
            if ($check.Detail -and $check.Detail.Problems) { $stage.Error += ' | ' + ($check.Detail.Problems -join ' | ') }
            $stage.FinishedAt = (Get-Date).ToString('o')
            Save-Suite
            continue
        }
        Test-Cancellation
        $stageLog = Join-Path $runDirectory ($name + '.log')
        $entryArgs = Get-AdapterArguments $name
        if ($name -eq 'Endfield') { $entryArgs.QuitAfterRun = $true }
        $entryFailure=$null
        try {
        & $entries[$name] @entryArgs *>&1 | ForEach-Object {
            $_ | Out-File -LiteralPath $stageLog -Append -Encoding UTF8
            if ($_ -is [string]) {
                try { $item = $_ | ConvertFrom-Json -ErrorAction Stop } catch { $item = $null }
            } else { $item = $_ }
            if ($item -and $item.SessionDirectory) { $stage.EvidenceDirectory = [string]$item.SessionDirectory; Save-Suite }
            if ($item -and $item.run_dir) { $stage.EvidenceDirectory = [string]$item.run_dir; Save-Suite }
            if ($_ -is [Management.Automation.ErrorRecord]) { throw $_ }
        }
        } catch { $entryFailure=$_ }
        Test-Cancellation
        if($entryFailure){
            # Only the wrapper's explicit terminal-native-failure receipt is eligible.
            # Unknown script exceptions, absent evidence and cancellation still abort.
            $terminalFailure=$false
            if($name -eq 'StarRail' -and $stage.EvidenceDirectory -and $entryFailure.Exception.Message -match '^StarRail daily needs attention: .*Native task or game exit was not verified; review '){
                $failedSession=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stage.EvidenceDirectory 'session.json')|ConvertFrom-Json
                $failedResult=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stage.EvidenceDirectory 'result.json')|ConvertFrom-Json
                $terminalFailure=$failedSession.Status -eq 'needs_attention' -and $failedResult.NativeStatus -eq 'failed' -and $failedResult.NativeRecordMatchesSession -and
                    $failedSession.NativeRunId -and $failedResult.NativeRunId -eq $failedSession.NativeRunId -and
                    $null -ne $failedResult.ExitCode -and [int]$failedResult.ExitCode -ne 0 -and $failedResult.GameClosed -and !@(Get-DailyProcesses).Count
            }
            if(!$terminalFailure){throw $entryFailure}
            $stage | Add-Member NoteProperty EntryError $entryFailure.Exception.Message -Force
        }
        if (!$stage.EvidenceDirectory) { throw ('No session evidence directory was returned for ' + $name) }
        $resultPath = Join-Path $stage.EvidenceDirectory 'result.json'
        if ($name -eq 'Genshin') {
            $session = Get-Content -LiteralPath (Join-Path $stage.EvidenceDirectory 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if (!$session.RunDirectory) { throw 'Genshin session has no native run directory.' }
            $resultPath = Join-Path $session.RunDirectory 'result.json'
        }
        $stage.ResultFile = $resultPath
        $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $stage.NativeCompleted = Test-NativeCompletion $name $result $session $stage.EvidenceDirectory
        # Never overlap game processes, including after the final stage.
        $remainingGames = @(Get-Process -Name YuanShen,GenshinImpact,StarRail,Endfield -ErrorAction SilentlyContinue)
        if ($remainingGames.Count) { throw ('Game did not exit after ' + $name + '; no next stage will start.') }
        if ($name -eq 'Endfield' -and (Get-Process -Name MaaEnd -ErrorAction SilentlyContinue)) {
            throw 'MaaEnd did not exit after its native --quit-after-run request; the suite is complete only after this process exits.'
        }
        if ($name -eq 'Endfield') {
            $exitReceiptPath = Join-Path $stage.EvidenceDirectory 'assistant-exit-receipt.json'
            if (!(Test-Path -LiteralPath $exitReceiptPath)) { throw 'MaaEnd exit receipt is missing; the Endfield stage is not complete.' }
            $exitReceipt = Get-Content -LiteralPath $exitReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (!$exitReceipt.quit_after_run_requested -or !$exitReceipt.maaend_exited) { throw 'MaaEnd exit receipt did not verify a native --quit-after-run exit.' }
            $stage | Add-Member NoteProperty AssistantExited $true -Force
        }
        # A returned, normally ended session may have incomplete rewards. Record it
        # separately and continue only after both receipt and live process checks.
        $exitVerified=switch($name){
            'Genshin' { [bool]($session.NativeEnded -and $session.GameClosed -and $session.BetterGIClosed -and $session.DisplayPreferenceRestored -and $result.ProfileStarted -and $result.NativeEnded) }
            'StarRail' { [bool]$result.GameClosed }
            'Endfield' { [bool]($exitReceipt.quit_after_run_requested -and $exitReceipt.maaend_exited) }
        }
        if (!$exitVerified -or @(Get-DailyProcesses).Count) { throw ('Safe exit was not verified after '+$name+'; no next stage will start.') }
        $stage | Add-Member NoteProperty ExitVerified $true -Force
        if($stage.NativeCompleted){
            $stage.Status='native_completed_requires_reward_review'
        }else{
            $stage.Status='incomplete_closed'
            $stage.Error='Native daily checks incomplete; applications exited safely. Review '+$resultPath
        }
        $stage.FinishedAt=(Get-Date).ToString('o')
        Save-Suite
    }
    $state.Stages=@(foreach($orderedGame in $state.Sequence){$state.Stages|Where-Object{$_.Game -eq $orderedGame}})
    $incomplete=@($state.Stages|Where-Object{!$_.NativeCompleted})
    if($incomplete.Count){throw ('Daily sequence finished with incomplete games: '+(($incomplete|ForEach-Object{$_.Game}) -join ', ')+'. Other safely closed games were allowed to finish.')}
    $state.Status='native_sequence_completed_requires_reward_review'
    $state.FinishedAt=(Get-Date).ToString('o')
    Save-Suite
    [pscustomobject]@{RunDirectory=$runDirectory;Status=$state.Status;Stages=$state.Stages}
} catch {
    if ($state) {
        $state.Status='needs_attention'; $state.Error=$_.Exception.Message; $state.FinishedAt=(Get-Date).ToString('o')
        if ($state.Stages.Count -and $state.Stages[-1].Status -eq 'running') { $state.Stages[-1].Status='failed_or_interrupted'; $state.Stages[-1].Error=$state.Error; $state.Stages[-1].FinishedAt=$state.FinishedAt }
        if($ControlDirectory -and (Test-Path -LiteralPath (Join-Path $ControlDirectory 'cancel-request.json'))){$state.Status='cancelled';if($state.Stages.Count -and !$state.Stages[-1].NativeCompleted){$state.Stages[-1].Status='cancelled'}}
        Save-Suite
    }
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
