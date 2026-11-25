[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BetterGI,
    [Parameter(Mandatory)][string]$BetterGIProfile,
    [Parameter(Mandatory)][string]$March7th,
    [Parameter(Mandatory)][string]$MaaEnd,
    [Parameter(Mandatory)][string]$MaaEndInstance,
    [ValidateRange(1024,65535)][int]$MaaEndApiPort = 12701,
    [string]$SevenZip = '',
    [string]$DataDirectory = 'data',
    [string]$GameTimeZone = 'China Standard Time',
    [ValidateRange(0,23)][int]$ResetHour = 4,
    [ValidateRange(640,7680)][int]$GenshinAutomationWidth = 1920,
    [ValidateRange(480,4320)][int]$GenshinAutomationHeight = 1080,
    [switch]$GenshinAutomationFullscreen,
    [switch]$LeaveGenshinDisplay,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.local.json')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'runner/Configuration.psm1') -Force
$ConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if (Test-Path -LiteralPath $ConfigPath) { throw 'This configuration already exists.' }
foreach ($requirement in @(
    @{Path=$BetterGI; File='BetterGI.exe'},
    @{Path=$March7th; File='m7a.exe'},
    @{Path=$MaaEnd; File='MaaEnd.exe'}
)) {
    if (!(Test-Path -LiteralPath (Join-Path $requirement.Path $requirement.File) -PathType Leaf)) {
        throw ('Select the installation directory containing ' + $requirement.File)
    }
}
if ($BetterGIProfile -notmatch '^[\p{L}\p{N}_ -]+$' -or
    !(Test-Path -LiteralPath (Join-Path $BetterGI "User/OneDragon/$BetterGIProfile.json") -PathType Leaf)) {
    throw 'Select an existing BetterGI OneDragon profile.'
}
if ($MaaEndInstance -match '["\\\p{Cc}]') { throw 'Unsupported MaaEnd instance name.' }
$null = [TimeZoneInfo]::FindSystemTimeZoneById($GameTimeZone)
if (!$DataDirectory.Trim()) { throw 'DataDirectory cannot be empty.' }
$config = [ordered]@{
    SchemaVersion=1
    DataDirectory=$DataDirectory
    GameTimeZone=$GameTimeZone
    ResetHour=$ResetHour
    SevenZip=$(if($SevenZip){(Resolve-Path -LiteralPath $SevenZip).Path}else{''})
    Sequence=@('Genshin','StarRail','Endfield')
    Genshin=@{
        Directory=(Resolve-Path -LiteralPath $BetterGI).Path
        Profile=$BetterGIProfile
        ManageDisplay=![bool]$LeaveGenshinDisplay
        AutomationWidth=$GenshinAutomationWidth
        AutomationHeight=$GenshinAutomationHeight
        AutomationFullscreen=[bool]$GenshinAutomationFullscreen
    }
    StarRail=@{Directory=(Resolve-Path -LiteralPath $March7th).Path}
    Endfield=@{Directory=(Resolve-Path -LiteralPath $MaaEnd).Path;Instance=$MaaEndInstance;ApiPort=$MaaEndApiPort}
}
$json = $config | ConvertTo-Json -Depth 5
$file = [IO.File]::Open($ConfigPath, 'CreateNew', 'Write', 'None')
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($json + [Environment]::NewLine)
    $file.Write($bytes, 0, $bytes.Length)
} finally { $file.Dispose() }
Write-Output "Saved $ConfigPath"
