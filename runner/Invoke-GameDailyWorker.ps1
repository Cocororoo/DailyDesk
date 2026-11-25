[CmdletBinding()]
param([string]$Game='All',[string]$ResumeRunDirectory,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ControlDirectory)
$ErrorActionPreference='Stop'
$log=Join-Path $ControlDirectory 'entry.log'
try {
    & (Join-Path $PSScriptRoot 'Invoke-GameDailySuite.ps1') -Game $Game -ResumeRunDirectory $ResumeRunDirectory -ConfigPath $ConfigPath -ControlDirectory $ControlDirectory *>&1 | ForEach-Object {
        $_ | Out-File -LiteralPath $log -Append -Encoding UTF8
        if($_ -is [Management.Automation.ErrorRecord]){throw $_}
    }
    exit 0
} catch {
    $_ | Out-File -LiteralPath $log -Append -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $ControlDirectory 'worker-error.txt'),$_.Exception.Message,[Text.UTF8Encoding]::new($false))
    exit 1
}
