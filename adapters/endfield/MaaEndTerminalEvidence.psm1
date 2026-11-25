function Get-MaaEndFrameworkTaskEvidence {
    [CmdletBinding()]
    param($Metadata,$State,[string[]]$DeltaFiles,[datetimeoffset]$FinishedAt)
    $runtime=if($State){$State.instances.($Metadata.instance_id)}else{$null}
    $mapping=if($runtime){$runtime.task_run_state.mappings}else{$null}
    $start=[datetimeoffset]$Metadata.started_at
    $events=[Collections.Generic.List[object]]::new()
    $windowIds=@($State.cached_win32_windows|Where-Object{$_.window_name -eq 'Endfield'}|ForEach-Object{'{0:X16}' -f [long]$_.handle})
    # IDs restart in every MaaFramework process. Correlate this run's ID map,
    # game-window UUID, timestamps and paired start/end events, not bare IDs.
    foreach($file in $DeltaFiles){
        if([IO.Path]::GetFileName($file) -notlike '*maafw*.delta.log'){continue}
        $lineNumber=0
        foreach($line in [IO.File]::ReadLines($file)){
            $lineNumber++
            if($line -notmatch '^\[(?<at>[^\]]+)\].*\[msg=Tasker\.Task\.(?<status>Starting|Succeeded|Failed)\] \[details=(?<details>\{.*\})\]'){continue}
            $atText=$matches.at;$status=$matches.status;$details=$matches.details
            try {
                $clock=[datetime]::ParseExact($atText,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
                $at=[datetimeoffset]::new([datetime]::SpecifyKind($clock,[DateTimeKind]::Unspecified),$start.Offset)
                if($at -lt $start -or $at -gt $FinishedAt){continue}
                $event=$details|ConvertFrom-Json
                if(!$mapping -or !$mapping.PSObject.Properties[[string]$event.task_id] -or !$event.uuid -or $windowIds -notcontains $event.uuid.ToUpperInvariant()){continue}
                $events.Add([pscustomobject]@{At=$at.ToString('o');Status=$status;NativeTaskId=[string]$event.task_id;TaskId=[string]$mapping.([string]$event.task_id);Entry=$event.entry;Uuid=$event.uuid;File=$file;Line=$lineNumber})
            } catch {continue}
        }
    }
    $rows=@(foreach($task in $Metadata.expected_tasks){
        $taskEvents=@($events|Where-Object{$_.TaskId -eq $task.id}|Sort-Object At)
        $starts=@($taskEvents|Where-Object{$_.Status -eq 'Starting'})
        $failed=@($taskEvents|Where-Object{$_.Status -eq 'Failed'})
        $ends=@($taskEvents|Where-Object{$_.Status -eq 'Succeeded'})
        # Explicit matching avoids accepting an end event for a different entry
        # or a truncated log with only the tail of a previous task.
        $paired=@(foreach($end in $ends){if(@($starts|Where-Object{$_.NativeTaskId -eq $end.NativeTaskId -and $_.Uuid -eq $end.Uuid -and $_.Entry -eq $end.Entry -and $_.At -le $end.At}).Count){$end}})
        $verified=$paired.Count -gt 0 -and !$failed.Count
        $proof=if($failed.Count){$failed[-1]}elseif($verified){$paired[-1]}else{$null}
        [pscustomobject]@{id=$task.id;task=$task.taskName;status=$(if($failed.Count){'failed'}elseif($verified){'succeeded'}else{'unverified'});event=$proof}
    })
    $all=$rows.Count -gt 0 -and @($rows|Where-Object{$_.status -ne 'succeeded'}).Count -eq 0
    [pscustomobject]@{Schema='maaend-framework-terminal-v1';AllSucceeded=[bool]$all;PerTask=$rows;MatchedEventCount=$events.Count;Correlation='current-run mapping + window UUID + timestamp interval + paired task start/end'}
}
Export-ModuleMember -Function Get-MaaEndFrameworkTaskEvidence
