# GuiCore.psm1 - the window's logic without the window: app groups, the trimmed plan, the background runner, and the
# work each button starts. Kept apart from Gui.psm1 so it can be tested without showing anything.
Set-StrictMode -Version 2.0

$script:GroupTitles = [ordered]@{
    ai = 'AI apps (Copilot)'
    consumer = 'News, weather and other Microsoft extras'
    gaming = 'Xbox and games'
    promoted = 'Promoted third-party apps'
    retired = 'Retired Microsoft apps'
    everyday = 'Everyday tools'
    communication = 'Mail and chat'
    store = 'Microsoft Store'
    tools = 'Tools'
    newusers = 'For new users'
}

function Get-TkPlanGroups {
    # Every choice in the plan (ticked or not), grouped by catalog category in a fixed order: the window's tree.
    param([Parameter(Mandatory = $true)]$Plan)
    $choices = @($Plan.Items | Where-Object { $_.Choice })
    $extra = @($choices | ForEach-Object { [string]$_.Category } | Where-Object { -not $script:GroupTitles.Contains($_) } | Sort-Object -Unique)
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @(@($script:GroupTitles.Keys) + $extra)) {
        $items = @($choices | Where-Object { [string]$_.Category -eq $k } | Sort-Object @{ Expression = { $_.Choice -ne 'Remove' } }, Title)
        if (-not $items.Count) { continue }
        $title = 'Other catalog apps'; if ($script:GroupTitles.Contains($k)) { $title = $script:GroupTitles[$k] } elseif ($k) { $title = $k }
        [void]$out.Add([pscustomobject]@{ Key = $k; Title = $title; Items = $items; Selected = @($items | Where-Object { $_.Selected }).Count; Total = $items.Count })
    }
    return @($out)
}

function Get-TkChoiceText {
    # How one choice reads in the tree.
    param($Item)
    switch ($Item.Choice) {
        'Block' { return "$($Item.Title)  (not on this PC: blocked before it arrives)" }
        'Setting' { return "$($Item.Title)  (turned off; existing users keep theirs)" }
        default { return [string]$Item.Title }
    }
}

function New-TkSync {
    return [hashtable]::Synchronized(@{ Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Result = $null; Error = $null })
}

function Start-TkBackground {
    # Runs $Body (script text) in its own runspace with StillGood loaded, so the window never freezes.
    # Log lines stream into $Sync.Log; the result lands in $Sync.Result, or the error in $Sync.Error.
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Body, $Arguments, [Parameter(Mandatory = $true)][hashtable]$Sync)
    $Sync.Result = $null; $Sync.Error = $null
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $runner = {
        param($Root, $Body, $Arguments)
        try {
            . (Join-Path $Root 'modules\_load.ps1')
            Set-TkLogSink { param($line) $Sync.Log.Enqueue($line) }
            $Sync.Result = & ([scriptblock]::Create($Body)) $Arguments
        } catch { $Sync.Error = $_.Exception.Message }
    }
    [void]$ps.AddScript($runner.ToString()).AddArgument($Root).AddArgument($Body).AddArgument($Arguments)
    return [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
}

function Complete-TkBackground {
    param($Job)
    try { [void]$Job.PowerShell.EndInvoke($Job.Handle) } catch { }
    $Job.PowerShell.Dispose(); $Job.Runspace.Close(); $Job.Runspace.Dispose()
}

# The work behind each button, as script text for Start-TkBackground. Each returns one object.
$script:Bodies = @{
    Scan    = {
        param($a)
        $null = New-TkRun -Name 'window-report'
        Write-TkLog 'Checking this PC. Nothing is changed.'
        $inv = Get-TkInventory
        $ready = Get-TkWin11Readiness
        $cat = Get-TkCatalog
        $org = Get-TkOrganization -Path ([string]$a.Org) -Catalog $cat
        $plan = New-TkCleanPlan -Inventory $inv -Catalog $cat -Organization $org
        $speed = Get-TkSpeedReport -Inventory $inv -CleanCount $plan.Counts.Remove
        $rep = New-TkReport -Inventory $inv -Readiness $ready -Plan $plan -OneDrive @(Get-TkOneDriveUsers) -Speed $speed
        $paths = Save-TkReport -Report $rep -Dir (Get-TkRun).Dir
        Write-TkLog ('Checked: {0} {1} apps to remove, {2} to block, {3} protected. {4} ways to make it faster.' -f $ready.Summary, $plan.Counts.Remove, $plan.Counts.Block, $plan.Counts.Protected, @($speed.Findings).Count)
        [pscustomobject]@{ Os = $inv.Os; Elevated = $inv.Elevated; Readiness = $ready; Plan = $plan; Speed = $speed; Html = $paths.Html }
    }.ToString()
    Clean   = {
        param($a)
        $null = New-TkRun -Name 'window-clean-apps'
        Invoke-TkCleanApps -Plan $a.Plan -Apply
    }.ToString()
    Undo    = {
        param($a)
        $null = New-TkRun -Name 'window-undo'
        Invoke-TkUndo -UndoFile $a.File -Apply -Reinstall:([bool]$a.Reinstall)
    }.ToString()
    Upgrade = {
        param($a)
        $null = New-TkRun -Name 'window-upgrade'
        if ($a.CleanToo) {
            $res = Invoke-TkCleanApps -Plan $a.Plan -Apply
            Write-TkLog ('Clean apps: {0} removed, {1} blocked, {2} with errors.' -f $res.AppsRemoved, $res.Blocked, $res.Failed)
        }
        $null = Start-TkUpgrade -Config $a.Config -AllowUnsupported ([bool]$a.Unsupported) -NoRestart $false -CleanAfter ([bool]$a.CleanToo) -Include @($a.Plan.Include) -Exclude @($a.Plan.Exclude) -OrganizationPath ([string]$a.Org)
        Write-TkLog 'The upgrade is running in the background.'
        'started'
    }.ToString()
}

function Get-TkJobBody { param([ValidateSet('Scan', 'Clean', 'Undo', 'Upgrade')][string]$Name) return $script:Bodies[$Name] }

$script:StageNames = @{
    Queued = 'Starting'; Preparing = 'Getting ready'; Downloading = 'Downloading the image'; WaitingForImage = 'Waiting for the image'
    Verifying = 'Checking the image'; Scanning = 'Compatibility scan'; Upgrading = 'Windows Setup is upgrading'; Restarting = 'Restarting'
    WaitingForRestart = 'Waiting for you to restart'; Finishing = 'Finishing'; Done = 'Done'; Failed = 'Stopped'; RolledBack = 'Rolled back'
}
function Get-TkStageName { param([string]$Stage) if ($script:StageNames.ContainsKey($Stage)) { return $script:StageNames[$Stage] }; return $Stage }

Export-ModuleMember -Function *
