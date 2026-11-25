function Get-MaaEndStartupBlock {
    [CmdletBinding()]
    param($FrameworkEvidence)

    $tasks = @($FrameworkEvidence.PerTask)
    if ($tasks.Count -lt 2 -or $tasks[0].status -ne 'failed' -or $tasks[1].status -ne 'failed') { return }
    if (@($tasks | Where-Object { $_.status -eq 'succeeded' -and $_.task -ne 'CloseGamePC' }).Count) { return }

    $firstFailures = $tasks[0..1].event
    if ($firstFailures[0].Uuid -ne $firstFailures[1].Uuid) { return }
    $proofs = @(foreach ($event in $firstFailures) {
        if (!$event.File -or !(Test-Path -LiteralPath $event.File -PathType Leaf)) { continue }
        $lineNumber = 0
        $lastTimeout = $null
        $terminalTime = ([datetimeoffset]$event.At).DateTime
        foreach ($line in [IO.File]::ReadLines($event.File)) {
            $lineNumber++
            if ($lineNumber -ge $event.Line) { break }
            if (!$line.Contains('__ScenePrivateLoginContinue')) { continue }
            if ($line -notmatch '^\[(?<at>[^\]]+)\].*\[msg=Node\.PipelineNode\.Failed\] \[details=(?<details>\{.*\})\]') { continue }
            try {
                $logTime = [datetime]::ParseExact($Matches.at, 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
                $data = $Matches.details | ConvertFrom-Json -ErrorAction Stop
            } catch { continue }
            # Native scene recovery runs in a nested task with its own task ID.
            $elapsed = ($terminalTime - $logTime).TotalSeconds
            if ($elapsed -lt 0 -or $elapsed -gt 2) { continue }
            if ($data.name -eq '__ScenePrivateLoginContinue' -and $data.reason -eq 'recognition_timeout') {
                $lastTimeout = [pscustomobject]@{ task = $event.Entry; file = $event.File; line = $lineNumber }
            }
        }
        if ($lastTimeout) { $lastTimeout }
    })
    if ($proofs.Count -eq 2) {
        [pscustomobject]@{ code = 'title-screen-transition-timeout'; evidence = $proofs }
    }
}

Export-ModuleMember -Function Get-MaaEndStartupBlock
