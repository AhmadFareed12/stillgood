# Settings.psm1 - user profiles, registry changes and the "stay clean" markers.
# Every change records the old value first, so each one can be undone.
Set-StrictMode -Version 2.0

$script:DeprovRoot = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'

function Get-TkUserHives {
    # Every real user profile, plus the default profile that new users are copied from.
    # Loaded = the user is signed in, so the hive is already open under HKU.
    $loaded = @(Invoke-TkSys 'GetLoadedHives')
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @(Invoke-TkSys 'GetProfiles')) {
        $file = Join-Path $p.Path 'NTUSER.DAT'
        if ($loaded -contains $p.Sid) {
            [void]$list.Add([pscustomobject]@{ Kind = 'User'; Sid = $p.Sid; Path = $p.Path; File = $file; Root = "HKU\$($p.Sid)"; Loaded = $true })
        } elseif (Invoke-TkSys 'TestPath' @($file)) {
            [void]$list.Add([pscustomobject]@{ Kind = 'User'; Sid = $p.Sid; Path = $p.Path; File = $file; Root = "HKU\TK_$($p.Sid)"; Loaded = $false })
        }
    }
    $defPath = Join-Path $env:SystemDrive 'Users\Default'
    $defFile = Join-Path $defPath 'NTUSER.DAT'
    if (Invoke-TkSys 'TestPath' @($defFile)) {
        [void]$list.Add([pscustomobject]@{ Kind = 'Default'; Sid = 'Default'; Path = $defPath; File = $defFile; Root = 'HKU\TK_Default'; Loaded = $false })
    }
    return @($list)
}

function Enter-TkHive {
    param($Hive)
    if ($Hive.Loaded) { return }
    $mount = $Hive.Root.Substring(4)
    if (@(Invoke-TkSys 'GetLoadedHives') -contains $mount) { return }   # left over from an interrupted run: reuse it
    Invoke-TkSys 'HiveLoad' @($Hive.Root, $Hive.File)
}

function Exit-TkHive {
    param($Hive)
    if (-not $Hive.Loaded) { Invoke-TkSys 'HiveUnload' @($Hive.Root) }
}

function Set-TkRegValue {
    # Changes one value. Returns what is needed to undo it, or $null when it was already right.
    param([string]$Key, [string]$Name, $Value, [string]$Kind)
    Assert-TkRegistryWrite -Path $Key -Name $Name
    $old = Invoke-TkSys 'RegGet' @($Key, $Name)
    if ($Kind -eq 'Delete') {
        if (-not $old.Exists) { return $null }
        Invoke-TkSys 'RegDeleteValue' @($Key, $Name)
    } else {
        if ($old.Exists -and ([string]$old.Value -eq [string]$Value) -and ($old.Kind -eq $Kind)) { return $null }
        Invoke-TkSys 'RegSet' @($Key, $Name, $Value, $Kind)
    }
    return [pscustomobject]@{ Existed = [bool]$old.Exists; OldValue = $old.Value; OldKind = $old.Kind }
}

function Invoke-TkApplySettings {
    # Applies the clean-apps settings to this PC, every user profile and the default profile. Adds undo records to $Undo.
    param([object[]]$Settings, [System.Collections.ArrayList]$Undo)
    $changed = 0; $failed = 0
    foreach ($s in @($Settings | Where-Object { $_.Scope -eq 'Machine' })) {
        try {
            $r = Set-TkRegValue -Key $s.Key -Name $s.Name -Value $s.Value -Kind $s.Kind
            if ($r) { [void]$Undo.Add([pscustomobject]@{ Owner = 'Machine'; SubKey = $s.Key; Name = $s.Name; Existed = $r.Existed; OldValue = $r.OldValue; OldKind = $r.OldKind }); $changed++ }
        } catch { $failed++; Write-TkLog "Could not set $($s.Key)\$($s.Name): $($_.Exception.Message)" 'Warn' }
    }
    $forUsers = @($Settings | Where-Object { $_.Scope -eq 'Users' })
    $forNew = @($Settings | Where-Object { $_.Scope -eq 'NewUsers' })
    foreach ($h in @(Get-TkUserHives)) {
        $apply = @($forUsers); if ($h.Kind -eq 'Default') { $apply += $forNew }
        if (-not $apply.Count) { continue }
        try { Enter-TkHive $h } catch { $failed += $apply.Count; Write-TkLog "Skipped profile $($h.Path): $($_.Exception.Message)" 'Warn'; continue }
        $here = 0
        try {
            foreach ($s in $apply) {
                try {
                    $r = Set-TkRegValue -Key "$($h.Root)\$($s.Key)" -Name $s.Name -Value $s.Value -Kind $s.Kind
                    if ($r) { [void]$Undo.Add([pscustomobject]@{ Owner = $h.Sid; SubKey = $s.Key; Name = $s.Name; Existed = $r.Existed; OldValue = $r.OldValue; OldKind = $r.OldKind }); $changed++; $here++ }
                } catch { $failed++; Write-TkLog "Could not set $($s.Name) for $($h.Path): $($_.Exception.Message)" 'Warn' }
            }
            Write-TkLog "Settings for $($h.Path) [$($h.Root)]: $here changed"
        } finally {
            try { Exit-TkHive $h } catch { Write-TkLog "Could not close the profile $($h.Path): $($_.Exception.Message)" 'Warn' }
        }
    }
    return [pscustomobject]@{ Changed = $changed; Failed = $failed }
}

function Undo-TkRegistry {
    # Puts every recorded value back the way it was (or removes it, if it did not exist before).
    param([object[]]$Records)
    $hives = @{}; foreach ($h in @(Get-TkUserHives)) { $hives[$h.Sid] = $h }
    $restored = 0; $failed = 0
    foreach ($g in @(@($Records) | Where-Object { $_ } | Group-Object Owner)) {
        $h = $null
        if ($g.Name -ne 'Machine') {
            if (-not $hives.ContainsKey($g.Name)) { $failed += $g.Count; Write-TkLog "Profile $($g.Name) no longer exists; its settings were skipped." 'Warn'; continue }
            $h = $hives[$g.Name]
            try { Enter-TkHive $h } catch { $failed += $g.Count; Write-TkLog "Could not open profile $($h.Path): $($_.Exception.Message)" 'Warn'; continue }
        }
        try {
            foreach ($r in $g.Group) {
                $key = $r.SubKey; if ($h) { $key = "$($h.Root)\$($r.SubKey)" }
                try {
                    Assert-TkRegistryWrite -Path $key -Name $r.Name
                    if ($r.Existed) { Invoke-TkSys 'RegSet' @($key, $r.Name, $r.OldValue, $r.OldKind) }
                    else { Invoke-TkSys 'RegDeleteValue' @($key, $r.Name) }
                    $restored++
                } catch { $failed++; Write-TkLog "Could not restore $key\$($r.Name): $($_.Exception.Message)" 'Warn' }
            }
        } finally {
            if ($h) { try { Exit-TkHive $h } catch { Write-TkLog "Could not close the profile $($h.Path)." 'Warn' } }
        }
    }
    return [pscustomobject]@{ Restored = $restored; Failed = $failed }
}

function Add-TkDeprovisioned {
    # Marks an app family so Windows does not install it again for new users or during feature updates.
    # Returns $true when this run created the marker (so undo removes only what this run added).
    param([Parameter(Mandatory = $true)][string]$Family)
    $key = "$script:DeprovRoot\$Family"
    Assert-TkRegistryWrite -Path $key
    if (Invoke-TkSys 'RegKeyExists' @($key)) { return $false }
    Invoke-TkSys 'RegCreateKey' @($key)
    return $true
}

function Remove-TkDeprovisioned {
    param([Parameter(Mandatory = $true)][string]$Family)
    $key = "$script:DeprovRoot\$Family"
    Assert-TkRegistryWrite -Path $key
    Invoke-TkSys 'RegDeleteKey' @($key)
}

function Get-TkOneDriveUsers {
    # Read-only: who keeps files in OneDrive on this PC. Nothing here changes OneDrive for anyone.
    foreach ($p in @(Invoke-TkSys 'GetProfiles')) {
        $state = 'NotUsed'; $folders = @()
        try {
            $folders = @(Get-ChildItem -LiteralPath $p.Path -Directory -Filter 'OneDrive*' -ErrorAction Stop | ForEach-Object { $_.Name })
            if ($folders.Count) { $state = 'Uses' }
        } catch { $state = 'Unknown' }
        [pscustomobject]@{ Sid = $p.Sid; Profile = (Split-Path -Leaf $p.Path); State = $state; Folders = $folders }
    }
}

Export-ModuleMember -Function *
