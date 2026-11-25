[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDirectory,
    [Parameter(Mandatory)][string]$DataDirectory,
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$InstallDirectory = (Resolve-Path -LiteralPath $InstallDirectory).Path
$cli = Join-Path $InstallDirectory 'm7a.exe'
$statusText = & $cli --status
if ($LASTEXITCODE -ne 0) { throw 'Cannot query March7th status.' }
$status = $statusText | ConvertFrom-Json
$config = Get-Content -LiteralPath $status.config_file -Raw -Encoding UTF8
function Read-Scalar([string]$Key) {
    $matchesFound = [regex]::Matches($config, ('(?m)^' + [regex]::Escape($Key) + ':[ \t]*([^\r\n#]*)(?:#[^\r\n]*)?\r?$'))
    if ($matchesFound.Count -ne 1) { throw ('Expected one YAML scalar: ' + $Key) }
    $matchesFound[0].Groups[1].Value.Trim().Trim('"',"'")
}
$nameBlock = [regex]::Match($config,'(?ms)^instance_names:\s*\r?\n(?<body>.*?)(?=^[^\s#][^\r\n]*:|\z)').Groups['body'].Value
$instanceType = Read-Scalar 'instance_type'
$target = [regex]::Match($nameBlock,('(?m)^  ' + [regex]::Escape($instanceType) + ':[ \t]*([^\r\n#]*)')).Groups[1].Value.Trim().Trim('"',"'")
$problems = @()
if (!$status.first_run_completed) { $problems += 'User must acknowledge first-run disclaimer in the native GUI.' }
if (!$status.game_path_exists) { $problems += 'Configured game path is missing.' }
if ($status.active_run) { $problems += 'A native March7th task is already running.' }
if ($instanceType -notin @('侵蚀隧洞','饰品提取') -or !$target -or $target -eq '无') { $problems += 'Expected a configured relic cavern or planar ornament extraction.' }
$disabledKeys = @('use_fuel','use_reserved_trailblaze_power','build_target_enable','break_down_level_four_relicset','weekly_relic_smart_discard_enable','echo_of_war_enable','activity_enable','borrow_enable','borrow_character_enable')
$nativeExample = Get-Content -LiteralPath (Join-Path $InstallDirectory 'assets\config\config.example.yaml') -Raw -Encoding UTF8
if ($config -match '(?m)^merge_immersifier:' -or $nativeExample -match '(?m)^merge_immersifier:') {
    $disabledKeys += 'merge_immersifier'
}
foreach ($key in $disabledKeys) {
    if ((Read-Scalar $key) -ne 'false') { $problems += ('Review unexpected enabled option: ' + $key) }
}
if ((Read-Scalar 'power_plan') -ne '[]') { $problems += 'A power plan would override the configured target.' }
if ((Read-Scalar 'power_enable') -ne 'true' -or (Read-Scalar 'daily_enable') -ne 'true' -or (Read-Scalar 'reward_enable') -ne 'true' -or (Read-Scalar 'reward_quest_enable') -ne 'true') { $problems += 'Power, daily or activity reward task is disabled.' }
$nativeNames = Get-Content -LiteralPath (Join-Path $InstallDirectory 'assets\config\instance_names.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (!$nativeNames.PSObject.Properties[$instanceType] -or !$nativeNames.$instanceType.PSObject.Properties[$target]) { $problems += 'Configured target is absent from the installed native list.' }
$preflight = [pscustomobject]@{Ready=($problems.Count -eq 0);InstallDirectory=$InstallDirectory;InstanceType=$instanceType;InstanceName=$target;Cavern=$(if($instanceType -eq '侵蚀隧洞'){$target}else{$null});FirstRunCompleted=[bool]$status.first_run_completed;Elevation=$status.elevation;Problems=$problems;Task='routine';AfterFinish='Exit'}
if ($PreflightOnly) { $preflight; return }
if ($problems.Count) { throw ($problems -join ' | ') }
$directory = Join-Path $DataDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$session = [pscustomobject][ordered]@{Schema='starrail-daily-session-v2';StartedAt=(Get-Date).ToString('o');InstallDirectory=$InstallDirectory;ExpectedInstanceType=$instanceType;ExpectedInstanceName=$target;ExpectedCavern=$(if($instanceType -eq '侵蚀隧洞'){$target}else{$null});NativeRunId=$null;ExitCode=$null;Status='running';Error=$null}
function Save-Session {
    $path=Join-Path $directory 'session.json'
    [IO.File]::WriteAllText(($path+'.tmp'), ($session | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace(($path+'.tmp'),$path,[NullString]::Value)}else{[IO.File]::Move(($path+'.tmp'),$path)}
}
Save-Session
[pscustomobject]@{SessionDirectory=$directory;Status='preparing'}
try {
    $consolePath = Join-Path $directory 'console.log'
    # Windows PowerShell 5.1 wraps redirected native stderr in ErrorRecords.
    # March7th logs ordinary progress there. Use its real exit code and run JSON.
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $cli routine --after-finish Exit --non-interactive --json 2>&1 |
            ForEach-Object {
                $line=$_.ToString()
                if($line -match '^\{.*"run_id".*\}$'){
                    try {$candidate=$line|ConvertFrom-Json;if($candidate.run_id){$session.NativeRunId=$candidate.run_id;Save-Session}}catch{}
                }
                $line
            } | Tee-Object -FilePath $consolePath | Out-Host
    } finally { $ErrorActionPreference = $previousErrorPreference }
    $session.ExitCode = $LASTEXITCODE
    $records = @(foreach ($line in [IO.File]::ReadAllLines($consolePath)) {
        if ($line -match '^\{.*"run_id".*\}$') {
            try { $candidate = $line | ConvertFrom-Json; if ($candidate.run_id) { $candidate } } catch { }
        }
    })
    if ($records.Count) { $session.NativeRunId = $records[-1].run_id }
    $session.Status = 'native_process_ended'
    Save-Session
    $result = & (Join-Path $PSScriptRoot 'Get-StarRailDailyResult.ps1') -SessionDirectory $directory
    if (!$result.NativeTasksSucceeded -or !$result.GameClosed) { throw ('Native task or game exit was not verified; review ' + $directory) }
    $session.Status = $result.Status
    Save-Session
    [pscustomobject]@{SessionDirectory=$directory;Result=$result}
} catch {
    $session.Status='needs_attention'; $session.Error=$_.Exception.Message; Save-Session
    throw ('StarRail daily needs attention: ' + $directory + ' | ' + $session.Error)
}
