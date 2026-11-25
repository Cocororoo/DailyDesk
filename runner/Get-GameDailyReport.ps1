[CmdletBinding()]
param([Parameter(Mandatory)][string]$ControlDirectory,[Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$readErrors=[Collections.Generic.List[string]]::new()
function Read-Json($Path){if($Path -and (Test-Path -LiteralPath $Path)){try{Get-Content -Raw -Encoding UTF8 -LiteralPath $Path|ConvertFrom-Json}catch{$readErrors.Add('无法读取 '+$Path+'：'+$_.Exception.Message)}}}
function Encode($Text){[Net.WebUtility]::HtmlEncode([string]$Text)}
function File-Link($Path,$Label){if(!$Path){return ''};'<a href="'+(Encode ([uri]::new([IO.Path]::GetFullPath($Path)).AbsoluteUri))+'">'+(Encode $Label)+'</a>'}
$settings=Read-Json (Join-Path $ControlDirectory 'supervisor.json')
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
$config=Read-DailyConfig $ConfigPath
$pointer=Join-Path $ControlDirectory 'suite-run.txt'
$run=if(Test-Path -LiteralPath $pointer){[IO.File]::ReadAllText($pointer).Trim()}else{$null}
$suite=if($run){Read-Json (Join-Path $run 'suite-result.json')}else{$null}
$diagnosis=Read-Json (Join-Path $ControlDirectory 'diagnosis.json')
if($diagnosis -and ($diagnosis.Schema -ne 'daily-diagnosis-v1' -or $diagnosis.SuiteRunDirectory -ne $run)){
    $readErrors.Add('复核记录与当前运行目录不匹配，未采用。');$diagnosis=$null
}
$cancelled=Test-Path -LiteralPath (Join-Path $ControlDirectory 'cancel-request.json')
$rows=[Collections.Generic.List[object]]::new()
function Add-Row($Game,$Task,$Status,$Detail,$Evidence){$rows.Add([pscustomobject]@{Game=$Game;Task=$Task;Status=$Status;Detail=[string]$Detail;Evidence=[string]$Evidence})}
$sequence=if($suite){@($suite.Sequence)}elseif($settings.Game -eq 'All'){@($config.Sequence)}else{@($settings.Game)}
$gameLabels=@{Genshin='原神';StarRail='星穹铁道';Endfield='终末地'}
$endNames=@{VisitFriends='拜访好友';GiftOperator='赠送与收取礼物';DijiangRewards='帝江号／基建';SellProduct='据点交易';AutoStockStaple='购买稳定物资';ResourceRecycleStation='资源回收站';AutoCollect='特产采集／存仓';AutoStockpile='自动囤货';AutoSell='售卖弹性物资';EnvironmentMonitoring='环境监测';AutoEssence='源质／基质清理智';CreditShoppingN2='信用点购物';DailyRewards='日常／邮件／活动／通行证领奖';CloseGamePC='退出游戏';__MXU_PRETASK__LaunchGamePC='启动游戏'}
$gameSummary=@()
foreach($game in $sequence){
    $stage=@($suite.Stages|Where-Object{$_.Game -eq $game})|Select-Object -Last 1
    $label=$gameLabels[$game]
    $state=if(!$stage){'未执行'}elseif($stage.NativeCompleted -and $stage.Status -eq 'native_completed_requires_reward_review'){'原生流程通过；收益待核验'}elseif($stage.Status -eq 'cancelled'){'已中止'}elseif($stage.Status -eq 'running'){'未完成／运行中'}else{'失败／待检查'}
    $gameSummary+=[pscustomobject]@{Game=$label;Status=$state;StartedAt=$stage.StartedAt;FinishedAt=$stage.FinishedAt;Evidence=$stage.EvidenceDirectory;Error=$stage.Error}
    $resultPath=$stage.ResultFile
    if(!$resultPath -and $stage.EvidenceDirectory){
        if($game -eq 'Genshin'){$session=Read-Json (Join-Path $stage.EvidenceDirectory 'session.json');if($session.RunDirectory){$resultPath=Join-Path $session.RunDirectory 'result.json'}}
        else{$resultPath=Join-Path $stage.EvidenceDirectory 'result.json'}
    }
    $result=Read-Json $resultPath
    $reassessment=@($diagnosis.Games|Where-Object{$_.Game -eq $game})|Select-Object -Last 1
    if($game -eq 'Endfield' -and $reassessment.NativeTasksVerified -and $result.native_tasks_complete -and $result.terminal_recovered_from_framework_events){
        $gameSummary[-1].Status='复核：原生任务已完成；监控曾误报'
        $gameSummary[-1].FinishedAt=$reassessment.NativeFinishedAt
    }
    if($game -eq 'StarRail' -and $reassessment.NativeRunId -and $reassessment.NativeRunId -eq $result.NativeRunId -and
        $result.NativeTasksSucceeded -and $result.GameClosed -and $result.PowerStopEvidence -and
        $result.ChallengesSettled -gt 0 -and $result.DailyRewardClaimVerifiedInLog -and !@($result.Issues).Count){
        $gameSummary[-1].Status='复核：清体力与实训奖励已完成'
        $gameSummary[-1].Error=$null
    }
    $missing=if(!$stage){'未执行'}elseif($cancelled){'中断；缺少完成证据'}else{'待核验；缺少完成证据'}
    if($stage.Status -eq 'preflight_failed'){Add-Row $label '启动预检' '失败；已跳过该游戏' $stage.Error $null}
    if($game -eq 'Genshin'){
        if($result.PartyLifecycleCheck){
            $party=$result.PartyLifecycleCheck
            $slot=if($party.Recorded.Count){$party.Recorded[0].originalSlot}
            Add-Row $label '刷本队伍／还原原队' $(if($party.Status -eq 'verified'){'已核验'}else{$missing}) ('原第'+$slot+'队；'+($party.Errors -join '；')) $resultPath
        }
        Add-Row $label '秘境／清树脂' $(if($result.ResinExhausted){'日志支持完成'}else{$missing}) $(if($result){'目标：'+$result.ExpectedDomain+'；挑战完成 '+$result.ChallengeCompletedRounds+' 次；最终原粹 '+$result.OriginalResin+'，浓缩 '+$result.CondensedResin}else{'无本轮资源读数'}) $resultPath
        if($result.ArtifactBagFullObserved){
            Add-Row $label '圣遗物背包' '空间不足；领奖被阻止' '圣遗物背包已满，秘境奖励无法结算。' $resultPath
        }
        $commissionDetail=$result.Summary
        if($result.CommissionCheck){
            $c=$result.CommissionCheck
            $commissionDetail+='；独立核验 '+$c.status+'；委托 '+$c.completed+'/4；已耗树脂 '+$c.resinConsumed+'/120；树脂缺口 '+$c.resinShortfall+'；领取重试 '+$c.attempts
        }
        $commissionStatus=if($result.DailyRewardClaimed){'日志支持已领取'}elseif($result.CommissionCheck.status -eq 'prerequisite_incomplete'){'前置未满足'}elseif($result.CommissionCheck.status -eq 'ready'){'可领但未领取'}else{$missing}
        Add-Row $label '每日委托奖励' $commissionStatus $commissionDetail $resultPath
        $commissionFolder=if($resultPath){Join-Path (Split-Path $resultPath -Parent) 'commission-evidence'}else{$null}
        if($commissionFolder -and (Test-Path -LiteralPath (Join-Path $commissionFolder 'receipt.json'))){
            $commissionReceipt=Read-Json (Join-Path $commissionFolder 'receipt.json')
            $lastSnapshot=@($commissionReceipt.snapshots)|Select-Object -Last 1
            if($lastSnapshot.path){Add-Row $label '委托页截图／OCR' '已留存' (Join-Path $commissionFolder 'receipt.json') (Join-Path $commissionFolder ([IO.Path]::GetFileName($lastSnapshot.path)))}
        }
        Add-Row $label '邮件' $(if(@($result.MailEvidence|Where-Object{$_}).Count -gt 0){'有操作记录；待核验'}else{$missing}) ($result.MailEvidence -join '；') $resultPath
        $nativeLog=if($resultPath){Join-Path (Split-Path $resultPath) 'run.log'}else{$null}
        $text=if($nativeLog -and (Test-Path -LiteralPath $nativeLog)){[IO.File]::ReadAllText($nativeLog)}else{''}
        foreach($item in @(@('探索派遣','派遣|探索人员|重新探索'),@('纪行','纪行'))){
            $lines=@($text -split '\r?\n'|Where-Object{$_ -match $item[1]}|Select-Object -Last 4)
            Add-Row $label $item[0] $(if($lines.Count){'有操作记录；待核验'}else{$missing}) ($lines -join '；') $nativeLog
        }
        Add-Row $label '尘歌壶宝钱／好感' $(if(@($result.PotEvidence|Where-Object{$_}).Count){'有操作记录；待核验'}else{$missing}) ($result.PotEvidence -join '；') $resultPath
        Add-Row $label '秘境掉落物品' $(if($result.RewardRecognitionRounds -gt 0){'有识别结果；待核验'}elseif($result.ChallengeCompletedRounds -gt 0){'掉落数量未核验'}else{$missing}) ('奖励识别 '+$result.RewardRecognitionRounds+' 轮；'+($result.RewardEvidence -join '；')) $resultPath
        if($result.RecoveredReviveEvents){Add-Row $label '角色倒下后恢复' $(if($result.ReviveRecoveryVerified){'日志支持恢复后继续通关'}else{'恢复结果待核验'}) ($result.RecoveredReviveEvents -join '；') $resultPath}
        $session=if($stage.EvidenceDirectory){Read-Json (Join-Path $stage.EvidenceDirectory 'session.json')}else{$null}
        if($session.DomainFallback){
            $attemptText=(@($session.Attempts|ForEach-Object{$_.Domain+'：'+$(if($_.ResinExhausted){'树脂已清至不足再领取'}else{'未清完，原始问题：'+($_.Issues -join '；')})+'；证据 '+$_.RunDirectory}) -join ' → ')
            Add-Row $label '体力副本回退' '已使用授权备用；保留主目标记录' ($session.DomainFallback.From+' → '+$session.DomainFallback.To+'；原因：'+$session.DomainFallback.Reason+'；'+$attemptText) (Join-Path $stage.EvidenceDirectory 'session.json')
        }
        $displayDetails = if ($session.RestoredDisplay) {
            ('已恢复 {0}×{1} {2}' -f $session.RestoredDisplay.Width.Value,$session.RestoredDisplay.Height.Value,$(if($session.RestoredDisplay.Fullscreen.Value){'全屏'}else{'窗口'}))
        } elseif ($session) { '本轮未启用分辨率管理' } else { '' }
        Add-Row $label '退出／恢复显示设置' $(if($session.GameClosed -and $session.BetterGIClosed -and $session.DisplayPreferenceRestored){'已核验'}else{$missing}) $displayDetails $stage.EvidenceDirectory
    } elseif($game -eq 'StarRail'){
        $batchText=(@($result.CavernBatchPlans|ForEach-Object{'计划 '+$_.Batches+' 批×每批 '+$_.ChallengesPerBatch+' 次'}) -join '；')
        $settled=if($result.ChallengesSettled -gt 0){'结算 '+$result.ChallengesSettled+' 次'}elseif($result.BattleCompletions -gt 0){'完成 '+$result.BattleCompletions+' 批'}
        $powerStop=if($result.PowerStopEvidence){'开拓力不足以继续'}
        $powerState=if($result.NativeTasksSucceeded -and ($result.PowerBelowCavernCostObserved -or ($result.PowerStopEvidence -and $result.ChallengesSettled -gt 0))){'日志支持完成'}elseif($result.NativeTasksSucceeded -and ($result.BattleCompletions -gt 0 -or $result.ChallengesSettled -gt 0)){'挑战已完成；最终余量待核验'}else{$missing}
        $target=if($result.ExpectedInstanceName){$result.ExpectedInstanceName}else{$result.ExpectedCavern}
        $targetDetail=if($target){if($result.ExpectedInstanceInLog -or $result.ExpectedCavernInLog){'目标已由日志识别：'+$target}else{'配置目标：'+$target+'（本轮日志未核实具体副本）'}}
        $powerDetails=@($targetDetail,$settled,$powerStop,$batchText,$(if($result.PowerObservations){'本轮体力观测：'+($result.PowerObservations -join ' → ')}))
        Add-Row $label '遗器清体力' $powerState (($powerDetails | Where-Object {$_}) -join '；') $resultPath
        Add-Row $label '每日实训500与领奖' $(if($result.DailyRewardClaimVerifiedInLog){'日志支持已领取'}elseif($result.Daily500Observed -and $result.DailyRewardNotAvailableObserved){'活跃度已满；本轮无可领奖励'}elseif($result.Daily500Observed){'已观测500；领奖待核验'}else{$missing}) ($result.DailyCompletionEvidence -join '；') $resultPath
        $nativeLog=if($stage.EvidenceDirectory){Join-Path $stage.EvidenceDirectory 'native-run.log'}else{$null}
        if($nativeLog -and !(Test-Path -LiteralPath $nativeLog)){$nativeLog=Join-Path $stage.EvidenceDirectory 'console.log'}
        $text=if($nativeLog -and (Test-Path -LiteralPath $nativeLog)){[IO.File]::ReadAllText($nativeLog)}else{''}
        foreach($item in @(@('委托收取与再派遣','委托'),@('邮件','邮件'),@('支援收益','支援.*收益|支援.*奖励'),@('无名勋礼','无名勋礼|勋礼'))){
            $lines=@($text -split '\r?\n'|Where-Object{$_ -match $item[1]}|Select-Object -Last 3)
            Add-Row $label $item[0] $(if($lines.Count){'有操作记录；待核验'}else{$missing}) ($lines -join '；') $nativeLog
        }
        Add-Row $label '退出游戏' $(if($result.GameClosed){'已核验'}else{$missing}) '' $resultPath
    } else {
        if ($result.startup_block.code -eq 'title-screen-transition-timeout') {
            $proof = @($result.startup_block.evidence | ForEach-Object { "$($_.file):$($_.line)" }) -join '；'
            Add-Row $label '进入大世界' '失败' ('启动界面识别超时；进入大世界后可单独补跑终末地。'+$proof) $resultPath
        }
        $meta=if($stage.EvidenceDirectory){Read-Json (Join-Path $stage.EvidenceDirectory 'run-metadata.json')}else{$null}
        $plan=Read-Json (Join-Path $ControlDirectory 'endfield-plan.json')
        $tasks=if($meta){@($meta.expected_tasks)}else{@($plan.instance.tasks|Where-Object{$_.enabled})}
        foreach($task in $tasks){
            $name=$task.taskName
            $taskResult=@($result.per_task|Where-Object{$_.id -eq $task.id})|Select-Object -Last 1
            $taskState=if($taskResult.status -eq 'succeeded'){'原生成功；收益待核验'}elseif($taskResult.status -eq 'failed'){'失败'}elseif($taskResult.status -eq 'skipped'){'原生跳过'}else{$missing}
            $extra='原生任务：'+$name+'；状态：'+$taskResult.status
            if($name -eq 'AutoCollect'){$extra+='；采集日期以原生计划为准'}
            $skip=@($result.planned_skips|Where-Object{$_.task -eq $name})|Select-Object -Last 1
            if($taskResult.status -eq 'succeeded' -and $skip.reason -eq 'not-in-weekly-schedule'){
                $taskState='按周计划跳过';$extra='本轮为 '+$skip.weekday+'，不在采集计划内。日志 '+$skip.file+':'+$skip.line
            }
            $failures=@($result.observed_subtask_failures|Where-Object{$_.task -like ($name+'*')})
            if($failures.Count){$taskState='失败（含子任务错误）';$extra+='；'+(($failures|ForEach-Object{$_.task+': '+$_.message}) -join '；')}
            $title=if($endNames.ContainsKey($name)){$endNames[$name]}else{$name}
            Add-Row $label $title $taskState $extra $resultPath
        }
        Add-Row $label '资源与奖励实际收益' '待核验' '实际收益见理智、调度券、物品和领奖截图。' $stage.EvidenceDirectory
        $resourceReview=Read-Json $result.review_file
        if($null -ne $resourceReview.sanity_after -and $resourceReview.sanity_after_evidence -and (Test-Path -LiteralPath $resourceReview.sanity_after_evidence)){
            Add-Row $label '理智最终余量' '已核对截图' ([string]$resourceReview.sanity_after+'/360；'+$resourceReview.sanity_after_observed_at) $resourceReview.sanity_after_evidence
        }
    }
    if(@($result.Issues|Where-Object{$_}).Count){Add-Row $label '日志异常／提示' '请检查' ($result.Issues -join '；') $resultPath}
}
$finalize=Read-Json (Join-Path $ControlDirectory 'finalize-receipt.json')
$overall=if($cancelled){'已中止：本轮未全部完成'}elseif($suite.Status -eq 'native_sequence_completed_requires_reward_review'){'原生流程全部通过；逐项收益仍以证据为准'}else{'需要检查：存在失败、未执行或缺少证据'}
if(!$cancelled -and $diagnosis.Conclusion -eq 'native-tasks-verified-monitor-false-negative' -and
    @($gameSummary|Where-Object{$_.Status -notmatch '原生流程通过|复核：原生任务已完成'}).Count -eq 0){
    $overall='复核：三游戏原生任务已完成；终末地监控曾误报，部分收益证据仍待补齐'
}
if(@($finalize.Errors|Where-Object{$_}).Count){$overall+='；收尾有错误，请检查'}
if($readErrors.Count){$overall+='；部分证据无法读取'}
$report=[ordered]@{Schema='daily-review-v1';GeneratedAt=(Get-Date).ToString('o');StartedAt=$settings.StartedAt;FinishedAt=$suite.FinishedAt;Summary=$overall;Cancelled=$cancelled;SuiteRunDirectory=$run;ControlDirectory=$ControlDirectory;Games=$gameSummary;Tasks=@($rows.ToArray());Error=$suite.Error;FinalizeErrors=@($finalize.Errors|Where-Object{$_});WorkerError=$(if(Test-Path (Join-Path $ControlDirectory 'worker-error.txt')){[IO.File]::ReadAllText((Join-Path $ControlDirectory 'worker-error.txt'))}else{$null})}
$report.RecordSource=$settings.RecordSource
$report.ReadErrors=@($readErrors.ToArray())
$report.Reassessment=$diagnosis
[IO.File]::WriteAllText((Join-Path $ControlDirectory 'report.json'),($report|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
$md=[Text.StringBuilder]::new()
$null=$md.AppendLine('# 每日上班运行记录').AppendLine().AppendLine($overall).AppendLine().AppendLine('开始：'+$settings.StartedAt+'；报告生成：'+$report.GeneratedAt).AppendLine().AppendLine('| 游戏 | 结果 |').AppendLine('|---|---|')
$html=[Text.StringBuilder]::new()
$null=$html.Append('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>每日上班运行记录</title><style>body{font:16px/1.6 "Microsoft YaHei",sans-serif;max-width:1200px;margin:36px auto;padding:0 24px;color:#203047;background:#f7f8fc}h1,h2{color:#673e81}table{border-collapse:collapse;width:100%;background:white;margin:16px 0}td,th{border:1px solid #d8dce7;padding:10px;text-align:left;vertical-align:top}td:last-child{max-width:630px;overflow-wrap:anywhere}a{color:#744c9e}.summary{padding:18px;background:#f0e5f5;border-radius:12px}small{color:#596579}</style><h1>每日上班运行记录</h1><p class="summary">').Append((Encode $overall)).Append('</p><p>开始：').Append((Encode $settings.StartedAt)).Append('<br>报告生成：').Append((Encode $report.GeneratedAt)).Append('</p><table><tr><th>游戏</th><th>结果</th><th>运行证据</th></tr>')
foreach($g in $gameSummary){$null=$md.AppendLine('| '+$g.Game+' | '+$g.Status+' |');$null=$html.Append('<tr><td>').Append((Encode $g.Game)).Append('</td><td>').Append((Encode $g.Status)).Append('<br><small>开始：').Append((Encode $g.StartedAt)).Append('<br>结束：').Append((Encode $g.FinishedAt)).Append('</small></td><td>').Append((File-Link $g.Evidence '打开目录')).Append('</td></tr>')}
$null=$html.Append('</table>')
if($diagnosis){
    $null=$md.AppendLine().AppendLine('## 运行后复核').AppendLine().AppendLine($diagnosis.Summary).AppendLine().AppendLine('复核时间：'+$diagnosis.CheckedAt+'；原始总调度状态：'+$suite.Status+'。原始失败与worker错误保留。').AppendLine().AppendLine('完整诊断：'+(Join-Path $ControlDirectory 'diagnosis.md'))
    $null=$html.Append('<h2>运行后复核</h2><p class="summary">').Append((Encode $diagnosis.Summary)).Append('</p><p>复核时间：').Append((Encode $diagnosis.CheckedAt)).Append('；原始总调度状态：').Append((Encode $suite.Status)).Append('。以下保留原始监控错误。</p><p>').Append((File-Link (Join-Path $ControlDirectory 'diagnosis.md') '完整诊断与证据')).Append('</p>')
}
if($settings.RecordSource){$null=$md.AppendLine().AppendLine('记录来源：'+$settings.RecordSource);$null=$html.Append('<p>记录来源：').Append((Encode $settings.RecordSource)).Append('</p>')}
$null=$html.Append('<p>“日志支持完成”“有操作记录”“原生成功”和“实际收益已核验”含义不同；缺少证据的项目不会算作全部成功。非安排日、资源不足、库存／价格跳过可能没有新增收益。</p>')
foreach($label in $gameLabels.Values|Select-Object -Unique){
    $items=@($rows|Where-Object{$_.Game -eq $label});if(!$items.Count){continue}
    $null=$md.AppendLine().AppendLine('## '+$label).AppendLine().AppendLine('| 项目 | 结果 | 说明 |').AppendLine('|---|---|---|')
    $null=$html.Append('<h2>').Append((Encode $label)).Append('</h2><table><tr><th>日常项目</th><th>结果</th><th>说明／证据</th></tr>')
    foreach($item in $items){
        $safe=$item.Detail.Replace('|','／').Replace("`r",' ').Replace("`n",' ')
        $null=$md.AppendLine('| '+$item.Task+' | '+$item.Status+' | '+$safe+' |')
        $null=$html.Append('<tr><td>').Append((Encode $item.Task)).Append('</td><td>').Append((Encode $item.Status)).Append('</td><td>').Append((Encode $item.Detail)).Append('<br>').Append((File-Link $item.Evidence '原始证据')).Append('</td></tr>')
    }
    $null=$html.Append('</table>')
}
foreach($errorText in (@($report.Error,$report.WorkerError)+@($report.FinalizeErrors)+@($report.ReadErrors))){if($errorText){$null=$html.Append('<p class="summary">').Append((Encode $errorText)).Append('</p>');$null=$md.AppendLine().AppendLine($errorText)}}
$null=$html.Append('<p>').Append((File-Link $ControlDirectory '完整运行记录')).Append(' · ').Append((File-Link $run '总调度日志')).Append('</p></html>')
[IO.File]::WriteAllText((Join-Path $ControlDirectory 'report.md'),$md.ToString(),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ControlDirectory 'report.html'),$html.ToString(),[Text.UTF8Encoding]::new($false))
if($run){foreach($name in @('report.md','report.html','report.json')){Copy-Item -LiteralPath (Join-Path $ControlDirectory $name) -Destination (Join-Path $run $name) -Force}}
[pscustomobject]@{Summary=$overall;Report=(Join-Path $ControlDirectory 'report.html');TaskCount=$rows.Count}
