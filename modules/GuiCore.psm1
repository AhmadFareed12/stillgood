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
}

function Get-TkPlanGroups {
    # The plan's removals and blocks, grouped by catalog category, in a fixed order.
    param([Parameter(Mandatory = $true)]$Plan)
    $acts = @($Plan.Items | Where-Object { $_.Action -eq 'Remove' -or $_.Action -eq 'Block' })
    $extra = @($acts | ForEach-Object { [string]$_.Category } | Where-Object { -not $script:GroupTitles.Contains($_) } | Sort-Object -Unique)
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @(@($script:GroupTitles.Keys) + $extra)) {
        $items = @($acts | Where-Object { [string]$_.Category -eq $k })
        if (-not $items.Count) { continue }
        $title = 'Other catalog apps'; if ($script:GroupTitles.Contains($k)) { $title = $script:GroupTitles[$k] } elseif ($k) { $title = $k }
        [void]$out.Add([pscustomobject]@{
            Key = $k; Title = $title; Items = $items
            Remove = @($items | Where-Object { $_.Action -eq 'Remove' }).Count; Block = @($items | Where-Object { $_.Action -eq 'Block' }).Count
        })
    }
    return @($out)
}

function Select-TkPlanGroups {
    # A copy of the plan where the unticked groups are kept instead of removed. The original plan is not changed.
    param([Parameter(Mandatory = $true)]$Plan, [string[]]$Unticked = @())
    $items = @(foreach ($i in @($Plan.Items)) {
        $c = $i.PSObject.Copy()
        if (($c.Action -eq 'Remove' -or $c.Action -eq 'Block') -and @($Unticked) -contains [string]$c.Category) {
            $c.Action = 'Keep'; $c.Reason = 'Kept: its group was unticked in the window.'
        }
        $c
    })
    $copy = $Plan.PSObject.Copy()
    $copy.Items = $items
    $n = { param($a) @($items | Where-Object { $_.Action -eq $a }).Count }
    $copy.Counts = [pscustomobject]@{ Remove = (& $n 'Remove'); Block = (& $n 'Block'); Keep = (& $n 'Keep'); Unknown = (& $n 'Unknown'); Protected = (& $n 'Protected') }
    return $copy
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
        $null = New-TkRun -Name "window-report-$($a.Profile)"
        Write-TkLog 'Checking this PC. Nothing is changed.'
        $inv = Get-TkInventory
        $ready = Get-TkWin11Readiness
        $cat = Get-TkCatalog
        $org = Get-TkOrganization -Path ([string]$a.Org) -Catalog $cat
        $plan = New-TkCleanPlan -Inventory $inv -Catalog $cat -Profile $a.Profile -Organization $org
        $rep = New-TkReport -Inventory $inv -Readiness $ready -Plan $plan -OneDrive @(Get-TkOneDriveUsers)
        $paths = Save-TkReport -Report $rep -Dir (Get-TkRun).Dir
        Write-TkLog ('Checked: {0} {1} apps to remove, {2} to block, {3} protected.' -f $ready.Summary, $plan.Counts.Remove, $plan.Counts.Block, $plan.Counts.Protected)
        [pscustomobject]@{ Os = $inv.Os; Elevated = $inv.Elevated; Readiness = $ready; Plan = $plan; Html = $paths.Html }
    }.ToString()
    Clean   = {
        param($a)
        $null = New-TkRun -Name "window-clean-apps-$($a.Plan.Profile)"
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
        $null = Start-TkUpgrade -Config $a.Config -AllowUnsupported ([bool]$a.Unsupported) -NoRestart $false -CleanAfter ([bool]$a.CleanToo) -Profile $a.Profile -OrganizationPath ([string]$a.Org)
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
