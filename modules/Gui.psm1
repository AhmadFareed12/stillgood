# Gui.psm1 - the StillGood window (WinForms). Open it with StillGood.cmd (double-click) or StillGood.ps1 -Mode Window.
# Actions on the left, what the PC looks like and what will change in the middle, a live log at the bottom.
# The work runs in a background runspace (GuiCore.psm1), so the window stays responsive.
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('TkNative.TkTree' -as [type])) {
    # A tree with tick boxes that ignores a double-click on a tick box: the standard TreeView then shows a tick that
    # does not match its state (a long-standing Windows bug).
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
namespace TkNative {
    public class TkTree : System.Windows.Forms.TreeView {
        protected override void WndProc(ref System.Windows.Forms.Message m) {
            if (m.Msg == 0x203) {
                long lp = m.LParam.ToInt64();
                System.Windows.Forms.TreeViewHitTestInfo hit = this.HitTest((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF));
                if (hit.Location == System.Windows.Forms.TreeViewHitTestLocations.StateImage) { m.Result = System.IntPtr.Zero; return; }
            }
            base.WndProc(ref m);
        }
    }
}
'@
}

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

function Measure-TkText {
    # Height a text needs when it wraps at this width.
    param([string]$Text, $Font, [int]$Width)
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    return [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font, (New-Object System.Drawing.Size([Math]::Max(10, $Width), 0)), $flags).Height
}

function Set-TkUiLayout {
    # Lays out the middle of the window for its actual size, from measured text: an old PC's small screen, a large
    # one, 100 to 200 percent display scaling and long texts all fit without cutting anything off.
    $ui = $script:Ui
    if (-not $ui.Tree -or -not $ui.Main -or -not $ui.Tabs) { return }
    $s = $ui.Scale; $pad = [int](16 * $s)
    $W = $ui.Main.ClientSize.Width; $H = $ui.Main.ClientSize.Height
    $inner = [Math]::Max([int](300 * $s), $W - 2 * $pad)
    $ui.Info.SetBounds($pad, [int](12 * $s), $inner, [int](22 * $s))
    $vh = Measure-TkText $ui.Verdict.Text $ui.Verdict.Font ($inner - [int](20 * $s))
    $ui.Verdict.SetBounds($pad, $ui.Info.Bottom + [int](6 * $s), $inner, [Math]::Max([int](34 * $s), $vh + [int](12 * $s)))
    $ty = $ui.Verdict.Bottom + [int](10 * $s)
    $ui.Tabs.SetBounds($pad, $ty, $inner, [Math]::Max([int](120 * $s), $H - $ty - [int](6 * $s)))
    # Inside the Clean apps tab: the summary line, the list, and what is never removed.
    $tw = $ui.TabApps.ClientSize.Width; $th = $ui.TabApps.ClientSize.Height
    $ip = [int](8 * $s); $iw = [Math]::Max([int](200 * $s), $tw - 2 * $ip)
    $ui.GroupsTitle.SetBounds($ip, $ip, $iw, (Measure-TkText $ui.GroupsTitle.Text $ui.GroupsTitle.Font $iw) + [int](2 * $s))
    $nh = Measure-TkText $ui.Never.Text $ui.Never.Font $iw
    $ui.Never.SetBounds($ip, $th - $nh - [int](4 * $s), $iw, $nh)
    $y = $ui.GroupsTitle.Bottom + [int](4 * $s)
    $ui.Tree.SetBounds($ip, $y, $iw, [Math]::Max([int](60 * $s), $ui.Never.Top - $y - [int](4 * $s)))
}

function Show-TkUiSpeed {
    # The "Make it faster" tab: each finding, most important first, with what to do; then what is already good.
    param($Speed)
    $ui = $script:Ui; $r = $ui.Speed
    $r.Clear()
    $bold = New-Object System.Drawing.Font($r.Font, [System.Drawing.FontStyle]::Bold)
    $black = [System.Drawing.Color]::FromArgb(30, 30, 30); $grey = [System.Drawing.Color]::FromArgb(85, 85, 85)
    $tone = @{ High = [System.Drawing.Color]::FromArgb(176, 74, 0); Medium = [System.Drawing.Color]::FromArgb(16, 70, 120); Low = [System.Drawing.Color]::FromArgb(110, 110, 110) }
    $add = { param([string]$Text, $Font, $Color) $r.SelectionStart = $r.TextLength; $r.SelectionLength = 0; $r.SelectionFont = $Font; $r.SelectionColor = $Color; $r.AppendText($Text) }
    $fs = @(); if ($Speed) { $fs = @($Speed.Findings | Where-Object { $_ }) }
    if ($fs.Count) { & $add "What slows this PC down, most important first. Nothing has been changed.`n`n" $r.Font $grey }
    else { & $add "Nothing found that slows this PC down.`n`n" $bold $script:Teal }
    foreach ($f in $fs) {
        & $add ("{0}   " -f $f.Impact.ToUpperInvariant()) $bold $tone[[string]$f.Impact]
        & $add ("{0}`n" -f $f.Title) $bold $black
        & $add ("{0}`n" -f $f.Found) $r.Font $grey
        & $add ("What to do: {0}`n`n" -f $f.Fix) $r.Font $black
    }
    if ($Speed -and @($Speed.Good | Where-Object { $_ }).Count) { & $add ('Already good: ' + (@($Speed.Good) -join ', ') + '.') $r.Font $script:Teal }
    $r.SelectionStart = 0; $r.SelectionLength = 0; $r.ScrollToCaret()
    $ui.TabSpeed.Text = "Make it faster ($($fs.Count))"
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
    $ui.Tree.Enabled = -not $Busy
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
    # The plan with exactly what is ticked in the tree.
    $ui = $script:Ui
    $on = @(foreach ($g in @($ui.Tree.Nodes)) { foreach ($n in @($g.Nodes)) { if ($n.Checked) { [string]$n.Tag } } })
    return (Select-TkPlanItems -Plan $ui.Scan.Plan -Selected $on)
}

function Update-TkUiSummary {
    # The line above the tree and each group's "ticked of total", after any tick changes.
    $ui = $script:Ui
    if (-not $ui.Scan) { return }
    foreach ($g in @($ui.Tree.Nodes)) {
        $on = @(@($g.Nodes) | Where-Object { $_.Checked }).Count
        $g.Text = "$($g.Name)   ($on of $($g.Nodes.Count))"
    }
    $plan = Get-TkUiTrimmedPlan
    $c = $plan.Counts
    $t = "Clean apps will remove $($c.Remove) app$(if ($c.Remove -ne 1) { 's' }) and block $($c.Block) before they arrive"
    $sets = @($plan.Items | Where-Object { $_.Action -eq 'Setting' }).Count
    if ($sets) { $t += ", and turn off $sets thing$(if ($sets -ne 1) { 's' }) that slow$(if ($sets -eq 1) { 's' }) the start-up" }
    $ui.GroupsTitle.Text = "$t. Tick a group for all its apps, or tick and untick apps one by one."
    $ui.TabApps.Text = "Clean apps ($($c.Remove))"
    Set-TkUiLayout
}

function Sync-TkUiTicks {
    # A group's tick sets all its apps; an app's tick shows on its group (ticked while any app in it is).
    param($Node)
    $ui = $script:Ui
    if ($ui.Syncing) { return }
    $ui.Syncing = $true
    try {
        if ($null -eq $Node.Parent) { foreach ($n in @($Node.Nodes)) { $n.Checked = $Node.Checked } }
        else { $Node.Parent.Checked = [bool]@(@($Node.Parent.Nodes) | Where-Object { $_.Checked }).Count }
    } finally { $ui.Syncing = $false }
    Update-TkUiSummary
}

function Update-TkUiScan {
    # Fill the window from a finished check.
    $ui = $script:Ui; $s = $ui.Scan
    $os = $s.Os
    $adm = 'yes'; if (-not $s.Elevated) { $adm = 'no (some checks could not be read)' }
    $ui.Info.Text = "$env:COMPUTERNAME  -  $($os.Caption) $($os.DisplayVersion) (build $($os.Build).$($os.Ubr))  -  administrator: $adm"
    $ui.Tips.SetToolTip($ui.Info, $ui.Info.Text)
    $v = $s.Readiness.Verdict
    # Green: meets the requirements. Calm blue: StillGood can upgrade it with the unsupported-hardware option.
    # Orange: fix something first. Red: Windows 11 cannot run.
    $colors = @{ Supported = @(227, 244, 230, 20, 92, 38); ProbablySupported = @(227, 244, 230, 20, 92, 38); UnsupportedButUpgradeable = @(228, 240, 251, 16, 70, 120); FixFirst = @(255, 243, 214, 122, 75, 0); NotUpgradeable = @(253, 227, 225, 138, 28, 18) }
    $c = $colors[$v]
    $ui.Verdict.BackColor = [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2]); $ui.Verdict.ForeColor = [System.Drawing.Color]::FromArgb($c[3], $c[4], $c[5])
    $t = [string]$s.Readiness.Summary
    if ($v -eq 'Supported' -or $v -eq 'ProbablySupported') { $t = "Windows 11: $t" }
    if ($v -eq 'FixFirst') { $t = 'Windows 11: fix this first, then this PC can be upgraded: ' + (@($s.Readiness.Fixable) -join '; ') + '.' }
    if ($v -eq 'NotUpgradeable') { $t = "Windows 11 can't run on this PC: " + (@($s.Readiness.Blockers) -join '; ') + '.' }
    $ui.Verdict.Text = $t
    # The tree: every group, every app in it, each with its own tick, as the plan starts them.
    $ui.Syncing = $true
    $ui.Tree.BeginUpdate(); $ui.Tree.Nodes.Clear()
    foreach ($g in @(Get-TkPlanGroups -Plan $s.Plan)) {
        $gn = $ui.Tree.Nodes.Add($g.Title); $gn.Name = $g.Title; $gn.Tag = $g.Key
        foreach ($i in @($g.Items)) {
            $n = $gn.Nodes.Add((Get-TkChoiceText $i)); $n.Tag = [string]$i.Name; $n.NodeFont = $ui.RowFont
            $tip = [string]$i.Name; if ($i.Note) { $tip += "`r`n" + $i.Note }; $n.ToolTipText = $tip
            $n.Checked = [bool]$i.Selected
        }
        $gn.Checked = [bool]@(@($gn.Nodes) | Where-Object { $_.Checked }).Count
    }
    $ui.Tree.ExpandAll()
    if ($ui.Tree.Nodes.Count) { $ui.Tree.Nodes[0].EnsureVisible() }
    $ui.Tree.EndUpdate()
    $ui.Syncing = $false
    $ui.ReportLink.Enabled = $true
    Show-TkUiSpeed (Get-TkProp $s 'Speed')
    if ($ui.Tree.Nodes.Count) { Update-TkUiSummary }
    else { $ui.GroupsTitle.Text = 'Nothing to remove: the apps StillGood knows are already gone from this PC.'; Set-TkUiLayout }
}

function Start-TkUiScan {
    $ui = $script:Ui
    Start-TkUiJob -Status 'Checking this PC. Nothing is changed.' -Job Scan -Arguments @{ Org = $ui.Org } -OnDone {
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
    # Show the list first, so nobody confirms without seeing what goes.
    if ($ui.Tabs.SelectedTab -ne $ui.TabApps) { $ui.Tabs.SelectedTab = $ui.TabApps; [System.Windows.Forms.Application]::DoEvents() }
    $plan = Get-TkUiTrimmedPlan
    if (-not ($plan.Counts.Remove + $plan.Counts.Block + @($plan.Items | Where-Object { $_.Action -eq 'Setting' }).Count)) { Show-TkUiInfo 'Nothing to remove: nothing is ticked, or these apps are already gone.'; return }
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
    # Asks where the Windows 11 image in this PC's language is, and its SHA-256.
    param([string]$Language, $Current)
    $d = New-Object System.Windows.Forms.Form
    $d.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96); $d.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $d.Text = 'StillGood - the Windows 11 image'; $d.Size = New-Object System.Drawing.Size(640, 360); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.Font = $script:Ui.Form.Font
    $help = New-TkCtl Label "This PC's Windows was installed in $Language, so it needs the $Language image. Download it once from Microsoft's Windows 11 page (Download Windows 11 Disk Image (ISO) for x64 devices); the same page lists its SHA-256 under 'Verify your download'. For many PCs, put it on a share." 16 12 590 86
    $l1 = New-TkCtl Label 'Image: a file, a share path or a web address' 16 106 480 20
    $src = New-TkCtl TextBox '' 16 128 480 26
    $browse = New-TkCtl Button 'Browse...' 504 127 100 28
    $l2 = New-TkCtl Label "SHA-256 (64 letters and digits, from Microsoft's page)" 16 166 480 20
    $sha = New-TkCtl TextBox '' 16 188 588 26
    $ok = New-TkCtl Button 'Save' 404 246 96 32; $cancel = New-TkCtl Button 'Cancel' 508 246 96 32
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

function Get-TkUiUpgradeImage {
    # The image for this PC's Windows language, from config\upgrade.json. If there is none yet, ask for it and add it.
    $path = Join-Path $script:Ui.Root 'config\upgrade.json'
    $culture = Get-TkOsLanguage
    $lang = "$(Get-TkLanguageName $culture) ($culture)"
    $raw = $null
    if (Test-Path -LiteralPath $path) {
        try { $raw = Read-TkJson $path; return (Resolve-TkUpgradeImage -Config (Get-TkUpgradeConfig -Path $path) -Culture $culture) }
        catch { Show-TkUiInfo $_.Exception.Message }
    }
    $r = Show-TkUpgradeSettings -Language $lang
    if (-not $r) { return $null }
    $images = [ordered]@{}
    if ($raw -and (Get-TkProp $raw 'images')) { foreach ($p in $raw.images.PSObject.Properties) { $images[$p.Name] = $p.Value } }
    $images[$culture] = [pscustomobject]@{ source = $r.Source; sha256 = $r.Sha256 }
    $obj = [ordered]@{ about = 'Windows 11 images by Windows language. Written by the StillGood window.'; images = [pscustomobject]$images }
    foreach ($k in @('dynamicUpdate', 'stallMinutes', 'dropFolderWaitHours')) { $v = $null; if ($raw) { $v = Get-TkProp $raw $k }; if ($null -ne $v) { $obj[$k] = $v } }
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Save-TkJson ([pscustomobject]$obj) $path
    try { return (Resolve-TkUpgradeImage -Config (Get-TkUpgradeConfig -Path $path) -Culture $culture) }
    catch { Show-TkUiError "config\upgrade.json needs fixing: $($_.Exception.Message)"; return $null }
}

function Start-TkUiUpgrade {
    param([bool]$CleanToo)
    $ui = $script:Ui
    if (-not $ui.Scan) { if ($CleanToo) { $ui.Then = { Start-TkUiUpgrade $true } } else { $ui.Then = { Start-TkUiUpgrade $false } }; Start-TkUiScan; return }
    $rd = $ui.Scan.Readiness
    if ($rd.Verdict -eq 'NotUpgradeable') { Show-TkUiError ("This PC cannot run Windows 11:`r`n- " + (@($rd.Blockers) -join "`r`n- ")); return }
    if ($rd.Verdict -eq 'FixFirst') { Show-TkUiError ("Fix these first, then try again:`r`n- " + (@($rd.Fixable) -join "`r`n- ")); return }
    $cfg = Get-TkUiUpgradeImage
    if (-not $cfg) { return }
    $unsupported = $false
    if ($rd.Verdict -eq 'UnsupportedButUpgradeable') {
        $m = "This PC doesn't pass Microsoft's hardware check:`r`n- " + (@($rd.Bypassable) -join "`r`n- ") + "`r`n`r`nStillGood can still upgrade it with the unsupported-hardware option. Microsoft does not support Windows 11 on this hardware and does not guarantee updates for it. The decision is yours.`r`n`r`nUpgrade anyway?"
        if (-not (Confirm-TkUi $m 'Warning')) { return }
        $unsupported = $true
    }
    $steps = "The upgrade will:`r`n1. Get the $($cfg.LanguageName) image from $($cfg.Source) and check it against its SHA-256.`r`n2. Run Windows Setup's compatibility scan. If it finds a blocker, it stops and nothing changes.`r`n3. Upgrade in the background, keeping files, apps and settings. Signing out does not stop it.`r`n4. Restart the PC on its own when Setup is ready, so save open work first.`r`n5. At the first sign-in on the new Windows, delete the image"
    if ($CleanToo) { $steps += ' and clean the apps Windows 11 brings' }
    $steps += ".`r`n`r`nRunning Setup accepts the Microsoft Software License Terms for Windows 11 on this PC.`r`n`r`nStart the upgrade?"
    if (-not (Confirm-TkUi $steps)) { return }
    $jobArgs = @{ Config = $cfg; Unsupported = $unsupported; CleanToo = $CleanToo; Org = $ui.Org; Plan = (Get-TkUiTrimmedPlan) }
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
    $w.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96); $w.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
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
    param([Parameter(Mandatory = $true)][string]$Root, [string]$OrgPath = '')
    if (-not ('TkNative.Dpi' -as [type])) { Add-Type -Namespace TkNative -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' }
    [void][TkNative.Dpi]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:Ui = @{ Root = $Root; Org = $OrgPath; Scan = $null; Job = $null; OnDone = $null; Then = $null; Syncing = $false; Sync = (New-TkSync) }
    $ui = $script:Ui
    # Display scaling (100 to 200 percent): sizes below are in pixels at 100 percent and scale with the screen.
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $ui.Scale = [double]$g.DpiX / 96; $g.Dispose()

    $f = New-Object System.Windows.Forms.Form
    $f.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96); $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $f.Text = "StillGood $((Get-TkProduct).Version)"; $f.StartPosition = 'CenterScreen'
    $f.Size = New-Object System.Drawing.Size(1060, 740); $f.MinimumSize = New-Object System.Drawing.Size(960, 660)
    # Fit the screen of an old PC: 1366x768 and 1024x768 leave about 728 pixels above the taskbar (seen in the lab).
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($wa.Width -lt $f.Width -or $wa.Height -lt $f.Height) {
        $f.MinimumSize = New-Object System.Drawing.Size([Math]::Min(960, $wa.Width), [Math]::Min(660, $wa.Height))
        $f.Size = New-Object System.Drawing.Size([Math]::Min($f.Width, $wa.Width), [Math]::Min($f.Height, $wa.Height))
    }
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
    $ui.ReportLink = New-TkCtl LinkLabel 'Open the full report' 18 ($y + 10) 200 22; $ui.ReportLink.Enabled = $false
    $ui.ReportLink.Add_LinkClicked({ if ($script:Ui.Scan) { Start-Process $script:Ui.Scan.Html } })
    $left.Controls.Add($ui.ReportLink)

    $bottom = New-Object System.Windows.Forms.Panel; $bottom.Dock = 'Bottom'; $bottom.Height = 200; $bottom.Padding = New-Object System.Windows.Forms.Padding(14, 6, 14, 12)
    if ($wa.Height -lt 800) { $bottom.Height = 150 }   # a small screen: more room for the list of apps
    $ui.Log = New-Object System.Windows.Forms.TextBox; $ui.Log.Multiline = $true; $ui.Log.ReadOnly = $true; $ui.Log.ScrollBars = 'Vertical'; $ui.Log.Dock = 'Fill'
    $ui.Log.Font = New-Object System.Drawing.Font('Consolas', 9); $ui.Log.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $statusRow = New-Object System.Windows.Forms.Panel; $statusRow.Dock = 'Top'; $statusRow.Height = 30
    $ui.Status = New-TkCtl Label 'Starting ...' 0 6 560 22; $ui.Status.AutoEllipsis = $true
    $ui.Bar = New-TkCtl ProgressBar '' 580 8 180 14; $ui.Bar.Style = 'Marquee'; $ui.Bar.MarqueeAnimationSpeed = 30; $ui.Bar.Visible = $false
    $statusRow.Controls.AddRange(@($ui.Status, $ui.Bar))
    $bottom.Controls.Add($ui.Log); $bottom.Controls.Add($statusRow)

    $main = New-Object System.Windows.Forms.Panel; $main.Dock = 'Fill'; $main.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 0)
    $ui.Main = $main
    $ui.Info = New-TkCtl Label '' 16 14 760 22; $ui.Info.AutoEllipsis = $true
    $ui.Verdict = New-TkCtl Label 'Windows 11: checking ...' 16 42 760 32; $ui.Verdict.TextAlign = 'MiddleLeft'; $ui.Verdict.BackColor = [System.Drawing.Color]::FromArgb(238, 238, 238)
    $ui.Verdict.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $ui.GroupsTitle = New-TkCtl Label 'What Clean apps removes' 16 88 420 20; $ui.GroupsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75)
    # One list: the groups, and every app under its group with its own tick. The tree's font is the bold one (the
    # group names) and the apps are regular: a node font bolder than the tree's would be clipped.
    $ui.Tree = New-Object TkNative.TkTree
    $ui.Tree.CheckBoxes = $true; $ui.Tree.ShowNodeToolTips = $true; $ui.Tree.ShowLines = $false; $ui.Tree.HideSelection = $true
    $ui.Tree.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.75); $ui.RowFont = New-Object System.Drawing.Font('Segoe UI', 9.75)
    $ui.Tree.ItemHeight = [int](24 * $ui.Scale); $ui.Tree.BorderStyle = 'FixedSingle'
    $ui.Tree.Add_AfterCheck({ param($sender, $e) Sync-TkUiTicks $e.Node })
    $never = New-TkCtl Label 'Never removed: Windows itself, Windows Security, Edge, App Installer, runtimes, languages, driver apps and your own software.' 16 366 400 40; $never.ForeColor = [System.Drawing.Color]::Gray
    $ui.Never = $never
    # Two tabs under the verdict: what would make this PC faster, and the apps Clean apps removes.
    $ui.Tabs = New-Object System.Windows.Forms.TabControl
    $ui.TabSpeed = New-Object System.Windows.Forms.TabPage; $ui.TabSpeed.Text = 'Make it faster'; $ui.TabSpeed.BackColor = [System.Drawing.Color]::White
    $ui.TabSpeed.Padding = New-Object System.Windows.Forms.Padding(10, 8, 4, 4)
    $ui.TabApps = New-Object System.Windows.Forms.TabPage; $ui.TabApps.Text = 'Clean apps'; $ui.TabApps.BackColor = [System.Drawing.Color]::White
    $ui.Speed = New-Object System.Windows.Forms.RichTextBox
    $ui.Speed.ReadOnly = $true; $ui.Speed.BorderStyle = 'None'; $ui.Speed.BackColor = [System.Drawing.Color]::White; $ui.Speed.Dock = 'Fill'; $ui.Speed.DetectUrls = $false
    $ui.Speed.Font = New-Object System.Drawing.Font('Segoe UI', 9.75); $ui.Speed.Text = 'Checking this PC ...'
    $ui.TabSpeed.Controls.Add($ui.Speed)
    $ui.TabApps.Controls.AddRange(@($ui.GroupsTitle, $ui.Tree, $never))
    $ui.Tabs.TabPages.AddRange(@($ui.TabSpeed, $ui.TabApps))
    $ui.TabApps.Add_Resize({ Set-TkUiLayout })
    $main.Controls.AddRange(@($ui.Info, $ui.Verdict, $ui.Tabs))
    $main.Add_Resize({ Set-TkUiLayout })

    $f.Controls.AddRange(@($main, $bottom, $left, $head))
    $main.BringToFront()

    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 250; $timer.Add_Tick({ Update-TkUiTick }); $ui.Timer = $timer
    $f.Add_Shown({
        # After display scaling has resized the window: keep it on the screen it opened on.
        $fm = $script:Ui.Form; $wa = [System.Windows.Forms.Screen]::FromControl($fm).WorkingArea
        if ($fm.Width -gt $wa.Width -or $fm.Height -gt $wa.Height) {
            $fm.MinimumSize = New-Object System.Drawing.Size([Math]::Min($fm.MinimumSize.Width, $wa.Width), [Math]::Min($fm.MinimumSize.Height, $wa.Height))
            $fm.SetBounds($wa.Left, $wa.Top, [Math]::Min($fm.Width, $wa.Width), [Math]::Min($fm.Height, $wa.Height))
        }
        Set-TkUiLayout
        $script:Ui.Timer.Start(); Start-TkUiScan
    })
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
