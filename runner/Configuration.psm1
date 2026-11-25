function Read-DailyConfig {
    param([string]$Path)
    $project = Split-Path $PSScriptRoot -Parent
    if (!$Path) { $Path = Join-Path $project 'config.local.json' }
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Local configuration is missing. Run Setup.ps1 first.'
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.SchemaVersion -ne 1) { throw 'Unsupported config schema.' }
    $games = @($config.Sequence)
    if ($games.Count -ne 3 -or @($games | Where-Object {$_ -cnotin 'Genshin','StarRail','Endfield'}).Count -or
        @($games | Select-Object -Unique).Count -ne $games.Count) { throw 'Sequence must contain all three game identifiers once.' }
    if ($config.ResetHour -isnot [int] -or $config.ResetHour -notin (0..23)) { throw 'Invalid ResetHour.' }
    $null = [TimeZoneInfo]::FindSystemTimeZoneById($config.GameTimeZone)
    $configDir = Split-Path $Path -Parent
    function Resolve-ConfiguredPath([string]$Value) {
        if (!$Value) { throw 'Required directory is empty in local configuration.' }
        if (![IO.Path]::IsPathRooted($Value)) { $Value = Join-Path $configDir $Value }
        [IO.Path]::GetFullPath($Value)
    }
    $dataDirectory = Resolve-ConfiguredPath $config.DataDirectory
    foreach ($game in $games) {
        if (!$config.$game) { throw "Missing configuration for $game." }
        $config.$game.Directory = Resolve-ConfiguredPath $config.$game.Directory
    }
    if ($config.Genshin.AutomationWidth -eq $null) { $config.Genshin | Add-Member NoteProperty AutomationWidth 1920 }
    if ($config.Genshin.AutomationHeight -eq $null) { $config.Genshin | Add-Member NoteProperty AutomationHeight 1080 }
    if ($config.Genshin.AutomationFullscreen -eq $null) { $config.Genshin | Add-Member NoteProperty AutomationFullscreen $false }
    if ($config.Genshin.AutomationWidth -notin (640..7680) -or $config.Genshin.AutomationHeight -notin (480..4320) -or
        $config.Genshin.AutomationFullscreen -isnot [bool]) { throw 'Invalid Genshin automation display settings.' }
    if ($config.Genshin.LocalScripts) {
        $config.Genshin.LocalScripts = Resolve-ConfiguredPath $config.Genshin.LocalScripts
        foreach ($script in 'Invoke-BetterGIDailySession.ps1','Get-BetterGIDailyResult.ps1') {
            if (!(Test-Path -LiteralPath (Join-Path $config.Genshin.LocalScripts $script) -PathType Leaf)) {
                throw "Local Genshin integration is missing $script."
            }
        }
    }
    $config | Add-Member NoteProperty ConfigPath $Path
    $config | Add-Member NoteProperty DataRoot $dataDirectory
    $config | Add-Member NoteProperty RunRoot (Join-Path $dataDirectory 'runs')
    $config | Add-Member NoteProperty HistoryRoot (Join-Path $dataDirectory 'history')
    $config
}

function Get-DailyGameDay {
    param($Config, [datetimeoffset]$At = [datetimeoffset]::Now)
    [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($At, $Config.GameTimeZone).AddHours(-$Config.ResetHour)
}

function Get-DailyProcesses {
    Get-Process -Name YuanShen,GenshinImpact,BetterGI,StarRail,Endfield,MaaEnd,'March7th Assistant',m7a -ErrorAction SilentlyContinue
}

function New-DailyRunDirectory {
    param([Parameter(Mandatory)][string]$Parent)
    $name = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    (New-Item -ItemType Directory -Path (Join-Path $Parent $name) -Force).FullName
}

function Write-DailyJson {
    param([string]$Path, $Value)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

Export-ModuleMember -Function Read-DailyConfig,Get-DailyGameDay,Get-DailyProcesses,New-DailyRunDirectory,Write-DailyJson
