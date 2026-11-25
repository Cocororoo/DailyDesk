[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory)
$ErrorActionPreference = 'Stop'
$RunDirectory = (Resolve-Path -LiteralPath $RunDirectory).Path
$run = Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$parts = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $(if($run.LogsFrozenAt){@()}else{@(Get-ChildItem -LiteralPath (Join-Path $run.BgiRoot 'log') -Filter 'better-genshin-impact*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)})) {
    $offset = 0L
    $previous = $run.LogOffsets.PSObject.Properties[$file.Name]
    if ($previous) { $offset = [long]$previous.Value }
    elseif ($file.LastWriteTime -lt [DateTime]::Parse($run.StartedAt)) { continue }
    if ($file.Length -lt $offset) { throw ('Log file was truncated; cannot verify this run: ' + $file.Name) }
    $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        try { $parts.Add($reader.ReadToEnd()) } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
$logText = $parts -join "`r`n"
if($run.LogsFrozenAt){$logText=[IO.File]::ReadAllText((Join-Path $RunDirectory 'run.log'))}
[IO.File]::WriteAllText((Join-Path $RunDirectory 'run.log'), $logText, (New-Object Text.UTF8Encoding($false)))
$profileStarted = $logText.Contains('启用一条龙配置：' + $run.Profile)
$nativeEnded = $profileStarted -and $logText.Contains('一条龙和配置组任务结束')
$summaryLines = @($logText -split '\r?\n' | Where-Object { $_ -match '一条龙结束汇总：|检查每日奖励结果：' })
$summary = if ($summaryLines.Count) { $summaryLines[-1] } else { '' }
$original = $null; $condensed = $null
$matchOriginal = [regex]::Match($summary, '原粹树脂\s+(\d+)/\d+')
$matchCondensed = [regex]::Match($summary, '浓缩树脂\s+(\d+)')
if ($matchOriginal.Success) { $original = [int]$matchOriginal.Groups[1].Value }
if ($matchCondensed.Success) { $condensed = [int]$matchCondensed.Groups[1].Value }
$rewards = @($logText -split '\r?\n' | Where-Object { $_ -match '本轮奖励识别结果' -and $_ -notmatch '为空' })
$reviewLogText = $logText
$combatEndCancellations = @()
# Native JSON logs cancellation as ERR when a clear interrupts an attack.
# Exclude only that exact message immediately following a clear (within 3s).
foreach ($cancel in [regex]::Matches($logText, '(?m)^\[(?<time>\d{2}:\d{2}:\d{2}\.\d{3})\] \[ERR\][^\r\n]*\r?\n(?<message>自动战斗：[^\r\n]*执行失败："取消自动任务")\r?$')) {
    $clearsBefore = [regex]::Matches($logText.Substring(0, $cancel.Index), '(?m)^\[(?<time>\d{2}:\d{2}:\d{2}\.\d{3})\][^\r\n]*\r?\n检测到秘境结束提示\(挑战达成\)，结束秘境\r?$')
    if ($clearsBefore.Count) {
        $lastClear = $clearsBefore[$clearsBefore.Count - 1]
        $elapsed = [TimeSpan]::Parse($cancel.Groups['time'].Value) - [TimeSpan]::Parse($lastClear.Groups['time'].Value)
        $between = $logText.Substring($lastClear.Index + $lastClear.Length, $cancel.Index - $lastClear.Index - $lastClear.Length)
        if ($elapsed.TotalSeconds -ge 0 -and $elapsed.TotalSeconds -le 3 -and [string]::IsNullOrWhiteSpace($between)) {
            $combatEndCancellations += $cancel.Value
            $reviewLogText = $reviewLogText.Replace($cancel.Value, '')
        }
    }
}
$issues = @($reviewLogText -split '\r?\n' | Where-Object { $_ -match '\[ERR\]|\[FTL\]|任务被取消|结果为空|奖励识别失败|已跳过本轮奖励识别|未领取|未配置.*跳过|未选择.*跳过|体力识别失败|委托状态识别失败|存在角色被击败|存在角色死亡|恢复时发生异常|打开大地图失败|未完整匹配到当前队伍|条件表达式求值失败|自动战斗：.*执行失败' })
$challengeRounds = ([regex]::Matches($logText, '检测到秘境结束提示\(挑战达成\)')).Count
$resinEvents = @($logText -split '\r?\n' | Where-Object { $_ -match '自动秘境.*使用.*树脂' })
$domainEvidence = @($logText -split '\r?\n' | Where-Object { $_ -match '传送到秘境|开始传送：.*秘境' })
$dailyClaimed = $summary -match '每日委托奖励：已领取|检查每日奖励结果：.*今日奖励已领取'
$commissionCheck=$null
if($run.NativeCommissionRunId){
    $commissionResults=@([regex]::Matches($logText,'(?m)^AGENT_COMMISSION_RESULT (.+)\r?$')|ForEach-Object{$_.Groups[1].Value|ConvertFrom-Json}|Where-Object{$_.runId -eq $run.NativeCommissionRunId})
    if($commissionResults.Count -eq 1){$commissionCheck=$commissionResults[0]}else{$commissionCheck=[pscustomobject]@{status='not_verified';runId=$run.NativeCommissionRunId}}
    # Never promote a stale or conflicting receipt over the final native summary.
    $dailyClaimed=$dailyClaimed -and $commissionCheck.status -eq 'claimed'
    if($nativeEnded -and $commissionCheck.status -ne 'claimed'){
        $issues+=@('Commission verification: '+$commissionCheck.status+'; completed='+$commissionCheck.completed+'; resinConsumed='+$commissionCheck.resinConsumed+'; resinShortfall='+$commissionCheck.resinShortfall)
    }
}
$resinExhausted = $null -ne $original -and $original -lt 20 -and $null -ne $condensed -and $condensed -eq 0
$revivePattern = '^(?:检测到复苏界面，存在角色被击败，前往七天神像复活|自动秘境：["“]?存在角色死亡，复活后重试秘境\.{3}["”]?)\r?$'
$reviveRecords = @([regex]::Matches($reviewLogText, ('(?m)' + $revivePattern)))
$recoveredReviveEvents = @()
$reviveRecoveryVerified = $false
if ($nativeEnded -and $resinExhausted -and $dailyClaimed -and $reviveRecords.Count) {
    $afterLastRevive = $reviewLogText.Substring($reviveRecords[-1].Index + $reviveRecords[-1].Length)
    # A final summary alone is insufficient: require a later clear and actual resin use.
    if ($afterLastRevive -match '检测到秘境结束提示\(挑战达成\)' -and $afterLastRevive -match '自动秘境.*使用.*树脂') {
        $reviveRecoveryVerified = $true
        $recoveredReviveEvents = @($reviveRecords | ForEach-Object { $_.Value.TrimEnd() })
        $issues = @($issues | Where-Object { $_ -notmatch $revivePattern })
    }
}
$status = if (!$profileStarted) { 'not_started' } elseif (!$nativeEnded) { 'running_or_interrupted' } elseif ($dailyClaimed -and $resinExhausted -and $issues.Count -eq 0) { 'native_core_verified_requires_visual_review' } else { 'needs_review' }
$result = [ordered]@{
    CheckedAt = (Get-Date).ToString('o'); Status = $status; ProfileStarted = $profileStarted; NativeEnded = $nativeEnded
    ExpectedDomain = $run.ExpectedDomain; OriginalResin = $original; CondensedResin = $condensed
    CommissionCheck = $commissionCheck
    ResinExhausted = $resinExhausted; DailyRewardClaimed = $dailyClaimed; RewardRecognitionRounds = $rewards.Count
    ChallengeCompletedRounds = $challengeRounds; ResinUseEvidence = $resinEvents; DomainEvidence = $domainEvidence
    MailEvidence = @($logText -split '\r?\n' | Where-Object { $_ -match '邮件：' })
    PotEvidence = @($logText -split '\r?\n' | Where-Object { $_ -match '领取好感和宝钱|未配置购买商店物品' })
    Summary = $summary; Issues = $issues; RewardEvidence = $rewards; ExpectedCombatEndCancellations = $combatEndCancellations
    ReviveRecoveryVerified = $reviveRecoveryVerified; RecoveredReviveEvents = $recoveredReviveEvents
    VisualReviewRequired = @('reward item and domain', 'daily reward claimed in handbook', 'expeditions dispatched', 'pot balances or no rewards available')
}
[IO.File]::WriteAllText((Join-Path $RunDirectory 'result.json'), ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
[pscustomobject]$result
