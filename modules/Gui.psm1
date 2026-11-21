# Gui.psm1 - the StillGood window (WinForms). Open it with StillGood.cmd (double-click) or StillGood.ps1 -Mode Window.
# Actions on the left, what the PC looks like and what will change in the middle, a live log at the bottom.
# The work runs in a background runspace (GuiCore.psm1), so the window stays responsive.
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:Ui = @{}
$script:Mon = @{}
$script:Teal = [System.Drawing.Color]::FromArgb(15, 76, 92)

function New-TkCtl {
    param([string]$Type, [string]$Text = '', [int]$X = 0, [int]$Y = 0, [int]$W = 100, [int]$H = 24)
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    return $c
}

function Show-TkUiInfo { param([string]$Text) [void][System.Windows.Forms.MessageBox]::Show($script:Ui.Form, $Text, 'StillGood', 'OK', 'Information') }
function Show-TkUiError { param([string]$Text) [void][System.Windows.Forms.MessageBox]::Show($script:Ui.Form, $Text, 'StillGood', 'OK', 'Warning') }
function Confirm-TkUi {
    param([string]$Text, [string]$Icon = 'Question')
    return ([System.Windows.Forms.MessageBox]::Show($script:Ui.Form, $Text, 'StillGood', 'YesNo', $Icon) -eq 'Yes')
}

function Set-TkUiBusy {
    param([bool]$Busy)
    $ui = $script:Ui
    foreach ($b in $ui.Buttons) { $b.Enabled = -not $Busy }
    $ui.Office.Enabled = -not $Busy; $ui.Kiosk.Enabled = -not $Busy
    foreach ($cb in @($ui.Groups.Controls)) { $cb.Enabled = -not $Busy }
    $ui.Bar.Visible = $Busy
    if (-not $Busy) { $ui.Status.Text = 'Ready. Choose an action on the left.' }
}

function Start-TkUiJob {
    param([string]$Status, [string]$Job, $Arguments, [scriptblock]$OnDone)
    $ui = $script:Ui
    $ui.Status.Text = $Status
    $ui.OnDone = $OnDone
    Set-TkUiBusy $true
    $ui.Status.Text = $Status
    $ui.Job = Start-TkBackground -Root $ui.Root -Body (Get-TkJobBody $Job) -Arguments $Arguments -Sync $ui.Sync
}

function Update-TkUiTick {
    # Every 250 ms: move new log lines into the log box, and finish a job that is done.
    $ui = $script:Ui
    $line = $null
    while ($ui.Sync.Log.TryDequeue([ref]$line)) { $ui.Log.AppendText(($line -replace '^\S+ ', '') + "`r`n") }
    if ($ui.Job -and $ui.Job.Handle.IsCompleted) {
        Complete-TkBackground $ui.Job
        $ui.Job = $null
        Set-TkUiBusy $false
        $cb = $ui.OnDone; $ui.OnDone = $null
        if ($cb) { & $cb $ui.Sync.Result $ui.Sync.Error }
    }
}

function Get-TkUiTrimmedPlan {
    $ui = $script:Ui
    $off = @($ui.Groups.Controls | Where-Object { $_ -is [System.Windows.Forms.CheckBox] -and -not $_.Checked } | ForEach-Object { [string]$_.Tag })
    return (Select-TkPlanGroups -Plan $ui.Scan.Plan -Unticked $off)
}

function Update-TkUiList {
    $ui = $script:Ui
    if (-not $ui.Scan) { return }
    $plan = Get-TkUiTrimmedPlan
    $ui.List.BeginUpdate(); $ui.List.Items.Clear()
    foreach ($i in @($plan.Items | Where-Object { $_.Action -eq 'Remove' })) { [void]$ui.List.Items.Add($i.Title) }
    foreach ($i in @($plan.Items | Where-Object { $_.Action -eq 'Block' })) { [void]$ui.List.Items.Add("$($i.Title) (blocked before it arrives)") }
    $ui.List.EndUpdate()
    $ui.ListTitle.Text = "Will be removed: $($plan.Counts.Remove) apps, $($plan.Counts.Block) blocked"
}

function Update-TkUiScan {
    # Fill the window from a finished check.
    $ui = $script:Ui; $s = $ui.Scan
    $os = $s.Os
    $adm = 'yes'; if (-not $s.Elevated) { $adm = 'no (some checks could not be read)' }
    $ui.Info.Text = "$env:COMPUTERNAME  -  $($os.Caption) $($os.DisplayVersion) (build $($os.Build).$($os.Ubr))  -  administrator: $adm"
    $v = $s.Readiness.Verdict
    $colors = @{ Supported = @(227, 244, 230, 20, 92, 38); ProbablySupported = @(227, 244, 230, 20, 92, 38); UnsupportedButUpgradeable = @(255, 243, 214, 122, 75, 0); FixFirst = @(255, 243, 214, 122, 75, 0); NotUpgradeable = @(253, 227, 225, 138, 28, 18) }
    $c = $colors[$v]
    $ui.Verdict.BackColor = [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2]); $ui.Verdict.ForeColor = [System.Drawing.Color]::FromArgb($c[3], $c[4], $c[5])
    $ui.Verdict.Text = "  Windows 11: $($s.Readiness.Summary)"
    $ui.Groups.SuspendLayout(); $ui.Groups.Controls.Clear()
    foreach ($g in @(Get-TkPlanGroups -Plan $s.Plan)) {
        $t = "$($g.Title)  -  $($g.Remove) app$(if ($g.Remove -ne 1) { 's' })"
        if ($g.Block) { $t += ", $($g.Block) blocked ahead" }
        $cb = New-TkCtl CheckBox $t 0 0 380 26
        $cb.Checked = $true; $cb.Tag = $g.Key
        $ui.Tips.SetToolTip($cb, (($g.Items | ForEach-Object { $_.Title }) -join ', '))
        $cb.Add_CheckedChanged({ Update-TkUiList })
        $ui.Groups.Controls.Add($cb)
    }
    if (-not $ui.Groups.Controls.Count) { $ui.Groups.Controls.Add((New-TkCtl Label 'Nothing to remove for this profile: these apps are already gone.' 0 0 380 40)) }
    $ui.Groups.ResumeLayout()
    $ui.GroupsTitle.Text = 'What Clean apps removes (untick a group to keep it)'
    $ui.ReportLink.Enabled = $true
    Update-TkUiList
}

function Start-TkUiScan {
    $ui = $script:Ui
    Start-TkUiJob -Status 'Checking this PC. Nothing is changed.' -Job Scan -Arguments @{ Profile = $ui.Profile; Org = $ui.Org } -OnDone {
        param($res, $err)
        if ($err) { Show-TkUiError "The check stopped: $err"; return }
        $script:Ui.Scan = $res
        Update-TkUiScan
        $next = $script:Ui.Then; $script:Ui.Then = $null
        if ($next) { & $next }
    }
}

function Start-TkUiClean {
    $ui = $script:Ui
    if (-not $ui.Scan) { $ui.Then = { Start-TkUiClean }; Start-TkUiScan; return }
    $plan = Get-TkUiTrimmedPlan
    if (-not ($plan.Counts.Remove + $plan.Counts.Block)) { Show-TkUiInfo 'Nothing to remove: every group is unticked, or these apps are already gone.'; return }
    $msg = "Clean apps will remove $($plan.Counts.Remove) apps for every user and for new users, block $($plan.Counts.Block) from coming back, and change $(@($plan.Settings).Count) settings so they stay away.`r`n`r`nEvery change is written to an undo file.`r`n`r`nClean apps now?"
    if (-not (Confirm-TkUi $msg)) { return }
    Start-TkUiJob -Status 'Cleaning apps. This takes a minute or two.' -Job Clean -Arguments @{ Plan = $plan } -OnDone {
        param($res, $err)
        if ($err) { Show-TkUiError "Clean apps stopped: $err"; return }
        $t = 'Done: {0} removed, {1} already gone, {2} blocked, {3} with errors, {4} settings changed.' -f $res.AppsRemoved, $res.AlreadyGone, $res.Blocked, $res.Failed, $res.SettingsChanged
        if (@($res.StillPresent).Count) { $t += "`r`n`r`nStill there: " + (@($res.StillPresent) -join ', ') }
        $t += "`r`n`r`nTo undo it later: Undo a clean-up."
        Show-TkUiInfo $t
        Start-TkUiScan
    }
}

function Show-TkUpgradeSettings {
    # Asks once where the Windows 11 image is and its SHA-256, then saves config\upgrade.json.
    param($Current)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'StillGood - the Windows 11 image'; $d.Size = New-Object System.Drawing.Size(640, 330); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.Font = $script:Ui.Form.Font
    $help = New-TkCtl Label "Download the image once from Microsoft's Windows 11 page (Download Windows 11 Disk Image (ISO) for x64 devices). The same page lists its SHA-256 under 'Verify your download'. For many PCs, put the file on a share and give the share path." 16 12 590 60
    $l1 = New-TkCtl Label 'Image: a file, a share path or a web address' 16 80 400 20
    $src = New-TkCtl TextBox '' 16 102 480 26
    $browse = New-TkCtl Button 'Browse...' 504 101 100 28
    $l2 = New-TkCtl Label "SHA-256 (64 letters and digits, from Microsoft's page)" 16 140 480 20
    $sha = New-TkCtl TextBox '' 16 162 588 26
    $ok = New-TkCtl Button 'Save' 404 220 96 32; $cancel = New-TkCtl Button 'Cancel' 508 220 96 32
    if ($Current) { $src.Text = [string]$Current.Source; $sha.Text = [string]$Current.Sha256 }
    $browse.Add_Click({ $o = New-Object System.Windows.Forms.OpenFileDialog; $o.Filter = 'Windows image (*.iso)|*.iso'; if ($o.ShowDialog() -eq 'OK') { $src.Text = $o.FileName } })
    $ok.Add_Click({
        if (-not $src.Text.Trim()) { [void][System.Windows.Forms.MessageBox]::Show($d, 'Say where the image is.', 'StillGood'); return }
        if ($sha.Text.Trim() -notmatch '^[0-9A-Fa-f]{64}$') { [void][System.Windows.Forms.MessageBox]::Show($d, 'The SHA-256 must be 64 letters and digits, copied from Microsoft''s page.', 'StillGood'); return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    $cancel.Add_Click({ $d.DialogResult = 'Cancel'; $d.Close() })
    $d.Controls.AddRange(@($help, $l1, $src, $browse, $l2, $sha, $ok, $cancel)); $d.AcceptButton = $ok; $d.CancelButton = $cancel
    if ($d.ShowDialog($script:Ui.Form) -ne 'OK') { return $null }
    return [pscustomobject]@{ Source = $src.Text.Trim(); Sha256 = $sha.Text.Trim().ToUpperInvariant() }
}

function Get-TkUiUpgradeConfig {
    $path = Join-Path $script:Ui.Root 'config\upgrade.json'
    $current = $null
    if (Test-Path -LiteralPath $path) {
        try { return (Get-TkUpgradeConfig -Path $path) } catch { Show-TkUiError "config\upgrade.json needs fixing: $($_.Exception.Message)" }
        try { $current = Read-TkJson $path; $current = [pscustomobject]@{ Source = Get-TkProp $current 'source'; Sha256 = Get-TkProp $current 'sha256' } } catch { }
    }
    $r = Show-TkUpgradeSettings -Current $current
    if (-not $r) { return $null }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Save-TkJson ([pscustomobject][ordered]@{ about = 'Written by the StillGood window.'; source = $r.Source; sha256 = $r.Sha256; dynamicUpdate = $true; stallMinutes = 10; dropFolderWaitHours = 24 }) $path
    return (Get-TkUpgradeConfig -Path $path)
}

function Start-TkUiUpgrade {
    param([bool]$CleanToo)
    $ui = $script:Ui
    if (-not $ui.Scan) { if ($CleanToo) { $ui.Then = { Start-TkUiUpgrade $true } } else { $ui.Then = { Start-TkUiUpgrade $false } }; Start-TkUiScan; return }
    $rd = $ui.Scan.Readiness
    if ($rd.Verdict -eq 'NotUpgradeable') { Show-TkUiError ("This PC cannot run Windows 11:`r`n- " + (@($rd.Blockers) -join "`r`n- ")); return }
    if ($rd.Verdict -eq 'FixFirst') { Show-TkUiError ("Fix these first, then try again:`r`n- " + (@($rd.Fixable) -join "`r`n- ")); return }
    $cfg = Get-TkUiUpgradeConfig
    if (-not $cfg) { return }
    $unsupported = $false
    if ($rd.Verdict -eq 'UnsupportedButUpgradeable') {
        $m = "This PC fails Microsoft's hardware check:`r`n- " + (@($rd.Bypassable) -join "`r`n- ") + "`r`n`r`nStillGood can still upgrade it with the unsupported-hardware option. Microsoft does not support Windows 11 on this hardware and does not guarantee updates for it. The decision is yours.`r`n`r`nUpgrade anyway?"
        if (-not (Confirm-TkUi $m 'Warning')) { return }
        $unsupported = $true
    }
    $steps = "The upgrade will:`r`n1. Get the image from $($cfg.Source) and check it against its SHA-256.`r`n2. Run Windows Setup's compatibility scan. If it finds a blocker, it stops and nothing changes.`r`n3. Upgrade in the background, keeping files, apps and settings. Signing out does not stop it.`r`n4. Restart the PC on its own when Setup is ready, so save open work first.`r`n5. At the first sign-in on the new Windows, delete the image"
    if ($CleanToo) { $steps += ' and clean the apps Windows 11 brings' }
    $steps += ".`r`n`r`nRunning Setup accepts the Microsoft Software License Terms for Windows 11 on this PC.`r`n`r`nStart the upgrade?"
    if (-not (Confirm-TkUi $steps)) { return }
    $jobArgs = @{ Config = $cfg; Unsupported = $unsupported; CleanToo = $CleanToo; Profile = $ui.Scan.Plan.Profile; Org = $ui.Org; Plan = (Get-TkUiTrimmedPlan) }
    Start-TkUiJob -Status 'Starting the upgrade ...' -Job Upgrade -Arguments $jobArgs -OnDone {
        param($res, $err)
        if ($err) { Show-TkUiError "The upgrade did not start: $err"; return }
        Show-TkMonitorWindow
    }
}

function Start-TkUiUndo {
    $latest = @(Get-ChildItem -LiteralPath (Join-Path (Get-TkDataRoot) 'undo') -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if (-not $latest.Count) { Show-TkUiInfo 'There is no clean-up to undo on this PC.'; return }
    $file = $latest[0].FullName
    $pv = Invoke-TkUndo -UndoFile $file
    $n = @($pv.Apps).Count
    $m = "Undo the clean-up from $($latest[0].LastWriteTime.ToString('g')): put back $($pv.Settings) settings and lift $($pv.Unblock) blocks.`r`n`r`nAlso reinstall the $n removed apps from the Microsoft Store now? This needs internet.`r`n`r`nYes: undo and reinstall.   No: undo only.   Cancel: change nothing."
    $answer = [System.Windows.Forms.MessageBox]::Show($script:Ui.Form, $m, 'StillGood', 'YesNoCancel', 'Question')
    if ($answer -eq 'Cancel') { return }
    Start-TkUiJob -Status 'Undoing the clean-up ...' -Job Undo -Arguments @{ File = $file; Reinstall = ($answer -eq 'Yes') } -OnDone {
        param($res, $err)
        if ($err) { Show-TkUiError "Undo stopped: $err"; return }
        $t = 'Done: {0} settings put back, {1} blocks lifted, {2} apps reinstalled.' -f $res.SettingsRestored, $res.Unblocked, $res.Reinstalled
        $left = @($res.ToReinstall)
        if ($left.Count) { $t += "`r`n`r`nPut these back from the Microsoft Store when you need them:`r`n" + (($left | ForEach-Object { "- $($_.Title)" }) -join "`r`n") }
        Show-TkUiInfo $t
        Start-TkUiScan
    }
}

function Update-TkMonitorWindow {
    $m = $script:Mon
    $s = Read-TkUpgradeState
    if (-not $s) { $m.Stage.Text = 'No upgrade has been started on this PC.'; $m.Message.Text = ''; $m.Bar.Visible = $false; return }
    $m.Stage.Text = Get-TkStageName $s.Stage
    $m.Message.Text = [string]$s.Message
    $pct = $null; $p = Get-TkProp $s 'Progress'
    if ($p) { $pct = Get-TkProp $p 'Percent' }
    if ($s.Stage -eq 'Upgrading') {
        $sp = Invoke-TkSys 'RegGet' @('HKLM\SYSTEM\Setup\MoSetup\Volatile', 'SetupProgress')
        if ($sp.Exists) { $pct = [double]$sp.Value; $m.Message.Text += "  Windows Setup reports $pct%." }
    }
    if (@('Done', 'Failed', 'RolledBack') -contains $s.Stage) { $m.Bar.Visible = $false }
    elseif ($null -ne $pct) { $m.Bar.Visible = $true; $m.Bar.Style = 'Continuous'; $m.Bar.Value = [int][math]::Max(0, [math]::Min(100, $pct)) }
    else { $m.Bar.Visible = $true; $m.Bar.Style = 'Marquee' }
    $lines = @(@(Get-TkProp $s 'History') | Where-Object { $_ } | ForEach-Object { '{0:HH:mm}  {1}' -f [datetime]$_.At, (Get-TkStageName $_.Stage) })
    $m.History.Text = ($lines -join "`r`n")
}

function Show-TkMonitorWindow {
    # A small window of its own: it can stay open while the main window is closed. It reads the upgrade's state file.
    if ($script:Mon.Form -and -not $script:Mon.Form.IsDisposed) { $script:Mon.Form.Activate(); return }
    $w = New-Object System.Windows.Forms.Form
    $w.Text = 'StillGood - Windows 11 upgrade'; $w.Size = New-Object System.Drawing.Size(620, 380); $w.StartPosition = 'CenterScreen'
    $w.Font = New-Object System.Drawing.Font('Segoe UI', 9.75); $w.BackColor = [System.Drawing.Color]::White
    $stage = New-TkCtl Label '' 18 16 570 30; $stage.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13); $stage.ForeColor = $script:Teal
    $msg = New-TkCtl Label '' 18 50 570 60
    $bar = New-TkCtl ProgressBar '' 18 114 570 18; $bar.MarqueeAnimationSpeed = 30
    $note = New-TkCtl Label 'Times are measured, never guessed: a time left appears only while downloading or checking the image.' 18 138 570 36; $note.ForeColor = [System.Drawing.Color]::Gray
    $hist = New-TkCtl TextBox '' 18 178 570 110; $hist.Multiline = $true; $hist.ReadOnly = $true; $hist.ScrollBars = 'Vertical'; $hist.BackColor = [System.Drawing.Color]::White
    $close = New-TkCtl Button 'Close (the upgrade keeps going)' 368 298 220 32
    $close.Add_Click({ $script:Mon.Form.Close() })
    $w.Controls.AddRange(@($stage, $msg, $bar, $note, $hist, $close))
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 2000
    $script:Mon = @{ Form = $w; Stage = $stage; Message = $msg; Bar = $bar; History = $hist; Timer = $t }
    $t.Add_Tick({ Update-TkMonitorWindow })
    $w.Add_FormClosed({ $script:Mon.Timer.Stop() })
    Update-TkMonitorWindow
    $t.Start()
    if ($script:Ui.Form -and $script:Ui.Form.Visible) { $w.Show($script:Ui.Form) } else { [void]$w.ShowDialog() }
}

function Show-TkWindow {
    param([Parameter(Mandatory = $true)][string]$Root, [ValidateSet('office', 'kiosk')][string]$Profile = 'office', [string]$OrgPath = '')
    if (-not ('TkNative.Dpi' -as [type])) { Add-Type -Namespace TkNative -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' }
    [void][TkNative.Dpi]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:Ui = @{ Root = $Root; Profile = $Profile; Org = $OrgPath; Scan = $null; Job = $null; OnDone = $null; Then = $null; Sync = (New-TkSync) }
    $ui = $script:Ui

    $f = New-Object System.Windows.Forms.Form
    $f.Text = "StillGood $((Get-TkProduct).Version)"; $f.StartPosition = 'CenterScreen'
    $f.Size = New-Object System.Drawing.Size(1060, 740); $f.MinimumSize = New-Object System.Drawing.Size(960, 660)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9.75); $f.BackColor = [System.Drawing.Color]::White
    $ui.Form = $f; $ui.Tips = New-Object System.Windows.Forms.ToolTip

    $head = New-Object System.Windows.Forms.Panel; $head.Dock = 'Top'; $head.Height = 66; $head.BackColor = $script:Teal
    $title = New-TkCtl Label 'StillGood' 18 8 300 34; $title.ForeColor = [System.Drawing.Color]::White; $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
    $sub = New-TkCtl Label 'Windows 11 for the PCs you already have. Nothing changes until you confirm.' 21 42 700 20; $sub.ForeColor = [System.Drawing.Color]::FromArgb(205, 228, 232)
    $head.Controls.AddRange(@($title, $sub))

    $left = New-Object System.Windows.Forms.Panel; $left.Dock = 'Left'; $left.Width = 244; $left.BackColor = [System.Drawing.Color]::FromArgb(243, 245, 247)
    $ui.Buttons = New-Object System.Collections.ArrayList
    $y = 18
    foreach ($a in @(@('Check this PC', 'Scan'), @('Clean apps', 'Clean'), @('Upgrade to Windows 11', 'Upgrade'), @('Upgrade + clean apps', 'UpgradeClean'), @('Watch the upgrade', 'Monitor'), @('Undo a clean-up', 'Undo'))) {
        $b = New-TkCtl Button $a[0] 14 $y 214 40
        $b.Tag = $a[1]; $b.FlatStyle = 'Flat'; $b.TextAlign = 'MiddleLeft'; $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        $b.BackColor = [System.Drawing.Color]::White; $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(206, 212, 218)
        $b.Add_Click({ param($sender, $e) Invoke-TkUiAction ([string]$sender.Tag) })
        [void]$ui.Buttons.Add($b); $left.Controls.Add($b)
        $y += 48
    }
    $grp = New-TkCtl GroupBox 'This PC is' 14 ($y + 8) 214 88
    $ui.Office = New-TkCtl RadioButton 'an office PC' 12 24 190 24
    $ui.Kiosk = New-TkCtl RadioButton 'a kiosk or point of sale' 12 52 196 24
    if ($Profile -eq 'kiosk') { $ui.Kiosk.Checked = $true } else { $ui.Office.Checked = $true }
    $ui.Office.Add_CheckedChanged({ if ($script:Ui.Office.Checked -and $script:Ui.Profile -ne 'office') { $script:Ui.Profile = 'office'; Start-TkUiScan } })
    $ui.Kiosk.Add_CheckedChanged({ if ($script:Ui.Kiosk.Checked -and $script:Ui.Profile -ne 'kiosk') { $script:Ui.Profile = 'kiosk'; Start-TkUiScan } })
    $grp.Controls.AddRange(@($ui.Office, $ui.Kiosk)); $left.Controls.Add($grp)
    $ui.ReportLink = New-TkCtl LinkLabel 'Open the full report' 18 ($y + 108) 200 22; $ui.ReportLink.Enabled = $false
    $ui.ReportLink.Add_LinkClicked({ if ($script:Ui.Scan) { Start-Process $script:Ui.Scan.Html } })
    $left.Controls.Add($ui.ReportLink)

    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 200; $bottom.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 12)
    $ui.Log = New-Object System.Windows.Forms.TextBox; $ui.Log.Multiline = $true; $ui.Log.ReadOnly = $true; $ui.Log.ScrollBars = 'Vertical'; $ui.Log.Dock = 'Fill'
    $ui.Log.Font = New-Object System.Drawing.Font('Consolas', 9); $ui.Log.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $statusRow = New-Object System.Windows.Forms.Panel; $statusRow.Dock = 'Top'; $statusRow.Height = 30
    $ui.Status = New-TkCtl Label 'Starting ...' 0 6 560 22
    $ui.Bar = New-TkCtl ProgressBar '' 580 8 180 14; $ui.Bar.Style = 'Marquee'; $ui.Bar.MarqueeAnimationSpeed = 30; $ui.Bar.Visible = $false
    $statusRow.Controls.AddRange(@($ui.Status, $ui.Bar))
    $bottom.Controls.Add($ui.Log); $bottom.Controls.Add($statusRow)

    $main = New-Object System.Windows.Forms.Panel; $main.Dock = 'Fill'; $main.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 0)
    $ui.Info = New-TkCtl Label '' 16 14 760 22
    $ui.Verdict = New-TkCtl Label '  Windows 11: checking ...' 16 42 760 32; $ui.Verdict.TextAlign = 'MiddleLeft'; $ui.Verdict.BackColor = [System.Drawing.Color]::FromArgb(238, 238, 238)
    $ui.GroupsTitle = New-TkCtl Label 'What Clean apps removes (untick a group to keep it)' 16 88 420 20; $ui.GroupsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)
    $ui.Groups = New-Object System.Windows.Forms.FlowLayoutPanel; $ui.Groups.Location = New-Object System.Drawing.Point(16, 112); $ui.Groups.Size = New-Object System.Drawing.Size(400, 250)
    $ui.Groups.FlowDirection = 'TopDown'; $ui.Groups.WrapContents = $false; $ui.Groups.AutoScroll = $true
    $never = New-TkCtl Label 'Never removed: Windows itself, Windows Security, Edge, App Installer, runtimes, languages, driver apps and your own software.' 16 366 400 40; $never.ForeColor = [System.Drawing.Color]::Gray
    $ui.ListTitle = New-TkCtl Label 'Will be removed' 436 88 340 20; $ui.ListTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)
    $ui.List = New-TkCtl ListBox '' 436 112 340 294; $ui.List.IntegralHeight = $false; $ui.List.HorizontalScrollbar = $true
    $main.Controls.AddRange(@($ui.Info, $ui.Verdict, $ui.GroupsTitle, $ui.Groups, $never, $ui.ListTitle, $ui.List))

    $f.Controls.AddRange(@($main, $bottom, $left, $head))
    $main.BringToFront()

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 250; $timer.Add_Tick({ Update-TkUiTick }); $ui.Timer = $timer
    $f.Add_Shown({ $script:Ui.Timer.Start(); Start-TkUiScan })
    $f.Add_FormClosing({ param($sender, $e) if ($script:Ui.Job) { $e.Cancel = $true; Show-TkUiInfo 'StillGood is still working. Close the window when it says it is done.' } })
    [void]$f.ShowDialog()
    $timer.Stop()
}

function Invoke-TkUiAction {
    param([string]$Action)
    if ($script:Ui.Job) { return }
    switch ($Action) {
        'Scan' { Start-TkUiScan }
        'Clean' { Start-TkUiClean }
        'Upgrade' { Start-TkUiUpgrade $false }
        'UpgradeClean' { Start-TkUiUpgrade $true }
        'Monitor' { Show-TkMonitorWindow }
        'Undo' { Start-TkUiUndo }
    }
}

Export-ModuleMember -Function *
