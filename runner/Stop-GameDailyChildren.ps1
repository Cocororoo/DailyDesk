[CmdletBinding()]
param([Parameter(Mandatory)][string]$ControlDirectory,[Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$owned=@(Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $ControlDirectory 'owned-processes.json')|ConvertFrom-Json)
$processes=@(foreach($item in $owned){
    try {$p=Get-Process -Id $item.Id -ErrorAction Stop; if($p.StartTime.ToUniversalTime().Ticks -eq $item.StartedUtcTicks){$p}}catch{}
})
$receipt=[ordered]@{At=(Get-Date).ToString('o');NativeStop=@();CloseRequests=@()}
# Only address an assistant whose identity is inside this run's kernel job.
if(@($processes|Where-Object{$_.ProcessName -in @('m7a','March7th Assistant')}).Count){
    $status=Join-Path $ControlDirectory 'supervisor.json'
    $settings=Get-Content -Raw -Encoding UTF8 -LiteralPath $status|ConvertFrom-Json
    $cli=Join-Path $settings.StarRailInstallDirectory 'm7a.exe'
    if(Test-Path -LiteralPath $cli){
        $p=Start-Process -FilePath $cli -ArgumentList @('--control','current','stop') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ControlDirectory 'march7th-stop.log') -RedirectStandardError (Join-Path $ControlDirectory 'march7th-stop.err')
        $receipt.NativeStop+=@{Assistant='March7th';Requested=$true}
        $null=$p.WaitForExit(2000)
    }
}
if(@($processes|Where-Object{$_.ProcessName -eq 'MaaEnd'}).Count){
    $pointer=Join-Path $ControlDirectory 'suite-run.txt'
    if(Test-Path -LiteralPath $pointer){
        $run=[IO.File]::ReadAllText($pointer).Trim()
        $suite=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $run 'suite-result.json')|ConvertFrom-Json
        $stage=$suite.Stages|Where-Object{$_.Game -eq 'Endfield'}|Select-Object -Last 1
        if($stage.EvidenceDirectory){
            $meta=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $stage.EvidenceDirectory 'run-metadata.json')|ConvertFrom-Json
            $uri=[uri]$meta.api_base
            if(!$uri.IsLoopback){throw 'Refusing non-local assistant stop endpoint.'}
            foreach($operation in @('pretask/stop','tasks/stop')){
                try {$null=Invoke-RestMethod ($meta.api_base+'/api/maa/instances/'+$meta.instance_id+'/'+$operation) -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 2; $receipt.NativeStop+=@{Assistant='MaaEnd';Operation=$operation;Requested=$true}}catch{$receipt.NativeStop+=@{Assistant='MaaEnd';Operation=$operation;Error=$_.Exception.Message}}
            }
        }
    }
}
foreach($p in ($processes|Sort-Object @{Expression={if($_.ProcessName -match 'BetterGI|MaaEnd|March7th|m7a'){0}else{1}}})){
    try {if(!$p.HasExited -and $p.StartTime.ToUniversalTime().Ticks -eq ($owned|Where-Object{$_.Id -eq $p.Id}).StartedUtcTicks){$sent=$p.CloseMainWindow();$receipt.CloseRequests+=@{Id=$p.Id;Name=$p.ProcessName;Sent=$sent}}}catch{}
}
$receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $ControlDirectory 'graceful-stop.json') -Encoding UTF8
Start-Sleep -Seconds 3
