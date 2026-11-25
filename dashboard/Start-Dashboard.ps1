[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateRange(1024,65535)][int]$Port = 17861,
    [switch]$CheckOnly
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
& $python @arguments $server --config $config.ConfigPath --port $Port --open
exit $LASTEXITCODE
