<#
.SYNOPSIS
    Windows 11 for the PCs you already have: report, clean apps and upgrade - on one PC or a whole fleet, without losing a file.

.DESCRIPTION
    Every mode starts with a preview. Nothing changes until you confirm, or until a script passes -Apply -Yes.
    Exit codes: 0 done, 1 failed, 2 refused (a blocker or a safety rule), 3 not confirmed, 10 preview only.

.EXAMPLE
    .\StillGood.ps1                                              # the menu
.EXAMPLE
    .\StillGood.ps1 -Mode Report                                 # read-only report, no admin rights needed
.EXAMPLE
    .\StillGood.ps1 -Mode CleanApps -Apply -Yes                  # the defaults, from an RMM tool or a script
.EXAMPLE
    .\StillGood.ps1 -Mode CleanApps -Include everyday,communication -Exclude Microsoft.WindowsCalculator -Apply -Yes
    # a till: also the everyday tools, mail and chat, but keep Calculator. Groups: ai, communication, consumer,
    # everyday, gaming, newusers, promoted, retired, store, tools; or 'all'. Apps: their package names (see the report).
.EXAMPLE
    .\StillGood.ps1 -Mode Upgrade -Config .\config\upgrade.json -Apply -Yes -AllowUnsupportedHardware
.EXAMPLE
    .\StillGood.ps1 -Mode Monitor
.EXAMPLE
    .\StillGood.ps1 -Mode Undo -Apply -Reinstall                 # undo the latest clean-apps run
#>
[CmdletBinding()]
param(
    [ValidateSet('Window', 'Menu', 'Report', 'CleanApps', 'Upgrade', 'UpgradeAndClean', 'Monitor', 'Undo')][string]$Mode = 'Menu',
    [string[]]$Include = @(),
    [string[]]$Exclude = @(),
    [switch]$Apply,
    [switch]$Yes,
    [switch]$AllowUnsupportedHardware,
    [switch]$NoRestart,
    [string]$Config,
    [string]$Organization,
    [string]$UndoFile,
    [switch]$Reinstall
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'modules\_load.ps1')

function Test-TkInteractive { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }

function Confirm-Tk {
    param([string]$Question)
    if ($Yes) { return $true }
    if (-not (Test-TkInteractive)) { Write-Host '  Nobody is at the keyboard: add -Yes to confirm.' -ForegroundColor Yellow; return $false }
    return ((Read-Host "  $Question Type YES to continue") -ceq 'YES')
}

function Get-TkOrgPath {
    if ($Organization) { return $Organization }
    $p = Join-Path $PSScriptRoot 'catalog\organization.json'
    if (Test-Path -LiteralPath $p) { return $p }
    return ''
}

function Test-TkPreviewOnly { return (-not $Apply -and $Mode -ne 'Menu') }

function Invoke-TkReportMode {
    param([string]$RunName = 'report')
    $run = New-TkRun -Name $RunName
    $inv = Get-TkInventory
    $ready = Get-TkWin11Readiness
    $cat = Get-TkCatalog
    $org = Get-TkOrganization -Path (Get-TkOrgPath) -Catalog $cat
    $plan = New-TkCleanPlan -Inventory $inv -Catalog $cat -Organization $org -Include $Include -Exclude $Exclude
    $speed = Get-TkSpeedReport -Inventory $inv -CleanCount $plan.Counts.Remove
    $rep = New-TkReport -Inventory $inv -Readiness $ready -Plan $plan -OneDrive @(Get-TkOneDriveUsers) -Speed $speed
    $paths = Save-TkReport -Report $rep -Dir $run.Dir
    Write-TkReportSummary -Report $rep -Paths $paths
    return @{ Run = $run; Readiness = $ready; Plan = $plan; Paths = $paths }
}

function Invoke-TkCleanMode {
    Assert-TkWorkstation
    if (-not (Test-TkElevated)) { Write-Host '  Clean apps needs administrator rights: it changes apps for every user.' -ForegroundColor Yellow; return 2 }
    $r = Invoke-TkReportMode -RunName 'clean-apps'
    $c = $r.Plan.Counts
    Write-Host ("  Clean apps ({0}) will remove {1} apps for every user and for new users, block {2} before they arrive, and set {3} settings. Every change is recorded for undo." -f (Get-TkSelectionText $r.Plan), $c.Remove, $c.Block, @($r.Plan.Settings).Count)
    if (Test-TkPreviewOnly) { Write-Host '  Preview only. Add -Apply to make these changes.'; return 10 }
    if (-not (Confirm-Tk 'Make these changes now?')) { Write-Host '  Nothing was changed.'; return 3 }
    $res = Invoke-TkCleanApps -Plan $r.Plan -Apply
    Write-Host ("  Done: {0} removed, {1} already gone, {2} blocked, {3} with errors, {4} settings changed." -f $res.AppsRemoved, $res.AlreadyGone, $res.Blocked, $res.Failed, $res.SettingsChanged) -ForegroundColor Green
    if (@($res.StillPresent).Count) { Write-Host "  Still present: $(@($res.StillPresent) -join ', ')" -ForegroundColor Yellow }
    Write-Host "  Undo file: $($res.UndoFile)"
    if ($res.Failed -or @($res.StillPresent).Count) { return 1 }
    return 0
}

function Invoke-TkUpgradeMode {
    param([bool]$CleanToo)
    Assert-TkWorkstation
    if (-not (Test-TkElevated)) { Write-Host '  The upgrade needs administrator rights.' -ForegroundColor Yellow; return 2 }
    $cfgPath = $Config; if (-not $cfgPath) { $cfgPath = Join-Path $PSScriptRoot 'config\upgrade.json' }
    if (-not (Test-Path -LiteralPath $cfgPath)) { Write-Host "  No upgrade settings at $cfgPath. Copy config\upgrade.example.json to config\upgrade.json and fill it in." -ForegroundColor Yellow; return 2 }
    $all = Get-TkUpgradeConfig -Path $cfgPath
    try { $cfg = Resolve-TkUpgradeImage -Config $all -Culture (Get-TkOsLanguage) }
    catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; return 2 }
    if ($cfg.AnyLanguage) { Write-Host "  The settings don't say which language the image is in. It must be $($cfg.LanguageName) ($($cfg.Culture)), this PC's Windows language, or Setup's scan refuses it (nothing changes)." -ForegroundColor Yellow }
    $r = Invoke-TkReportMode -RunName 'upgrade'
    $rd = $r.Readiness
    if ($rd.Verdict -eq 'NotUpgradeable') { Write-Host '  This PC cannot run Windows 11:' -ForegroundColor Red; @($rd.Blockers) | ForEach-Object { Write-Host "    - $_" }; return 2 }
    if ($rd.Verdict -eq 'FixFirst') { Write-Host '  Fix these first:' -ForegroundColor Yellow; @($rd.Fixable) | ForEach-Object { Write-Host "    - $_" }; return 2 }
    if ($rd.Verdict -eq 'UnsupportedButUpgradeable') {
        Write-Host '  This PC doesn''t pass Microsoft''s hardware check:' -ForegroundColor Yellow
        @($rd.Bypassable) | ForEach-Object { Write-Host "    - $_" }
        Write-Host '  Microsoft does not support Windows 11 on this hardware and does not guarantee updates for it.' -ForegroundColor Yellow
        if (-not $AllowUnsupportedHardware) { Write-Host '  To upgrade anyway, run again with -AllowUnsupportedHardware. The decision is yours.'; return 2 }
    }
    Write-Host '  The upgrade will:'
    Write-Host "    1. Get the $($cfg.LanguageName) image from $($cfg.Source) and check it against the pinned SHA-256."
    Write-Host '       Time left is shown only for this step and the check, where it can be measured.'
    Write-Host '    2. Run Windows Setup''s compatibility scan. If it finds a blocker, it stops and nothing changes.'
    Write-Host '    3. Upgrade silently in the background, keeping files, apps and settings. Signing out does not stop it.'
    if ($NoRestart) { Write-Host '    4. Wait for you to restart the PC.' } else { Write-Host '    4. Restart the PC when Setup is ready.' }
    $last = '    5. At the first sign-in on the new Windows, delete the image'
    if ($CleanToo) { $last += ' and run Clean apps again for the apps Windows 11 brings' }
    Write-Host "$last."
    Write-Host '  Running Setup accepts the Microsoft Software License Terms for Windows 11 on this PC.'
    if (Test-TkPreviewOnly) { Write-Host '  Preview only. Add -Apply to start.'; return 10 }
    if (-not (Confirm-Tk 'Start the upgrade?')) { Write-Host '  Nothing was changed.'; return 3 }
    if ($CleanToo) {
        $res = Invoke-TkCleanApps -Plan $r.Plan -Apply
        Write-Host ("  Clean apps: {0} removed, {1} blocked, {2} with errors." -f $res.AppsRemoved, $res.Blocked, $res.Failed)
    }
    $null = Start-TkUpgrade -Config $cfg -AllowUnsupported ([bool]$AllowUnsupportedHardware) -NoRestart ([bool]$NoRestart) -CleanAfter $CleanToo -Include @($r.Plan.Include) -Exclude @($r.Plan.Exclude) -OrganizationPath (Get-TkOrgPath)
    Write-Host '  The upgrade is running in the background. Watch it with: .\StillGood.ps1 -Mode Monitor' -ForegroundColor Green
    return 0
}

function Invoke-TkUndoMode {
    $file = $UndoFile
    if (-not $file) {
        $latest = @(Get-ChildItem -LiteralPath (Join-Path (Get-TkDataRoot) 'undo') -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if (-not $latest.Count) { Write-Host '  No clean-apps run to undo on this PC.'; return 2 }
        $file = $latest[0].FullName
    }
    $pv = Invoke-TkUndo -UndoFile $file
    Write-Host ("  Undo ({0}) restores {1} settings, unblocks {2} apps, and puts back {3} apps." -f (Split-Path -Leaf $file), $pv.Settings, $pv.Unblock, @($pv.Apps).Count)
    if (-not $Reinstall) { Write-Host '  Apps are put back from the Microsoft Store: add -Reinstall (as the signed-in user), or use the commands listed after the undo.' }
    if (Test-TkPreviewOnly) { Write-Host '  Preview only. Add -Apply to undo.'; return 10 }
    if (-not (Confirm-Tk 'Undo now?')) { Write-Host '  Nothing was changed.'; return 3 }
    $null = New-TkRun -Name 'undo'
    $res = Invoke-TkUndo -UndoFile $file -Apply -Reinstall:$Reinstall
    Write-Host ("  Done: {0} settings restored, {1} apps unblocked, {2} reinstalled." -f $res.SettingsRestored, $res.Unblocked, $res.Reinstalled) -ForegroundColor Green
    foreach ($a in @($res.ToReinstall)) { Write-Host "    $($a.Title): $($a.Restore)" }
    if ($res.Failed) { return 1 }
    return 0
}

function Show-TkMenu {
    $p = Get-TkProduct
    while ($true) {
        Write-Host ''
        Write-Host "  $($p.Name) $($p.Version) - Windows 11 for the PCs you already have" -ForegroundColor Cyan
        Write-Host '  Clean apps uses the defaults here. To choose app by app, open the window (StillGood.cmd).'
        Write-Host '  1  Report only (changes nothing)'
        Write-Host '  2  Clean apps'
        Write-Host '  3  Upgrade to Windows 11'
        Write-Host '  4  Upgrade + clean apps'
        Write-Host '  5  Watch an upgrade in progress'
        Write-Host '  6  Undo a clean-apps run'
        Write-Host '  Q  Quit'
        $choice = ([string](Read-Host '  Choose')).Trim().ToUpperInvariant()
        try {
            switch ($choice) {
                '1' { $r = Invoke-TkReportMode; if ((Read-Host '  Open the report? (Y/N)') -match '^[Yy]') { Start-Process $r.Paths.Html } }
                '2' { $null = Invoke-TkCleanMode }
                '3' { $null = Invoke-TkUpgradeMode -CleanToo $false }
                '4' { $null = Invoke-TkUpgradeMode -CleanToo $true }
                '5' { Show-TkUpgradeMonitor }
                '6' { $null = Invoke-TkUndoMode }
                'Q' { return }
                default { Write-Host '  Choose 1-6 or Q.' }
            }
        } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red }
    }
}

try {
    switch ($Mode) {
        'Window' {
            # The window (what StillGood.cmd opens). It asks Windows for administrator rights first.
            if (-not (Test-TkElevated)) {
                $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $argLine = "-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -Mode Window"
                try { Start-Process -FilePath $ps -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden | Out-Null }
                catch {
                    Add-Type -AssemblyName System.Windows.Forms
                    [void][System.Windows.Forms.MessageBox]::Show('StillGood needs administrator rights to check and clean apps for every user. Open it again and choose Yes when Windows asks.', 'StillGood', 'OK', 'Information')
                }
                exit 0
            }
            Import-Module (Join-Path $PSScriptRoot 'modules\GuiCore.psm1') -Force -DisableNameChecking -Global
            Import-Module (Join-Path $PSScriptRoot 'modules\Gui.psm1') -Force -DisableNameChecking -Global
            Show-TkWindow -Root $PSScriptRoot -OrgPath (Get-TkOrgPath)
            exit 0
        }
        'Menu' {
            if (-not (Test-TkInteractive)) { Write-Host '  No keyboard here: choose a -Mode (see Get-Help .\StillGood.ps1).'; exit 2 }
            Show-TkMenu; exit 0
        }
        'Report' { $null = Invoke-TkReportMode; exit 0 }
        'CleanApps' { exit (Invoke-TkCleanMode) }
        'Upgrade' { exit (Invoke-TkUpgradeMode -CleanToo $false) }
        'UpgradeAndClean' { exit (Invoke-TkUpgradeMode -CleanToo $true) }
        'Monitor' { Show-TkUpgradeMonitor -Once:(-not (Test-TkInteractive)); exit 0 }
        'Undo' { exit (Invoke-TkUndoMode) }
    }
} catch {
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
