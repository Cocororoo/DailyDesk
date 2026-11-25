$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
foreach ($source in Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object Extension -In '.ps1','.psm1') {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($source.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($source.FullName + ": " + ($errors -join [Environment]::NewLine)) }
}
Import-Module (Join-Path $project 'runner/Configuration.psm1') -Force
$fixture = New-DailyRunDirectory ([IO.Path]::GetTempPath())
$bgi = (New-Item -ItemType Directory -Path (Join-Path $fixture 'BetterGI/User/OneDragon') -Force).Parent.Parent.FullName
$star = (New-Item -ItemType Directory -Path (Join-Path $fixture 'March7th/assets/config') -Force).Parent.Parent.FullName
$maa = (New-Item -ItemType Directory -Path (Join-Path $fixture 'MaaEnd/config') -Force).Parent.FullName
# Each stand-in executable is either empty or performs a harmless JSON status query.
$null = New-Item -ItemType File -Path (Join-Path $bgi 'BetterGI.exe'),(Join-Path $maa 'MaaEnd.exe'),(Join-Path $fixture 'YuanShen.exe')
$starConfig = Join-Path $star 'config.yaml'
$status = (@{config_file=$starConfig;first_run_completed=$true;game_path_exists=$true;elevation='admin'} | ConvertTo-Json -Compress)
$statusLiteral = $status.Replace('\','\\').Replace('"','\"')
Add-Type -TypeDefinition "public static class MarchFixture { public static void Main(string[] a) { System.Console.WriteLine(`"$statusLiteral`"); } }" -OutputAssembly (Join-Path $star 'm7a.exe') -OutputType ConsoleApplication
Write-DailyJson (Join-Path $bgi 'User/config.json') @{genshinStartConfig=@{linkedStartEnabled=$true;installPath=(Join-Path $fixture 'YuanShen.exe')}}
Write-DailyJson (Join-Path $bgi 'User/OneDragon/Daily.json') @{
    Name='Daily';CompletionAction='关闭游戏和软件';DomainName='Testing'
    TaskEnabledList=@{'自动秘境'=$true;'领取邮件'=$true}
}
$map = New-Item -ItemType Directory (Join-Path $bgi 'GameTask/AutoTrackPath/Assets') -Force
Write-DailyJson (Join-Path $map.FullName 'tp.json') @{data=@(@{points=@(@{name='Testing';type='BlessDomain'})})}
$starYaml = @'
instance_type: 侵蚀隧洞
instance_names:
  侵蚀隧洞: Testing
use_fuel: false
use_reserved_trailblaze_power: false
build_target_enable: false
break_down_level_four_relicset: false
weekly_relic_smart_discard_enable: false
echo_of_war_enable: false
activity_enable: false
borrow_enable: false
borrow_character_enable: false
power_plan: []
power_enable: true
daily_enable: true
reward_enable: true
reward_quest_enable: true
reward_dispatch_enable: true
reward_mail_enable: true
reward_assist_enable: true
reward_srpass_enable: true
'@
Set-Content -LiteralPath $starConfig -Value $starYaml -Encoding UTF8
Set-Content -LiteralPath (Join-Path $star 'assets/config/config.example.yaml') -Value $starYaml -Encoding UTF8
Write-DailyJson (Join-Path $star 'assets/config/instance_names.json') @{'侵蚀隧洞'=@{Testing='Test'};'饰品提取'=@{Testing='Test'}}
$null = New-Item -ItemType Directory -Path (Join-Path $maa 'tasks/AutoEssence/Location'),(Join-Path $maa 'locales/interface') -Force
Write-DailyJson (Join-Path $maa 'tasks/AutoEssence/Location/ChooseLocation.json') @{option=@{AutoEssenceChooseLocation=@{cases=@(@{name='Region';label='Region'})}}}
Write-DailyJson (Join-Path $maa 'locales/interface/zh_cn.json') @{Region='Region'}
$endTasks = @(
    @{id='gather';taskName='AutoCollect';enabled=$true;optionValues=@{AutoCollectSchedule=@{caseNames=@('AutoCollectScheduleTuesday')};AutoCollectStashBackpackSubTask=@{value=$true}}}
    @{id='essence';taskName='AutoEssence';enabled=$true;optionValues=@{AutoEssenceChooseLocation=@{caseNames=@('Region')};AutoEssenceRepeatCount=@{values=@{AutoEssenceRepeatCountValue='10'}}}}
    @{id='stock';taskName='AutoStockStaple';enabled=$true;optionValues=@{AutoStockReserveValleyIV=@{values=@{ReserveValleyIV='150000'}}}}
    @{id='exit';taskName='CloseGamePC';enabled=$true;optionValues=@{}}
)
Write-DailyJson (Join-Path $maa 'config/mxu-MaaEnd.json') @{
    settings=@{webServerEnabled=$true;webServerPort=12701}
    instances=@(@{name='Daily';id='daily';controllerName='Win32-Front';tasks=$endTasks})
}
$configPath = Join-Path $fixture 'config.local.json'
& (Join-Path $project 'Setup.ps1') -BetterGI $bgi -BetterGIProfile Daily -March7th $star -MaaEnd $maa -MaaEndInstance Daily -GenshinAutomationWidth 1600 -GenshinAutomationHeight 900 -GenshinAutomationFullscreen -LeaveGenshinDisplay -ConfigPath $configPath
$localConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($localConfig.Genshin.AutomationWidth -ne 1600 -or $localConfig.Genshin.AutomationHeight -ne 900 -or !$localConfig.Genshin.AutomationFullscreen) {
    throw 'Genshin automation display settings were not saved.'
}
$legacyConfig = Join-Path $fixture 'legacy-config.json'
$localConfig.Genshin.PSObject.Properties.Remove('AutomationWidth')
$localConfig.Genshin.PSObject.Properties.Remove('AutomationHeight')
$localConfig.Genshin.PSObject.Properties.Remove('AutomationFullscreen')
Write-DailyJson $legacyConfig $localConfig
$legacy = Read-DailyConfig $legacyConfig
if ($legacy.Genshin.AutomationWidth -ne 1920 -or $legacy.Genshin.AutomationHeight -ne 1080 -or $legacy.Genshin.AutomationFullscreen) {
    throw 'Legacy configuration defaults were not applied.'
}
$ready = & (Join-Path $project 'Run-Daily.cmd') -PreflightOnly -ConfigPath $configPath | Out-String | ConvertFrom-Json
if ($ready.Checks.Count -ne 3 -or @($ready.Checks | Where-Object { !$_.Ready }).Count) {
    throw ('Expected three passing adapter checks: ' + ($ready | ConvertTo-Json -Depth 10 -Compress))
}
if ($ready.Checks[0].Detail.AutomationWidth -ne 1600 -or $ready.Checks[0].Detail.AutomationHeight -ne 900 -or !$ready.Checks[0].Detail.AutomationFullscreen) {
    throw 'Genshin display settings did not reach the adapter preflight.'
}
if (!$ready.Ready -and !$ready.ConflictingProcesses.Count) { throw 'Suite preflight did not report a conflict.' }
$windowHost = Join-Path $project 'runner/GameDailyHost.cs'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type -Path $windowHost -ReferencedAssemblies System.Windows.Forms,System.Drawing
& (Join-Path $project 'Open-Dashboard.cmd') -CheckOnly -ConfigPath $configPath
if ($LASTEXITCODE) { throw 'Dashboard configuration check failed.' }

Import-Module (Join-Path $project 'adapters/endfield/MaaEndStartupEvidence.psm1') -Force
$log = Join-Path $fixture 'startup.log'
@'
[2026-01-01 12:00:01.000] [msg=Node.PipelineNode.Failed] [details={"name":"__ScenePrivateLoginContinue","reason":"recognition_timeout","task_id":1}]
[2026-01-01 12:00:01.100] task failed
[2026-01-01 12:00:04.000] [msg=Node.PipelineNode.Failed] [details={"name":"__ScenePrivateLoginContinue","reason":"recognition_timeout","task_id":7}]
[2026-01-01 12:00:04.300] task failed
'@ | Set-Content -LiteralPath $log -Encoding UTF8
$events = @(
    @{status='failed';task='First';event=@{At='2026-01-01T12:00:01.100+08:00';Entry='First';File=$log;Line=2;Uuid='1'}}
    @{status='failed';task='Second';event=@{At='2026-01-01T12:00:04.300+08:00';Entry='Second';File=$log;Line=4;Uuid='1'}}
)
$block = Get-MaaEndStartupBlock -FrameworkEvidence @{PerTask=$events}
if ($block.code -ne 'title-screen-transition-timeout' -or $block.evidence.Count -ne 2) { throw 'Startup block was missed.' }
$events[1].status = 'succeeded'
if (Get-MaaEndStartupBlock -FrameworkEvidence @{PerTask=$events}) { throw 'A recovered startup was misclassified.' }
$startScript = Join-Path $project 'dashboard/Start-Dashboard.ps1'
$missing = Join-Path $fixture 'missing.json'
$failed = $false
try { & $startScript -CheckOnly -ConfigPath $missing } catch { $failed = $_.Exception.Message -match 'configuration is missing' }
if (!$failed) { throw 'Dashboard did not reject a missing config.' }
Write-Output "Verified two entry points and native startup evidence. Fixture: $fixture"
