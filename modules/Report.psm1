# Report.psm1 - the read-only report: this PC, Windows 11 readiness, and what Clean apps would do.
# HTML for people, JSON for tools. Building it changes nothing.
Set-StrictMode -Version 2.0

function New-TkReport {
    param([Parameter(Mandatory = $true)]$Inventory, $Readiness, $Plan, $OneDrive)
    return [pscustomobject]@{
        Kind = 'Report'; Product = (Get-TkProduct).Name; Version = (Get-TkProduct).Version
        Created = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME; Elevated = [bool]$Inventory.Elevated
        Os = $Inventory.Os; Summary = $Inventory.Summary; Readiness = $Readiness; Plan = $Plan; OneDrive = @($OneDrive | Where-Object { $_ })
        Startup = @($Inventory.Startup | Where-Object { $_ })
        Programs = @($Inventory.Programs | Where-Object { $_ } | Select-Object DisplayName, Publisher, Version | Sort-Object DisplayName)
    }
}

function Save-TkReport {
    param([Parameter(Mandatory = $true)]$Report, [Parameter(Mandatory = $true)][string]$Dir)
    $json = Join-Path $Dir 'report.json'; $html = Join-Path $Dir 'report.html'
    Save-TkJson $Report $json
    [System.IO.File]::WriteAllText($html, (ConvertTo-TkReportHtml $Report), (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Json = $json; Html = $html }
}

function ConvertTo-TkCheckLabel {
    param($Check)
    if ($Check.Status -eq 'Pass') { return @('ok', 'OK') }
    if ($Check.Status -eq 'Unknown') { return @('unk', 'Not read') }
    if ($Check.Fixable) { return @('warn', 'Fix first') }
    if ($Check.Bypassable) { return @('warn', 'Fails Microsoft''s check') }
    return @('bad', 'Blocker')
}

function ConvertTo-TkReportHtml {
    param([Parameter(Mandatory = $true)]$Report)
    $sb = New-Object System.Text.StringBuilder
    function Put([string]$s) { [void]$sb.Append($s) }
    function Esc($t) { return [System.Net.WebUtility]::HtmlEncode([string]$t) }
    function Rows($items, [string[]]$cols) {
        foreach ($i in @($items)) { Put '<tr>'; foreach ($c in $cols) { Put "<td>$(Esc (Get-TkProp $i $c))</td>" }; Put '</tr>' }
    }
    $os = $Report.Os
    Put '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    Put "<title>$(Esc $Report.Product) report &middot; $(Esc $Report.Computer)</title><style>"
    Put 'body{font:15px/1.5 "Segoe UI",system-ui,sans-serif;color:#1c1c1c;max-width:1040px;margin:32px auto;padding:0 20px}'
    Put 'h1{font-size:28px;margin:0}h2{font-size:20px;margin:36px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{font-size:16px;margin:22px 0 6px}'
    Put '.sub{color:#666;margin:2px 0 0}table{border-collapse:collapse;width:100%;margin:6px 0 10px}td,th{border-bottom:1px solid #eee;padding:6px 8px;text-align:left;vertical-align:top}'
    Put 'th{font-weight:600;background:#fafafa}.chip{display:inline-block;padding:1px 8px;border-radius:10px;font-size:13px}.ok{background:#e3f4e6;color:#145c26}'
    Put '.warn{background:#fff3d6;color:#7a4b00}.bad{background:#fde3e1;color:#8a1c12}.unk{background:#eee;color:#555}.verdict{font-size:17px;padding:10px 14px;border-radius:8px}'
    Put 'dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 18px}dt{color:#666}dd{margin:0}details{margin:10px 0}summary{cursor:pointer;font-weight:600}'
    Put 'code{background:#f4f4f4;padding:1px 5px;border-radius:4px}.counts{color:#444}footer{margin:40px 0;color:#666;font-size:14px}</style></head><body>'
    Put "<header><h1>$(Esc $Report.Computer)</h1><p class=""sub"">$(Esc $Report.Product) $(Esc $Report.Version) &middot; report only, nothing was changed &middot; $(Esc $Report.Created)</p></header>"

    Put '<h2>This PC</h2><dl>'
    Put "<dt>Windows</dt><dd>$(Esc $os.Caption) $(Esc $os.DisplayVersion) (build $(Esc $os.Build).$(Esc $os.Ubr))</dd>"
    $lang = [string](Get-TkProp $os 'Language')
    if ($lang) { Put "<dt>Installed in</dt><dd>$(Esc (Get-TkLanguageName $lang)) ($(Esc $lang)). An upgrade needs a Windows 11 image in this language.</dd>" }
    $adm = 'Yes'; if (-not $Report.Elevated) { $adm = 'No - TPM, Secure Boot and other users'' apps could not be read. Run as administrator for the full report.' }
    Put "<dt>Run as administrator</dt><dd>$(Esc $adm)</dd>"
    Put "<dt>Apps</dt><dd>$(Esc $Report.Summary.Apps) installed, $(Esc $Report.Summary.ProvisionedForNewUsers) set up for new users</dd>"
    Put "<dt>Desktop programs</dt><dd>$(Esc $Report.Summary.DesktopPrograms)</dd><dt>Startup items</dt><dd>$(Esc $Report.Summary.StartupItems)</dd></dl>"

    if ($Report.Readiness) {
        $rd = $Report.Readiness
        $cls = @{ Supported = 'ok'; ProbablySupported = 'ok'; UnsupportedButUpgradeable = 'warn'; FixFirst = 'warn'; NotUpgradeable = 'bad' }[$rd.Verdict]
        Put "<h2>Windows 11 readiness</h2><p class=""verdict $cls"">$(Esc $rd.Summary)</p>"
        Put '<table><tr><th>Check</th><th>Needs</th><th>Found</th><th>Result</th><th>Note</th></tr>'
        foreach ($c in @($rd.Checks)) {
            $l = ConvertTo-TkCheckLabel $c
            Put "<tr><td>$(Esc $c.Name)</td><td>$(Esc $c.Required)</td><td>$(Esc $c.Found)</td><td><span class=""chip $($l[0])"">$(Esc $l[1])</span></td><td>$(Esc $c.Note)</td></tr>"
        }
        Put '</table>'
    }

    if ($Report.Plan) {
        $p = $Report.Plan; $c = $p.Counts
        Put "<h2>Clean apps preview</h2><p>Choices: $(Esc (Get-TkSelectionText $p)). Every app can be ticked or unticked in the window, or with -Include and -Exclude.</p>"
        Put "<p class=""counts""><b>$($c.Remove)</b> will be removed &middot; <b>$($c.Block)</b> blocked before they arrive &middot; $($c.Keep) kept &middot; $($c.Unknown) not in the catalog (kept) &middot; $($c.Protected) protected</p>"
        $sel = { param($a) @($p.Items | Where-Object { $_.Action -eq $a }) }
        Put '<h3>Will be removed, for every user and for new users</h3><table><tr><th>App</th><th>Package</th><th>Why</th><th>To put it back</th></tr>'
        foreach ($i in (& $sel 'Remove')) { Put "<tr><td>$(Esc $i.Title)</td><td><code>$(Esc $i.Name)</code></td><td>$(Esc $i.Reason)</td><td><code>$(Esc $i.Restore)</code></td></tr>" }
        Put '</table>'
        $blk = @(& $sel 'Block')
        if ($blk.Count) { Put '<h3>Blocked before they arrive</h3><table><tr><th>App</th><th>Package</th></tr>'; foreach ($i in $blk) { Put "<tr><td>$(Esc $i.Title)</td><td><code>$(Esc $i.Name)</code></td></tr>" }; Put '</table>' }
        Put '<h3>Settings that keep the PC clean</h3><table><tr><th>Where</th><th>Setting</th><th>New value</th><th>Why</th></tr>'
        foreach ($s in @($p.Settings)) {
            $where = @{ Users = 'Every user and new users'; Machine = 'This PC'; NewUsers = 'New users only' }[$s.Scope]
            $val = $s.Value; if ($s.Kind -eq 'Delete') { $val = '(removed)' }
            Put "<tr><td>$(Esc $where)</td><td><code>$(Esc $s.Name)</code></td><td>$(Esc $val)</td><td>$(Esc $s.Why)</td></tr>"
        }
        Put '</table>'
        foreach ($sec in @(@('Keep', 'Kept (not ticked, or never removed)'), @('Unknown', 'Not in the catalog, so kept'), @('Protected', 'Protected, never removed'))) {
            $list = @(& $sel $sec[0])
            Put "<details><summary>$(Esc $sec[1]) ($($list.Count))</summary><table><tr><th>App</th><th>Package</th><th>Why</th></tr>"
            foreach ($i in $list) { Put "<tr><td>$(Esc $i.Title)</td><td><code>$(Esc $i.Name)</code></td><td>$(Esc $i.Reason)</td></tr>" }
            Put '</table></details>'
        }
    }

    if (@($Report.OneDrive).Count) {
        Put '<h2>OneDrive</h2><p>Clean apps never removes OneDrive for anyone who has a profile on this PC.</p><table><tr><th>Profile</th><th>OneDrive</th></tr>'
        foreach ($o in @($Report.OneDrive)) {
            $t = @{ Uses = 'Keeps files in OneDrive'; NotUsed = 'No OneDrive folder'; Unknown = 'Could not check (run as administrator)' }[$o.State]
            Put "<tr><td>$(Esc $o.Profile)</td><td>$(Esc $t)</td></tr>"
        }
        Put '</table>'
    }
    Put "<details><summary>Startup items ($(@($Report.Startup).Count))</summary><table><tr><th>Name</th><th>Command</th><th>Where</th></tr>"
    Rows $Report.Startup @('Name', 'Command', 'Location'); Put '</table></details>'
    Put "<details><summary>Desktop programs ($(@($Report.Programs).Count))</summary><table><tr><th>Program</th><th>Publisher</th><th>Version</th></tr>"
    Rows $Report.Programs @('DisplayName', 'Publisher', 'Version'); Put '</table></details>'
    Put '<footer>Nothing on this PC was changed to make this report. Clean apps and Upgrade show their own preview and wait for a confirmation before they change anything.</footer></body></html>'
    return $sb.ToString()
}

function Write-TkReportSummary {
    param([Parameter(Mandatory = $true)]$Report, $Paths)
    $os = $Report.Os
    Write-Host ''
    Write-Host ("  {0}: {1} {2} (build {3})" -f $Report.Computer, $os.Caption, $os.DisplayVersion, $os.Build)
    if (-not $Report.Elevated) { Write-Host '  Not run as administrator: some checks could not be read.' -ForegroundColor Yellow }
    if ($Report.Readiness) {
        Write-Host "  Windows 11: $($Report.Readiness.Summary)"
        foreach ($b in @($Report.Readiness.Blockers) + @($Report.Readiness.Fixable)) { if ($b) { Write-Host "    - $b" -ForegroundColor Yellow } }
    }
    if ($Report.Plan) {
        $c = $Report.Plan.Counts
        Write-Host ("  Clean apps ({0}): {1} to remove, {2} to block ahead, {3} kept, {4} not in the catalog, {5} protected" -f (Get-TkSelectionText $Report.Plan), $c.Remove, $c.Block, $c.Keep, $c.Unknown, $c.Protected)
    }
    if ($Paths) { Write-Host "  Report: $($Paths.Html)" -ForegroundColor Cyan }
    Write-Host ''
}

Export-ModuleMember -Function New-TkReport, Save-TkReport, ConvertTo-TkReportHtml, ConvertTo-TkCheckLabel, Write-TkReportSummary
