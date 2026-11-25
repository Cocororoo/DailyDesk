[CmdletBinding()]
param(
    [ValidateSet('All','Genshin','StarRail','Endfield')][string]$Game='All',
    [string]$ResumeRunDirectory,
    [string]$ConfigPath,
    [switch]$PreflightOnly
)
$ErrorActionPreference='Stop'
if ($PreflightOnly) {
    try {
        $check = & (Join-Path $PSScriptRoot 'Invoke-GameDailySuite.ps1') -Game $Game -ConfigPath $ConfigPath -ResumeRunDirectory $ResumeRunDirectory -PreflightOnly
        $check | ConvertTo-Json -Depth 12
        exit $(if($check.Ready){0}else{1})
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}
try {
    Import-Module (Join-Path $PSScriptRoot 'Configuration.psm1') -Force
    $config=Read-DailyConfig $ConfigPath
    $ConfigPath=$config.ConfigPath
    $hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Game {1} -ConfigPath "{2}"' -f $PSCommandPath,$Game,$ConfigPath
        if($ResumeRunDirectory){$arguments+=' -ResumeRunDirectory "'+$ResumeRunDirectory+'"'}
        $p=Start-Process -FilePath $hostExe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        exit $p.ExitCode
    }
    $mutex=[Threading.Mutex]::new($false,'Local\ThreeGameDailyWindow')
    $locked=$false
    try {
        try {$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(!$locked){throw '每日上班已打开，请使用现有窗口。'}
        $directory=Join-Path $config.HistoryRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Path $directory -Force|Out-Null
        $settings=[ordered]@{Schema='daily-supervisor-v1';StartedAt=(Get-Date).ToString('o');GameDay=(Get-DailyGameDay $config).ToString('yyyy-MM-dd');Game=$Game;SupervisorId=$PID;StarRailInstallDirectory=$config.StarRail.Directory}
        Write-DailyJson (Join-Path $directory 'supervisor.json') $settings
        Add-Type -AssemblyName System.Windows.Forms,System.Drawing
        Add-Type -Path (Join-Path $PSScriptRoot 'GameDailyHost.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing
        $code=[GameDaily.DailyWindow]::Run($hostExe,$PSScriptRoot,$directory,$Game,$ResumeRunDirectory,$ConfigPath,'',0)
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
    exit $code
} catch {
    $shell=New-Object -ComObject WScript.Shell
    $null=$shell.Popup($_.Exception.Message,0,'每日上班需要处理',48)
    exit 1
}
