[CmdletBinding()]
param(
    [ValidateSet('Status','Launch')][string]$Action,
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('All','Genshin','StarRail','Endfield')][string]$Game='All'
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$runner = Join-Path $PSScriptRoot '../runner'
Import-Module (Join-Path $runner 'Configuration.psm1') -Force
$config = Read-DailyConfig $ConfigPath
if($Action -eq 'Status'){
    $processes=@(Get-DailyProcesses | ForEach-Object {@{id=$_.Id;name=$_.ProcessName}})
    $supervisors=@(foreach($directory in Get-ChildItem -LiteralPath $config.HistoryRoot -Directory -ErrorAction SilentlyContinue){
        $file=Join-Path $directory.FullName 'supervisor.json'
        if(!(Test-Path -LiteralPath $file)){continue}
        try{
            $settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $file|ConvertFrom-Json
            $process=Get-Process -Id $settings.SupervisorId -ErrorAction Stop
            if($process.ProcessName -notin @('powershell','pwsh') -or [Math]::Abs(($process.StartTime-[datetime]$settings.StartedAt).TotalSeconds) -gt 10){continue}
            @{pid=$process.Id;runId=$directory.Name}
        }catch{}
    })
    @{processes=$processes;supervisors=$supervisors;gameDay=(Get-DailyGameDay $config).ToString('yyyy-MM-dd')}|ConvertTo-Json -Depth 5 -Compress
    exit 0
}
# The browser never invokes game executables. Preserve the same supervised entry,
# elevation, mutex, process ownership and cancellation behavior as the shortcut.
Start-Sleep -Milliseconds 350
& (Join-Path $runner 'Start-GameDailySuite.ps1') -Game $Game -ConfigPath $ConfigPath
exit $LASTEXITCODE
