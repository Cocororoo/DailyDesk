function Get-GenshinDisplayPreference {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RegistrySubKey)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey, $false)
    if (!$key) { throw 'Game display preference key is missing.' }
    try {
        $patterns = [ordered]@{
            Width = '^Screenmanager Resolution Width_h\d+$'
            Height = '^Screenmanager Resolution Height_h\d+$'
            Fullscreen = '^Screenmanager Is Fullscreen mode_h\d+$'
        }
        $result = [ordered]@{}
        foreach ($field in $patterns.Keys) {
            $names = @($key.GetValueNames() | Where-Object { $_ -match $patterns[$field] })
            if ($names.Count -ne 1) { throw ('Expected one game display key for ' + $field) }
            $name = $names[0]
            if ($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { throw ('Unexpected registry type: ' + $name) }
            $result[$field] = [pscustomobject]@{ Name = $name; Value = [int]$key.GetValue($name); Kind = 'DWord' }
        }
        [pscustomobject]$result
    } finally { $key.Dispose() }
}

function Set-GenshinDisplayPreference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$RegistrySubKey,
        [Parameter(Mandatory=$true)][ValidateRange(640,7680)][int]$Width,
        [Parameter(Mandatory=$true)][ValidateRange(480,4320)][int]$Height,
        [ValidateSet(0,1)][int]$Fullscreen = 1
    )
    $before = Get-GenshinDisplayPreference -RegistrySubKey $RegistrySubKey
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey, $true)
    if (!$key) { throw 'Cannot write game display preferences.' }
    $target = [ordered]@{ Width=$Width; Height=$Height; Fullscreen=$Fullscreen }
    try {
        foreach ($field in $target.Keys) { $key.SetValue($before.$field.Name, $target[$field], [Microsoft.Win32.RegistryValueKind]::DWord) }
        $key.Flush()
        foreach ($field in $target.Keys) {
            if ([int]$key.GetValue($before.$field.Name) -ne $target[$field]) { throw ('Display preference verification failed: ' + $field) }
        }
    } catch {
        foreach ($field in $target.Keys) { $key.SetValue($before.$field.Name, $before.$field.Value, [Microsoft.Win32.RegistryValueKind]::DWord) }
        $key.Flush()
        throw
    } finally { $key.Dispose() }
    Get-GenshinDisplayPreference -RegistrySubKey $RegistrySubKey
}

Export-ModuleMember -Function Get-GenshinDisplayPreference,Set-GenshinDisplayPreference
