[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateRange(1024,65535)][int]$Port = 17861,
    [ValidateSet('overview','plans','history','updates')][string]$Page = 'overview',
    [switch]$CheckOnly,
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../runner/Configuration.psm1') -Force
$config = Read-DailyConfig $ConfigPath
$candidates = @(Get-Command py.exe,python.exe -ErrorAction SilentlyContinue)
$python = $null
foreach ($candidate in $candidates) {
    $arguments = @()
    if ($candidate.Name -eq 'py.exe') { $arguments = @('-3') }
    & $candidate.Source @arguments -c 'import sys; sys.exit(sys.version_info < (3, 10))'
    if ($LASTEXITCODE -eq 0) { $python = $candidate.Source; break }
}
if (!$python) { throw 'Install Python 3.10 or later and add it to PATH.' }
$server = Join-Path $PSScriptRoot 'server.py'
if ($CheckOnly) {
    & $python @arguments $server --config $config.ConfigPath --check
    exit $LASTEXITCODE
}
$url = "http://127.0.0.1:$Port"
$mutex = [Threading.Mutex]::new($false, "Local\DailyDeskDashboard-$Port")
$locked = $false
function Test-DashboardReady {
    try {
        $health = Invoke-RestMethod "$url/api/health" -TimeoutSec 1
        return $health.app -eq 'daily-desk' -and $health.configPath -eq $config.ConfigPath
    } catch { return $false }
}
try {
    try { $locked = $mutex.WaitOne(20000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'DailyDesk dashboard is still starting.' }
    if (!(Test-DashboardReady)) {
        $logs = Join-Path $config.DataRoot 'dashboard'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $serverArgs = $arguments + @(('"{0}"' -f $server), '--config', ('"{0}"' -f $config.ConfigPath), '--port', $Port)
        $process = Start-Process -FilePath $python -ArgumentList $serverArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logs 'server.log') -RedirectStandardError (Join-Path $logs 'server-error.log')
        $ready = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            if ($process.HasExited) { break }
            if (Test-DashboardReady) { $ready = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (!$ready) { throw ('DailyDesk dashboard failed to start. See ' + (Join-Path $logs 'server-error.log')) }
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if (!$NoOpen) { Start-Process "$url/#$Page" }
