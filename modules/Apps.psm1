# Apps.psm1 - Clean apps: carries out a plan, writes the undo file and checks the result. Also undoes a run.
Set-StrictMode -Version 2.0

function Invoke-TkCleanApps {
    param([Parameter(Mandatory = $true)]$Plan, [switch]$Apply)
    if (-not $Apply) { throw 'Clean apps changes nothing without -Apply. Run the preview (Report) to see what it would do.' }
    $run = Get-TkRun; if (-not $run) { $run = New-TkRun -Name "clean-apps-$($Plan.Profile)" }
    Save-TkJson $Plan (Join-Path $run.Dir 'plan.json')
    $undoApps = New-Object System.Collections.ArrayList
    $undoBlocks = New-Object System.Collections.ArrayList
    $undoReg = New-Object System.Collections.ArrayList
    $results = New-Object System.Collections.ArrayList

    foreach ($item in @($Plan.Items | Where-Object { $_.Action -eq 'Remove' -or $_.Action -eq 'Block' })) {
        $r = [pscustomobject]@{ Name = $item.Name; Title = $item.Title; Action = $item.Action; Removed = 0; AlreadyGone = $false; Blocked = $false; Refused = $false; Failed = 0; Errors = @() }
        $live = @(); $prov = @()
        if ($item.Action -eq 'Remove') {
            # Look again right before acting: the plan may be old, and the guard has the last word.
            $live = @(Invoke-TkSys 'FindAppx' @($item.Name))
            $prov = @(Invoke-TkSys 'FindProvisioned' @($item.Name))
            try {
                Assert-TkRemovable -Name $item.Name
                foreach ($pkg in $live) {
                    Assert-TkRemovable -Name $pkg.Name -IsFramework ([bool](Get-TkProp $pkg 'IsFramework')) -NonRemovable ([bool](Get-TkProp $pkg 'NonRemovable')) -SignatureKind ([string](Get-TkProp $pkg 'SignatureKind'))
                }
            } catch {
                $r.Refused = $true; $r.Failed++; $r.Errors += $_.Exception.Message; Write-TkLog $_.Exception.Message 'Warn'
                [void]$results.Add($r); continue
            }
            if (-not $live.Count -and -not $prov.Count) { $r.AlreadyGone = $true; Write-TkLog "$($item.Title): already gone" }
            # The new-user copy first. On Windows 10, removing an app for every user while it is still set up for new
            # users fails at Windows' clean-up step ("DeStage", 0x80070002, seen in the lab on 22H2); removing the
            # new-user copy first takes every user's copy with it, cleanly, on Windows 10 and 11.
            foreach ($pv in $prov) {
                try { Invoke-TkSys 'RemoveProvisioned' @($pv.PackageName); $r.Removed++; Write-TkLog "Removed $($pv.PackageName) for new users" 'Ok' }
                catch {
                    $still = @(Invoke-TkSys 'FindProvisioned' @($item.Name) | Where-Object { $_.PackageName -eq $pv.PackageName })
                    if ($still.Count) { $r.Failed++; $r.Errors += "$($pv.PackageName): $($_.Exception.Message)"; Write-TkLog "Could not remove $($pv.PackageName) for new users: $($_.Exception.Message)" 'Warn' }
                    else { Write-TkLog "$($pv.PackageName) was already gone for new users" }
                }
            }
            # Then whatever is still installed for someone: apps never set up for new users, or a Windows whose
            # new-user removal leaves the installed copies. Only packages the guard checked above.
            if ($prov.Count -and $live.Count) {
                $checked = @($live | ForEach-Object { $_.PackageFullName })
                $live = @(Invoke-TkSys 'FindAppx' @($item.Name) | Where-Object { $checked -contains $_.PackageFullName })
                if (-not $live.Count) { Write-TkLog "$($item.Title): removed for every user together with the new-user copy" 'Ok' }
            }
            foreach ($pkg in $live) {
                try { Invoke-TkSys 'RemoveAppx' @($pkg.PackageFullName); $r.Removed++; Write-TkLog "Removed $($pkg.PackageFullName) for every user" 'Ok' }
                catch { $r.Failed++; $r.Errors += "$($pkg.PackageFullName): $($_.Exception.Message)"; Write-TkLog "Could not remove $($pkg.PackageFullName): $($_.Exception.Message)" 'Warn' }
            }
        }
        # Mark the family so new users and feature updates do not bring it back.
        $family = $item.Family
        if (-not $family -and $live.Count) { $family = [string](Get-TkProp $live[0] 'PackageFamilyName') }
        if ($family) {
            try { if (Add-TkDeprovisioned -Family $family) { [void]$undoBlocks.Add($family) }; $r.Blocked = $true }
            catch { $r.Failed++; $r.Errors += "block $($family): $($_.Exception.Message)"; Write-TkLog "Could not block $($family): $($_.Exception.Message)" 'Warn' }
        }
        if ($r.Removed -gt 0) { [void]$undoApps.Add([pscustomobject]@{ Name = $item.Name; Title = $item.Title; Family = $family; Restore = $item.Restore }) }
        [void]$results.Add($r)
    }

    $settings = Invoke-TkApplySettings -Settings @($Plan.Settings) -Undo $undoReg

    $undo = [pscustomobject]@{
        Kind = 'CleanAppsUndo'; Product = (Get-TkProduct).Name; Version = (Get-TkProduct).Version
        Created = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME; Profile = $Plan.Profile
        Apps = @($undoApps); Deprovisioned = @($undoBlocks); Registry = @($undoReg)
    }
    $undoPath = Join-Path $run.Dir 'undo.json'
    Save-TkJson $undo $undoPath
    $undoDir = Join-Path (Get-TkDataRoot) 'undo'
    New-Item -ItemType Directory -Path $undoDir -Force | Out-Null
    Copy-Item -LiteralPath $undoPath -Destination (Join-Path $undoDir ('{0}-{1}.json' -f (Split-Path -Leaf $run.Dir), $Plan.Profile)) -Force

    # Check the result: anything planned for removal that is still here?
    $left = @($results | Where-Object { $_.Action -eq 'Remove' -and -not $_.Refused } | Where-Object {
        @(Invoke-TkSys 'FindAppx' @($_.Name)).Count -or @(Invoke-TkSys 'FindProvisioned' @($_.Name)).Count
    } | ForEach-Object { $_.Name })
    $summary = [pscustomobject]@{
        Kind = 'CleanAppsResult'; Profile = $Plan.Profile; Finished = (Get-Date).ToString('s')
        AppsRemoved = @($results | Where-Object { $_.Removed -gt 0 }).Count
        AlreadyGone = @($results | Where-Object { $_.AlreadyGone }).Count
        Blocked = @($results | Where-Object { $_.Blocked }).Count
        Failed = @($results | Where-Object { $_.Failed -gt 0 }).Count
        StillPresent = $left
        SettingsChanged = $settings.Changed; SettingsFailed = $settings.Failed
        UndoFile = $undoPath; Items = @($results)
    }
    Save-TkJson $summary (Join-Path $run.Dir 'result.json')
    $lvl = 'Ok'; if ($summary.Failed -or $left.Count -or $settings.Failed) { $lvl = 'Warn' }
    Write-TkLog ('Clean apps finished: {0} removed, {1} already gone, {2} blocked, {3} with errors, {4} settings changed.' -f $summary.AppsRemoved, $summary.AlreadyGone, $summary.Blocked, $summary.Failed, $summary.SettingsChanged) $lvl
    return $summary
}

function Invoke-TkUndo {
    # Without -Apply: shows what the undo would do. With -Reinstall: also reinstalls the removed apps (run as the signed-in user).
    param([Parameter(Mandatory = $true)][string]$UndoFile, [switch]$Apply, [switch]$Reinstall)
    $u = Read-TkJson $UndoFile
    if ((Get-TkProp $u 'Kind') -ne 'CleanAppsUndo') { throw "$UndoFile is not a clean-apps undo file." }
    $apps = @(@($u.Apps) | Where-Object { $_ })
    if (-not $Apply) {
        return [pscustomobject]@{ Kind = 'UndoPreview'; Settings = @(@($u.Registry) | Where-Object { $_ }).Count; Unblock = @(@($u.Deprovisioned) | Where-Object { $_ }).Count; Apps = $apps }
    }
    $reg = Undo-TkRegistry -Records @($u.Registry)
    $unblocked = 0; $failed = 0
    foreach ($f in @(@($u.Deprovisioned) | Where-Object { $_ })) {
        try { Remove-TkDeprovisioned -Family $f; $unblocked++ } catch { $failed++; Write-TkLog "Could not unblock $($f): $($_.Exception.Message)" 'Warn' }
    }
    $reinstalled = 0; $manual = New-Object System.Collections.ArrayList
    foreach ($a in $apps) {
        $cmd = [string]$a.Restore
        if ($Reinstall -and ((Test-TkLike $cmd @('winget *')) -or $cmd -eq 'wsreset -i')) {
            $parts = @($cmd -split ' ' | Where-Object { $_ })
            $exe = "$($parts[0]).exe"
            $exeArgs = @(); if ($parts.Count -gt 1) { $exeArgs = @($parts[1..($parts.Count - 1)]) }
            try {
                $res = Invoke-TkSys 'RunExe' @($exe, $exeArgs, 1800)
                if ($res.ExitCode -eq 0) { $reinstalled++; Write-TkLog "Reinstalled $($a.Title)" 'Ok'; continue }
                Write-TkLog "Could not reinstall $($a.Title) (exit $($res.ExitCode))" 'Warn'
            } catch { Write-TkLog "Could not reinstall $($a.Title): $($_.Exception.Message)" 'Warn' }
        }
        [void]$manual.Add($a)
    }
    return [pscustomobject]@{
        Kind = 'UndoResult'; SettingsRestored = $reg.Restored; Unblocked = $unblocked; Reinstalled = $reinstalled
        ToReinstall = @($manual); Failed = ($failed + $reg.Failed)
    }
}

Export-ModuleMember -Function *
