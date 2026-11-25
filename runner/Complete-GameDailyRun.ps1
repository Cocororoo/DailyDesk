[CmdletBinding()]
param([Parameter(Mandatory)][string]$ControlDirectory,[Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$adapters=Join-Path (Split-Path $PSScriptRoot -Parent) 'adapters'
Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
$config = Read-DailyConfig $ConfigPath
$genshinScripts = if ($config.Genshin.LocalScripts) { $config.Genshin.LocalScripts } else { Join-Path $adapters 'genshin' }
$receipt=[ordered]@{At=(Get-Date).ToString('o');Cancelled=$false;DisplayRecovered=$null;Errors=@()}
function Save-FinalSuite($Path,$Value){
    $temp=$Path+'.finalizing'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temp,$Path,[NullString]::Value)
}
try {
    $cancelled=Test-Path -LiteralPath (Join-Path $ControlDirectory 'cancel-request.json')
    $receipt.Cancelled=$cancelled
    $pointer=Join-Path $ControlDirectory 'suite-run.txt'
    if(Test-Path -LiteralPath $pointer){
        $run=[IO.File]::ReadAllText($pointer).Trim()
        $suitePath=Join-Path $run 'suite-result.json'
        $suite=Get-Content -Raw -Encoding UTF8 -LiteralPath $suitePath|ConvertFrom-Json
        $stage=$suite.Stages|Select-Object -Last 1
        if($cancelled){
            $suite.Status='cancelled';$suite.FinishedAt=(Get-Date).ToString('o');$suite.Error='用户关闭每日上班窗口；本轮未完成。'
            if($stage -and !$stage.NativeCompleted){$stage.Status='cancelled';$stage.FinishedAt=$suite.FinishedAt;$stage.Error=$suite.Error}
            Save-FinalSuite $suitePath $suite
        }
        if($stage.Game -eq 'Genshin' -and $stage.EvidenceDirectory){
            $sessionPath=Join-Path $stage.EvidenceDirectory 'session.json'
            $session=Get-Content -Raw -Encoding UTF8 -LiteralPath $sessionPath|ConvertFrom-Json
            if($session.RunDirectory){
                try {$null=& (Join-Path $genshinScripts 'Get-BetterGIDailyResult.ps1') -RunDirectory $session.RunDirectory;$stage.ResultFile=Join-Path $session.RunDirectory 'result.json'}catch{$receipt.Errors+=$_.Exception.Message}
            }
            if($cancelled -and !(Get-Process BetterGI,YuanShen,GenshinImpact -ErrorAction SilentlyContinue)){
                try {
                    $null=& (Join-Path $genshinScripts 'Invoke-BetterGIDailySession.ps1') -RecoverSessionDirectory $stage.EvidenceDirectory
                    $session=Get-Content -Raw -Encoding UTF8 -LiteralPath $sessionPath|ConvertFrom-Json
                    $session.Status='cancelled_display_restored';$session.GameClosed=$true;$session.BetterGIClosed=$true
                    $session.Error='用户关闭每日上班窗口；显示偏好已恢复，日常完成情况仍须核验。'
                    [IO.File]::WriteAllText($sessionPath,($session|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
                    $receipt.DisplayRecovered=$true
                }catch{$receipt.DisplayRecovered=$false;$receipt.Errors+=$_.Exception.Message}
            }
        }
        if($cancelled -and $stage.Game -eq 'StarRail' -and $stage.EvidenceDirectory){
            try {$null=& (Join-Path $adapters 'starrail\Get-StarRailDailyResult.ps1') -SessionDirectory $stage.EvidenceDirectory;$stage.ResultFile=Join-Path $stage.EvidenceDirectory 'result.json'}catch{$receipt.Errors+=$_.Exception.Message}
        }
        Save-FinalSuite $suitePath $suite
    }
} catch {$receipt.Errors+=$_.Exception.Message}
$receipt|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $ControlDirectory 'finalize-receipt.json') -Encoding UTF8
try {
    & (Join-Path $PSScriptRoot 'Get-GameDailyReport.ps1') -ControlDirectory $ControlDirectory -ConfigPath $ConfigPath|Out-Null
    if($receipt.Errors.Count){exit 1}
} catch {$_|Out-File -LiteralPath (Join-Path $ControlDirectory 'report-error.log') -Encoding UTF8;exit 1}
