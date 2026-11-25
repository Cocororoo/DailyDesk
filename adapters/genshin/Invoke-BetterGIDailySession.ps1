[CmdletBinding(DefaultParameterSetName='Run')]
param(
    [Parameter(Mandatory,ParameterSetName='Run')][string]$BgiRoot,
    [Parameter(Mandatory,ParameterSetName='Run')][ValidatePattern('^[\p{L}\p{N}_ -]+$')][string]$Profile,
    [Parameter(Mandatory,ParameterSetName='Run')][string]$DataDirectory,
    [Parameter(ParameterSetName='Run')][bool]$ManageDisplay = $true,
    [Parameter(ParameterSetName='Run')][ValidateRange(640,7680)][int]$AutomationWidth = 1920,
    [Parameter(ParameterSetName='Run')][ValidateRange(480,4320)][int]$AutomationHeight = 1080,
    [Parameter(ParameterSetName='Run')][bool]$AutomationFullscreen = $false,
    [Parameter(ParameterSetName='Run')][string]$GameDay,
    [Parameter(ParameterSetName='Run')][ValidateRange(5,180)][int]$TimeoutMinutes = 45,
    [Parameter(ParameterSetName='Run')][switch]$PreflightOnly,
    [Parameter(Mandatory,ParameterSetName='Recover')][string]$RecoverSessionDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GenshinDisplay.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../runner/Configuration.psm1') -Force

function Restore-SessionDisplay($State, [string]$Directory) {
    if ($State.ManageDisplay) {
        if (Get-Process -Name BetterGI,YuanShen,GenshinImpact -ErrorAction SilentlyContinue) {
            throw 'Close Genshin and BetterGI before restoring display preferences.'
        }
        $before = $State.DisplayBefore
        $State.RestoredDisplay = Set-GenshinDisplayPreference -RegistrySubKey $State.RegistrySubKey -Width $before.Width.Value -Height $before.Height.Value -Fullscreen $before.Fullscreen.Value
    }
    $State.DisplayPreferenceRestored = $true
    Write-DailyJson (Join-Path $Directory 'session.json') $State
}

if ($PSCmdlet.ParameterSetName -eq 'Recover') {
    $sessionPath = Join-Path $RecoverSessionDirectory 'session.json'
    $session = Get-Content -LiteralPath $sessionPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($session.Schema -ne 'dailydesk-bettergi-session-v1') { throw 'Unrecognized session manifest.' }
    Restore-SessionDisplay $session $RecoverSessionDirectory
    return $session
}

$exe = Join-Path $BgiRoot 'BetterGI.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'BetterGI.exe is missing.' }
$config = Get-Content -LiteralPath (Join-Path $BgiRoot 'User/config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$flow = Get-Content -LiteralPath (Join-Path $BgiRoot "User/OneDragon/$Profile.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ($flow.Name -cne $Profile -or $flow.CompletionAction -ne '关闭游戏和软件') {
    throw 'Set the configured OneDragon profile to close the game and BetterGI after completion.'
}
$gamePath = $config.genshinStartConfig.installPath
if (!$gamePath -or !(Test-Path -LiteralPath $gamePath -PathType Leaf) -or !$config.genshinStartConfig.linkedStartEnabled) {
    throw 'Configure and enable linked Genshin launch in BetterGI.'
}
$autoDomain = $config.autoDomainConfig
if ($autoDomain.autoArtifactSalvage -or $autoDomain.fragileResinUseCount -gt 0 -or $autoDomain.transientResinUseCount -gt 0) {
    throw 'Disable artifact salvage, fragile resin and transient resin in BetterGI.'
}
$dayProperty = $GameDay + 'DomainName'
$domain = if ($flow.WeeklyDomainEnabled -and $flow.$dayProperty) { $flow.$dayProperty } else { $flow.DomainName }
$displayBefore = $null
$registryKey = $null
if ($ManageDisplay) {
    $registryKey = switch ([IO.Path]::GetFileName($gamePath)) {
        'YuanShen.exe' { 'SOFTWARE\miHoYo\原神' }
        'GenshinImpact.exe' { 'SOFTWARE\miHoYo\Genshin Impact' }
        default { throw 'Unsupported Genshin executable for display management.' }
    }
    $displayBefore = Get-GenshinDisplayPreference -RegistrySubKey $registryKey
    if ($displayBefore.Fullscreen.Value -notin @(0, 1) -or $displayBefore.Width.Value -notin (640..7680) -or $displayBefore.Height.Value -notin (480..4320)) {
        throw 'Open Genshin once and save a supported display mode before enabling display management.'
    }
    $argsText = [string]$config.genshinStartConfig.genshinStartArgs
    foreach ($dimension in @{width=$AutomationWidth;height=$AutomationHeight}.GetEnumerator()) {
        if ($argsText -match ('-screen-' + $dimension.Key + '\s+(\d+)') -and [int]$Matches[1] -ne $dimension.Value) {
            throw ('BetterGI game launch arguments override the configured ' + $AutomationWidth + 'x' + $AutomationHeight + ' resolution.')
        }
    }
    if ($argsText -match '-screen-fullscreen\s+(\d+)' -and [int]$Matches[1] -ne [int]$AutomationFullscreen) {
        throw 'BetterGI game launch arguments override the configured fullscreen mode.'
    }
}
if (Get-Process -Name BetterGI,YuanShen,GenshinImpact -ErrorAction SilentlyContinue) {
    throw 'Close Genshin and BetterGI before starting a daily session.'
}
if ($PreflightOnly) {
    return [pscustomobject]@{ Ready=$true; Profile=$Profile; ExpectedDomain=$domain; ManageDisplay=$ManageDisplay; AutomationWidth=$AutomationWidth; AutomationHeight=$AutomationHeight; AutomationFullscreen=$AutomationFullscreen }
}

$directory = New-DailyRunDirectory $DataDirectory
$sessionPath = Join-Path $directory 'session.json'
$manifestPath = Join-Path $directory 'run.json'
$session = [pscustomobject][ordered]@{
    Schema='dailydesk-bettergi-session-v1'; StartedAt=(Get-Date).ToString('o'); Status='preparing'
    RunDirectory=$directory; GamePath=$gamePath; ManageDisplay=$ManageDisplay; RegistrySubKey=$registryKey
    DisplayBefore=$displayBefore; RestoredDisplay=$null; DisplayPreferenceRestored=$false
    NativeEnded=$false; GameClosed=$false; BetterGIClosed=$false; Error=$null
}
$offsets = @{}
foreach ($log in @(Get-ChildItem (Join-Path $BgiRoot 'log') -Filter 'better-genshin-impact*.log' -File -ErrorAction SilentlyContinue)) {
    $offsets[$log.Name] = $log.Length
}
$run = [ordered]@{
    StartedAt=$session.StartedAt; BgiRoot=$BgiRoot; Profile=$Profile; ExpectedDomain=$domain
    AutomationWidth=$AutomationWidth; AutomationHeight=$AutomationHeight; AutomationFullscreen=$AutomationFullscreen
    LogOffsets=$offsets
}
Write-DailyJson $sessionPath $session
Write-DailyJson $manifestPath $run
[pscustomobject]@{ SessionDirectory=$directory; Status='preparing' }
$restorePending = $false
try {
    if ($ManageDisplay) {
        $null = Set-GenshinDisplayPreference -RegistrySubKey $registryKey -Width $AutomationWidth -Height $AutomationHeight -Fullscreen ([int]$AutomationFullscreen)
        $restorePending = $true
    }
    $process = Start-Process -FilePath $exe -WorkingDirectory $BgiRoot -ArgumentList ('startOneDragon "' + $Profile + '"') -WindowStyle Hidden -PassThru
    $session.Status = 'running'
    Write-DailyJson $sessionPath $session
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $startDeadline = (Get-Date).AddMinutes(2)
    do {
        $result = & (Join-Path $PSScriptRoot 'Get-BetterGIDailyResult.ps1') -RunDirectory $directory
        $session.NativeEnded = [bool]$result.NativeEnded
        $session.GameClosed = !(Get-Process -Name YuanShen,GenshinImpact -ErrorAction SilentlyContinue)
        $session.BetterGIClosed = !(Get-Process -Name BetterGI -ErrorAction SilentlyContinue)
        if ($session.GameClosed -and $session.BetterGIClosed -and $process.HasExited) { break }
        if (!$result.ProfileStarted -and (Get-Date) -gt $startDeadline) {
            throw 'BetterGI did not log a daily start within two minutes. Check its window for a login or initialization prompt.'
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    if (!$session.GameClosed -or !$session.BetterGIClosed) { throw 'Timed out waiting for BetterGI to close the game and itself.' }
    $run.LogsFrozenAt = (Get-Date).ToString('o')
    Write-DailyJson $manifestPath $run
    $session.Status = 'native_process_ended'
    Restore-SessionDisplay $session $directory
    $restorePending = $false
    [pscustomobject]@{ SessionDirectory=$directory; Result=$result }
} catch {
    $session.Status = 'needs_attention'
    $session.Error = $_.Exception.Message
    if ($restorePending -and !(Get-Process -Name BetterGI,YuanShen,GenshinImpact -ErrorAction SilentlyContinue)) {
        try { Restore-SessionDisplay $session $directory } catch { $session.Error += ' | Display restoration: ' + $_.Exception.Message }
    }
    Write-DailyJson $sessionPath $session
    throw
}
