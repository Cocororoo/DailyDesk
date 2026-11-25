[CmdletBinding()]
param([Parameter(Mandatory)][string]$SessionDirectory)
$ErrorActionPreference = 'Stop'
$SessionDirectory = (Resolve-Path -LiteralPath $SessionDirectory).Path
$session = Get-Content -LiteralPath (Join-Path $SessionDirectory 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedType = if ($session.ExpectedInstanceType) { $session.ExpectedInstanceType } else { '侵蚀隧洞' }
$expectedName = if ($session.ExpectedInstanceName) { $session.ExpectedInstanceName } else { $session.ExpectedCavern }
$record = $null
$log = ''
if ($session.NativeRunId) {
    $recordPath = Join-Path $session.InstallDirectory ('logs\runs\' + $session.NativeRunId + '.json')
    $logPath = [IO.Path]::ChangeExtension($recordPath,'.log')
    if (Test-Path -LiteralPath $recordPath) {
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Copy-Item -LiteralPath $recordPath -Destination (Join-Path $SessionDirectory 'native-run.json') -Force
    }
    if (Test-Path -LiteralPath $logPath) {
        $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        Copy-Item -LiteralPath $logPath -Destination (Join-Path $SessionDirectory 'native-run.log') -Force
    }
}
$powerValues = @([regex]::Matches($log,'开拓力[：:]\s*(\d+)/300') | ForEach-Object { [int]$_.Groups[1].Value })
$lines = $log -split '\r?\n'
$issuePattern = '\|\s*(ERROR|CRITICAL)\s*\||每日实训未完成|清体力未完成|检测到该次副本未正常运行|目标副本识别错误|战斗失败|战斗超时|准备分解四星及以下遗器'
$issues = @($lines | Where-Object { $_ -match $issuePattern })
$recordTimeMatches = $false
$recordTimeSource = 'missing'
if ($record) {
    $sessionStart = [datetimeoffset]$session.StartedAt
    if ($record.pid_create_time) {
        # Native started_at is rounded down to seconds; PID creation retains fractions.
        $recordTimeMatches = [double]$record.pid_create_time -ge ($sessionStart.ToUnixTimeMilliseconds() / 1000.0)
        $recordTimeSource = 'pid_create_time'
    } else {
        $recordTimeMatches = ([datetimeoffset]$record.started_at).ToUnixTimeSeconds() -ge $sessionStart.ToUnixTimeSeconds()
        $recordTimeSource = 'started_at_seconds'
    }
}
$recordMatchesSession = $record -and $record.run_id -eq $session.NativeRunId -and $record.task -eq 'routine' -and $recordTimeMatches
$nativeSuccess = $recordMatchesSession -and $record.status -eq 'success' -and $record.exit_code -eq 0 -and $session.ExitCode -eq 0
$lastPower = if ($powerValues.Count) { $powerValues[-1] } else { $null }
$battleCompletions = @([regex]::Matches($log,'第\d+次副本完成')).Count
$powerSection = [regex]::Match($log,'(?s)开始清体力(?<body>.*?)开始领取奖励')
$powerLog = $powerSection.Groups['body'].Value
$settlementCounts = @([regex]::Matches($powerLog,'(?m)\|\s*INFO\s*\|\s*已结算\s+(\d+)\s*次\s*$') | ForEach-Object { [int]$_.Groups[1].Value })
$challengesSettled = [int](($settlementCounts | Measure-Object -Sum).Sum)
$powerStopLine = if ($powerSection.Success) {
    @($powerLog -split '\r?\n' | Where-Object { $_ -match '\|\s*INFO\s*\|\s*开拓力不足，结束本副本项\s*$' }) | Select-Object -Last 1
}
$rewardCompletionLines = @($log -split '\r?\n' | Where-Object { $_ -match '每日实训已完成|每日实训奖励完成' })
$dailyScoreValues = @([regex]::Matches($log,'(?:当前累计分数[：:]|当前分数[：:]|每日实训活跃度)\s*(\d+)/500') | ForEach-Object { [int]$_.Groups[1].Value })
$daily500Observed = @($dailyScoreValues | Where-Object { $_ -ge 500 }).Count -gt 0 -or $rewardCompletionLines.Count -gt 0
$dailyFullLines=@($log -split '\r?\n'|Where-Object{$_ -match '检测到本日活跃度已满提示'})
$daily500Observed=$daily500Observed -or $dailyFullLines.Count -gt 0
$dailyNoneLines=@($log -split '\r?\n'|Where-Object{$_ -match '未检测到每日实训奖励'})
$batchPlans=@([regex]::Matches($log,'开始刷侵蚀隧洞\s*-\s*(?<name>[^，\r\n]+)，总计(?<rounds>\d+)轮，每轮包含(?<count>\d+)次')|ForEach-Object{[pscustomobject]@{Cavern=$_.Groups['name'].Value.Trim();Batches=[int]$_.Groups['rounds'].Value;ChallengesPerBatch=[int]$_.Groups['count'].Value}})
$instanceBatchPlans=@([regex]::Matches($log,'开始刷(?<type>侵蚀隧洞|饰品提取)\s*-\s*(?<name>[^，\r\n]+)，总计(?<rounds>\d+)轮，每轮包含(?<count>\d+)次')|ForEach-Object{[pscustomobject]@{InstanceType=$_.Groups['type'].Value;InstanceName=$_.Groups['name'].Value.Trim();Batches=[int]$_.Groups['rounds'].Value;ChallengesPerBatch=[int]$_.Groups['count'].Value}})
$immersifierValues = @([regex]::Matches($log,'沉浸器[：:]\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
$targetObserved = [bool]($expectedName -and $log -match ([regex]::Escape($expectedType) + '\s*-\s*' + [regex]::Escape($expectedName)))
$recoveredStartupIssues = @()
$startup = [regex]::Match($log,'(?s)\A.*?(?=开始清体力)')
if ($nativeSuccess -and $powerStopLine -and $challengesSettled -gt 0 -and $daily500Observed -and
    $rewardCompletionLines.Count -and $startup.Success) {
    $unknown = '\|\s*ERROR\s*\|\s*当前界面[：:]未知\s*$'
    $startupUnknown = @($startup.Value -split '\r?\n' | Where-Object { $_ -match $unknown })
    if ($startupUnknown.Count -eq @($issues | Where-Object { $_ -match $unknown }).Count) {
        $recoveredStartupIssues = $startupUnknown
        $issues = @($issues | Where-Object { $_ -notmatch $unknown })
    }
}
$result = [pscustomobject][ordered]@{
    CheckedAt = (Get-Date).ToString('o')
    SessionDirectory = $SessionDirectory
    NativeRunId = $session.NativeRunId
    NativeStatus = $(if ($record) { $record.status } else { 'unverified' })
    NativeTasksSucceeded = [bool]$nativeSuccess
    NativeRecordMatchesSession = [bool]$recordMatchesSession
    NativeRecordTimeSource = $recordTimeSource
    ExitCode = $session.ExitCode
    ExpectedInstanceType = $expectedType
    ExpectedInstanceName = $expectedName
    ExpectedInstanceInLog = $targetObserved
    InstanceBatchPlans = $instanceBatchPlans
    ImmersifierObservations = $immersifierValues
    ExpectedCavern = $session.ExpectedCavern
    ExpectedCavernInLog = [bool]($expectedType -eq '侵蚀隧洞' -and $targetObserved)
    PowerObservations = $powerValues
    PowerBefore = $(if ($powerValues.Count) { $powerValues[0] } else { $null })
    PowerAfter = $(if ($powerValues.Count -gt 1) { $powerValues[-1] } else { $null })
    PowerLastObserved = $lastPower
    PowerBelowCavernCostObserved = [bool]($null -ne $lastPower -and $lastPower -lt 40)
    PowerBelowInstanceCostObserved = [bool]($null -ne $lastPower -and $lastPower -lt 40)
    BattleCompletions = $battleCompletions
    ChallengesSettled = $challengesSettled
    PowerStopEvidence = $powerStopLine
    CavernBatchPlans = $batchPlans
    Daily500Observed = [bool]$daily500Observed
    DailyRewardClaimVerifiedInLog = [bool]($rewardCompletionLines.Count -gt 0 -or $log -match '\|\s*INFO\s*\|\s*已领取实训档位奖励')
    DailyRewardNotAvailableObserved = [bool]($dailyNoneLines.Count -gt 0)
    DailyCompletionEvidence = @($lines | Where-Object { $_ -match '每日实训已完成|每日实训完成|当前累计分数|每日实训活跃度|已领取实训档位奖励|实训分数已达标|每日实训奖励完成|检测到本日活跃度已满提示|未检测到每日实训奖励' })
    RecoveredStartupIssues = $recoveredStartupIssues
    Issues = $issues
    GameClosed = !(Get-Process -Name StarRail -ErrorAction SilentlyContinue)
    Status = $(if (!$nativeSuccess) { 'failed_or_unverified' } elseif ($issues.Count) { 'needs_review' } else { 'native_success_requires_reward_review' })
    VisualReviewRequired = $true
}
[IO.File]::WriteAllText((Join-Path $SessionDirectory 'result.json'), ($result | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
$result
