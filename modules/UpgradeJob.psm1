# UpgradeJob.psm1 - what the background tasks do: the upgrade job, the check after the next sign-in, and the monitor.
Set-StrictMode -Version 2.0

$script:SetupLog = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Panther\setupact.log'
$script:RollbackLogs = Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Rollback'

function Get-TkStageStart {
    param($State)
    $h = @(@(Get-TkProp $State 'History') | Where-Object { $_ })
    if ($h.Count) { return [datetime]$h[-1].At }
    return [datetime]$State.Updated
}

function Invoke-TkUpgradeJob {
    # Runs as SYSTEM in a scheduled task, so signing out does not stop it.
    param([Parameter(Mandatory = $true)][string]$JobPath)
    $job = Read-TkJson $JobPath
    $cfg = $job.Config
    $paths = Get-TkUpgradePaths
    $iso = $null; $mounted = $false
    try {
        Write-TkUpgradeState 'Preparing' 'Checking this PC before the upgrade.'
        Assert-TkWorkstation -Os (Invoke-TkSys 'GetOs')
        $iso = Get-TkImage -Config $cfg
        if (-not $iso) {
            Write-TkUpgradeState 'Failed' "No verified image arrived within $($cfg.DropFolderWaitHours) hours. Nothing was changed."
            return 'Failed'
        }
        $drive = Invoke-TkSys 'MountIso' @($iso); $mounted = $true
        $setup = "$($drive.TrimEnd('\'))\setup.exe"
        if (-not (Invoke-TkSys 'TestPath' @($setup))) { throw "The image has no setup.exe ($setup)." }
        if ($job.AllowUnsupported) {
            # Microsoft's own documented value for upgrading PCs with an older TPM or processor. The admin chose this.
            [void](Set-TkRegValue -Key 'HKLM\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Value 1 -Kind 'DWord')
        }
        New-Item -ItemType Directory -Path $paths.Logs -Force | Out-Null

        Write-TkUpgradeState 'Scanning' 'Windows Setup is checking this PC (a compatibility scan; nothing changes). This usually takes 5 to 30 minutes.' @{ Progress = $null }
        $scanArgs = Get-TkSetupArguments -Mode Scan -DynamicUpdate ([bool]$cfg.DynamicUpdate) -AllowUnsupported ([bool]$job.AllowUnsupported) -LogDir $paths.Logs
        $scan = Resolve-TkSetupExitCode -Code (Invoke-TkSys 'RunExe' @($setup, $scanArgs, 7200)).ExitCode -Mode Scan
        if ($scan.Result -ne 'Compatible') {
            Write-TkUpgradeState 'Failed' "The compatibility scan stopped the upgrade: $($scan.Meaning) ($($scan.Code)) Nothing was changed." @{ Scan = $scan }
            return 'Failed'
        }

        # Checked at the next sign-in: confirms the upgrade, cleans up, then removes itself.
        Invoke-TkSys 'RegisterTask' @('AfterUpgrade', (Join-Path $job.AppDir 'worker\After-Upgrade.ps1'), "-Job `"$JobPath`"", 'Logon', 4)
        $msg = 'Windows Setup is upgrading this PC. Files, apps and settings are kept.'
        if (-not $job.NoRestart) { $msg += ' The PC restarts on its own when Setup is ready.' }
        Write-TkUpgradeState 'Upgrading' $msg @{ Scan = $scan }
        $upArgs = Get-TkSetupArguments -Mode Upgrade -DynamicUpdate ([bool]$cfg.DynamicUpdate) -AllowUnsupported ([bool]$job.AllowUnsupported) -NoRestart ([bool]$job.NoRestart) -LogDir $paths.Logs
        $res = Resolve-TkSetupExitCode -Code (Invoke-TkSys 'RunExe' @($setup, $upArgs, 14400)).ExitCode -Mode Upgrade
        if ($res.Result -eq 'Success') {
            if ($job.NoRestart) {
                Write-TkUpgradeState 'WaitingForRestart' 'Setup finished its first part. Restart the PC to complete the upgrade.' @{ Setup = $res }
                return 'WaitingForRestart'
            }
            Write-TkUpgradeState 'Restarting' 'Setup finished its first part. The PC restarts to complete the upgrade.' @{ Setup = $res }
            return 'Restarting'
        }
        Invoke-TkSys 'UnregisterTask' @('AfterUpgrade')
        Write-TkUpgradeState 'Failed' "Windows Setup stopped: $($res.Meaning) ($($res.Code)) The PC is still on its old Windows." @{ Setup = $res }
        return 'Failed'
    } catch {
        Write-TkUpgradeState 'Failed' "The upgrade stopped: $($_.Exception.Message)"
        return 'Failed'
    } finally {
        if ($mounted) { try { Invoke-TkSys 'DismountIso' @($iso) } catch { } }
    }
}

function Invoke-TkAfterUpgrade {
    # Runs at sign-in. A sign-in on a newer build is the proof the upgrade worked; only then is the image deleted.
    param([Parameter(Mandatory = $true)][string]$JobPath)
    $job = Read-TkJson $JobPath
    $state = Read-TkUpgradeState
    $os = Invoke-TkSys 'GetOs'
    $paths = Get-TkUpgradePaths
    if ([int]$os.Build -gt [int]$job.StartBuild) {
        Write-TkUpgradeState 'Finishing' "Signed in on Windows build $($os.Build). Finishing up."
        $notes = New-Object System.Collections.ArrayList
        if ($job.CleanAfter) {
            try {
                $cat = Get-TkCatalog -Path (Join-Path $job.AppDir 'catalog\apps.json')
                $org = Get-TkOrganization -Path ([string]$job.Organization) -Catalog $cat
                # The same choices as before the upgrade: the defaults with this job's -Include and -Exclude.
                $plan = New-TkCleanPlan -Inventory (Invoke-TkSys 'GetInventory') -Catalog $cat -Organization $org -Include @(Get-TkProp $job 'Include') -Exclude @(Get-TkProp $job 'Exclude')
                $res = Invoke-TkCleanApps -Plan $plan -Apply
                [void]$notes.Add("Clean apps on Windows 11: $($res.AppsRemoved) removed, $($res.Blocked) blocked.")
            } catch { [void]$notes.Add("Clean apps did not finish: $($_.Exception.Message)") }
        }
        foreach ($dir in @($paths.Download, $paths.Drop)) {
            if (Test-Path -LiteralPath $dir) {
                try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop } catch { [void]$notes.Add("Could not remove $($dir): $($_.Exception.Message)") }
            }
        }
        [void]$notes.Add('The Windows 11 image was removed.')
        if ($job.AllowUnsupported) {
            try { [void](Set-TkRegValue -Key 'HKLM\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Value $null -Kind 'Delete') } catch { }
        }
        Invoke-TkSys 'UnregisterTask' @('AfterUpgrade')
        Invoke-TkSys 'UnregisterTask' @('Upgrade')
        Write-TkUpgradeState 'Done' ("Upgraded from build {0} to build {1}. {2}" -f $job.StartBuild, $os.Build, ($notes -join ' ')) @{ FromBuild = $job.StartBuild; ToBuild = $os.Build }
        return 'Done'
    }
    if (-not $state) { return 'Unknown' }
    if ($state.Stage -eq 'Failed') { Invoke-TkSys 'UnregisterTask' @('AfterUpgrade'); return 'Failed' }
    if (@('Upgrading', 'Restarting', 'WaitingForRestart') -contains $state.Stage) {
        $restarted = ([datetime](Invoke-TkSys 'LastBoot')) -gt (Get-TkStageStart $state)
        if ($restarted -and $null -eq (Invoke-TkSys 'SetupCpu')) {
            Invoke-TkSys 'UnregisterTask' @('AfterUpgrade')
            Write-TkUpgradeState 'RolledBack' "The PC restarted but is still on build $($os.Build): Setup rolled the upgrade back or was interrupted. The image is kept for another try. Setup's logs: $script:RollbackLogs"
            return 'RolledBack'
        }
    }
    return 'InProgress'
}

function Get-TkSetupLogTail {
    try {
        $fs = [System.IO.File]::Open($script:SetupLog, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length; $take = [Math]::Min([int64]4096, $len)
            [void]$fs.Seek(-$take, 'End'); $buf = New-Object byte[] $take; [void]$fs.Read($buf, 0, $take)
            $lines = @([Text.Encoding]::UTF8.GetString($buf) -split "`r?`n" | Where-Object { $_.Trim() })
            if ($lines.Count) { return $lines[-1].Trim() }
        } finally { $fs.Close() }
    } catch { }
    return $null
}

function Show-TkUpgradeMonitor {
    # Shows stages, measured progress and real activity. No invented countdowns.
    param([switch]$Once, [int]$RefreshSeconds = 5)
    $lastCpu = $null
    while ($true) {
        $s = Read-TkUpgradeState
        if (-not $s) { Write-Host '  No upgrade has been started on this PC.'; return }
        if (-not $Once) { Clear-Host }
        $since = Get-TkStageStart $s
        Write-Host ''
        Write-Host ("  {0}  -  {1}" -f $s.Stage, $s.Message)
        Write-Host ("  In this stage for {0} (since {1:HH:mm})" -f (Format-TkDuration ((Get-Date) - $since).TotalSeconds), $since)
        if ($s.Stage -eq 'Upgrading') {
            $p = Invoke-TkSys 'RegGet' @('HKLM\SYSTEM\Setup\MoSetup\Volatile', 'SetupProgress')
            if ($p.Exists) { Write-Host "  Windows Setup reports $($p.Value)%. Setup gives no time estimate, so neither does this monitor." }
            $cpu = Invoke-TkSys 'SetupCpu'
            if ($null -ne $cpu) {
                if ($null -ne $lastCpu -and $cpu -gt $lastCpu) { Write-Host '  Setup is working (using the processor right now).' } else { Write-Host '  Setup is running.' }
                $lastCpu = $cpu
            }
            $tail = Get-TkSetupLogTail
            if ($tail) { if ($tail.Length -gt 160) { $tail = $tail.Substring(0, 160) + '...' }; Write-Host "  Last Setup log line: $tail" }
        }
        Write-Host ''
        if ($Once -or @('Done', 'Failed', 'RolledBack') -contains $s.Stage) { return }
        Start-Sleep -Seconds $RefreshSeconds
    }
}

Export-ModuleMember -Function *
