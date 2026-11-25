[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MaaRoot,
    [Parameter(Mandatory)][string]$InstanceName,
    [Parameter(Mandatory)][string]$DataDirectory,
    [ValidateRange(1024,65535)][int]$ApiPort = 12701,
    [switch]$PreflightOnly,
    [switch]$QuitAfterRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../runner/Configuration.psm1') -Force
if ($InstanceName -match '["\\\p{Cc}]') { throw 'MaaEnd instance names cannot contain quotes, backslashes or control characters.' }
$exe = Join-Path $MaaRoot 'MaaEnd.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'MaaEnd.exe is missing.' }
$configPath = Join-Path $MaaRoot 'config/mxu-MaaEnd.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$instances = @($config.instances | Where-Object name -CEQ $InstanceName)
if ($instances.Count -ne 1) { throw 'Configure a unique native MaaEnd instance with the selected name.' }
$instance = $instances[0]
if (!$config.settings.webServerEnabled -or $config.settings.webServerPort -ne $ApiPort) {
    throw 'Enable MaaEnd local Web API and match the configured API port.'
}
if ($instance.id -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid native MaaEnd instance identifier.' }
$tasks = @($instance.tasks | Where-Object {
    $_.enabled -and $_.taskName -notlike '__MXU_PRETASK__*' -and
        (!$_.enabledByController -or $_.enabledByController.($instance.controllerName) -ne $false)
} | Select-Object id,taskName)
if (!$tasks.Count -or @($tasks | Where-Object id -NotMatch '^[a-zA-Z0-9_-]+$').Count -or
        @($tasks.id | Select-Object -Unique).Count -ne $tasks.Count) {
    throw 'MaaEnd instance must have at least one enabled task and unique task identifiers.'
}
if (Get-Process MaaEnd,Endfield -ErrorAction SilentlyContinue) { throw 'Close MaaEnd and Endfield before using this entry.' }
if ($PreflightOnly) {
    return [pscustomobject]@{Ready=$true;Instance=$InstanceName;Controller=$instance.controllerName;TaskCount=$tasks.Count}
}

$runDir = New-DailyRunDirectory $DataDirectory
$logs = @(Get-ChildItem -LiteralPath (Join-Path $MaaRoot 'debug') -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    @{path=$_.FullName;length=$_.Length;created_utc_ticks=$_.CreationTimeUtc.Ticks}
})
$metadata = [ordered]@{
    run_id = Split-Path -Leaf $runDir
    started_at = (Get-Date).ToString('o')
    maaend_root = $MaaRoot
    instance_name = $InstanceName
    instance_id = $instance.id
    controller = $instance.controllerName
    quit_after_run = [bool]$QuitAfterRun
    api_base = "http://127.0.0.1:$ApiPort"
    expected_tasks = $tasks
    launched = $true
    log_baselines = $logs
}
Write-DailyJson (Join-Path $runDir 'run-metadata.json') $metadata
[pscustomobject]@{run_dir=$runDir;Status='preparing'}
$launch = @{
    MaaRoot=$MaaRoot
    SessionTemp=(Join-Path $DataDirectory 'temp')
    LaunchReceipt=(Join-Path $runDir 'launch-receipt.json')
    InstanceName=$InstanceName
    QuitAfterRun=[bool]$QuitAfterRun
}
$null = & (Join-Path $PSScriptRoot 'Start-MaaEndWithEnvironment.ps1') @launch
