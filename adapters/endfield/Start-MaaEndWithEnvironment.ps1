[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MaaRoot,
    [Parameter(Mandatory)][string]$SessionTemp,
    [Parameter(Mandatory)][string]$LaunchReceipt,
    [Parameter(Mandatory)][string]$InstanceName,
    [switch]$NoAutoStart,
    [switch]$QuitAfterRun
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    # ShellExecute/runas rebuilds the environment. Elevate this helper first, then
    # set the app-only TEMP/TMP inside the elevated process, not its caller.
    $hostExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = Join-Path $PSHOME 'pwsh.exe' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -MaaRoot "{1}" -SessionTemp "{2}" -LaunchReceipt "{3}" -InstanceName "{4}"' -f $PSCommandPath,$MaaRoot,$SessionTemp,$LaunchReceipt,$InstanceName
    if ($NoAutoStart) { $arguments += ' -NoAutoStart' }
    if ($QuitAfterRun) { $arguments += ' -QuitAfterRun' }
    $helper = Start-Process -FilePath $hostExe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $LaunchReceipt) -and (Get-Date) -lt $deadline) {
        if ($helper.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $LaunchReceipt)) {
        throw "Elevated launch did not produce a receipt. Inspect the UAC prompt or helper. Helper PID: $($helper.Id)"
    }
    $receipt = Get-Content -Encoding UTF8 -LiteralPath $LaunchReceipt -Raw | ConvertFrom-Json
    if ($receipt.error) { throw $receipt.error }
    $receipt | ConvertTo-Json -Depth 8
    return
}

try {
    if (Get-Process MaaEnd -ErrorAction SilentlyContinue) { throw 'MaaEnd is already running.' }
    $MaaRoot = (Resolve-Path -LiteralPath $MaaRoot).Path
    New-Item -ItemType Directory -Path $SessionTemp -Force | Out-Null
    $SessionTemp = (Resolve-Path -LiteralPath $SessionTemp).Path
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $MaaRoot 'MaaEnd.exe'
    $info.WorkingDirectory = $MaaRoot
    $info.UseShellExecute = $false
    if (-not $NoAutoStart) {
        $info.Arguments = '--autostart --instance "' + $InstanceName + '"'
        if ($QuitAfterRun) { $info.Arguments += ' --quit-after-run' }
    }
    $info.EnvironmentVariables['TEMP'] = $SessionTemp
    $info.EnvironmentVariables['TMP'] = $SessionTemp
    $process = [Diagnostics.Process]::Start($info)
    $receipt = [ordered]@{
        at = (Get-Date).ToString('o')
        process_id = $process.Id
        elevated_helper = $true
        temp = $SessionTemp
        tmp = $SessionTemp
        arguments = $info.Arguments
        quit_after_run = [bool]$QuitAfterRun
        executable = $info.FileName
        working_directory = $MaaRoot
        environment_scope = 'MaaEnd and child processes only'
    }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $LaunchReceipt -Encoding UTF8
    $receipt | ConvertTo-Json -Depth 8
} catch {
    [ordered]@{at=(Get-Date).ToString('o');error=$_.Exception.Message} | ConvertTo-Json |
        Set-Content -LiteralPath $LaunchReceipt -Encoding UTF8
    throw
}
