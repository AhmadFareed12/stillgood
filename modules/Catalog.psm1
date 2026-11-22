# Catalog.psm1 - loads the catalog and the organization file, and turns an inventory into a plan.
# Pure: nothing here changes the PC. The plan is what the preview shows and what Clean apps carries out.
#
# Every app StillGood may remove is a choice with its own tick. The catalog says which start ticked ('remove':
# 'default') and which start unticked ('optional': everyday tools, mail and chat, the Store - tick them for a kiosk or
# a till). -Include and -Exclude change the ticks by app, by group or 'all'; the window's tree does the same per app.
Set-StrictMode -Version 2.0

$script:RemoveValues = @('default', 'optional', 'never')
$script:NewUsersOneDrive = 'NewUsers.OneDriveSetup'
$script:EdgePreload = 'Startup.EdgePreload'
$script:OneDriveSignIn = 'Startup.OneDriveSignIn'
# The choices that are settings, not apps. Only what the lab measured as a real gain that cannot break an app:
# Edge preloading itself at sign-in (82 MB on a used Windows 11 PC) and OneDrive starting at sign-in for people who
# don't use it (10 seconds of boot on an old Windows 11 PC). Services, telemetry and the usual tweaks were measured
# too and left out: small or no gain, or a risk to other apps.
$script:SettingChoices = @(
    [pscustomobject]@{ name = $script:EdgePreload; title = 'Edge preloading itself at sign-in'; category = 'startup'; hint = 'Edge still opens normally'; on = $true; restore = 'Undo puts it back.' },
    [pscustomobject]@{ name = $script:OneDriveSignIn; title = 'OneDrive starting at sign-in, for people who do not use it'; category = 'startup'; hint = 'nothing is removed'; on = $true; restore = 'Undo puts it back.' },
    [pscustomobject]@{ name = $script:NewUsersOneDrive; title = 'OneDrive set-up for new users'; category = 'newusers'; hint = 'turned off; existing users keep theirs'; on = $false; restore = 'Undo puts it back.' }
)

function Get-TkCatalog {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\apps.json' }
    $c = Read-TkJson $Path
    $seen = @{}
    foreach ($a in @($c.apps)) {
        $name = [string](Get-TkProp $a 'name')
        if (-not $name) { throw "A catalog entry has no name ($Path)." }
        if ($name -match '[\*\?\[\]]') { throw "Catalog names are exact package names, without wildcards: $name" }
        if ($seen.ContainsKey($name)) { throw "The catalog lists $name twice." }
        $seen[$name] = $true
        $r = Get-TkProp $a 'remove'
        if ($null -ne $r -and ($r -isnot [string] -or $script:RemoveValues -notcontains $r)) { throw "Catalog entry $name`: 'remove' must be default, optional or never." }
    }
    return $c
}

function Find-TkCatalogEntry {
    param($Catalog, [string]$Name)
    foreach ($a in @($Catalog.apps)) { if ($a.name -eq $Name) { return $a } }   # -eq is case-insensitive
    return $null
}

function Get-TkRemoveDefault {
    # 'default' (starts ticked), 'optional' (offered, starts unticked) or 'never'.
    param($Entry)
    $r = [string](Get-TkProp $Entry 'remove'); if (-not $r) { return 'never' }
    return $r
}

function Get-TkGroupKeys {
    # The groups the window shows and -Include/-Exclude accept: the catalog's categories, plus newusers.
    param($Catalog)
    return @(@(@($Catalog.apps) | ForEach-Object { [string](Get-TkProp $_ 'category') }) + @($script:SettingChoices | ForEach-Object { $_.category }) | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TkOrganization {
    # Optional organization.json: 'keep' (adds protection) and 'alsoRemove' (catalog apps that start ticked here).
    param([string]$Path, $Catalog)
    if (-not $Path) { return [pscustomobject]@{ Keep = @(); AlsoRemove = @() } }
    $o = Read-TkJson $Path
    $keep = @(@(Get-TkProp $o 'keep') | Where-Object { $_ })
    $ar = Get-TkProp $o 'alsoRemove'
    if ($ar -and -not ($ar -is [array] -or $ar -is [string])) { throw "Organization file: 'alsoRemove' is one list of catalog apps that start ticked on every PC (it is no longer split by office and kiosk)." }
    $also = @(@($ar) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    foreach ($n in $also) {
        if (-not (Find-TkCatalogEntry $Catalog $n)) { throw "Organization file: '$n' under alsoRemove is not in the catalog. Only catalog apps can be removed." }
    }
    return [pscustomobject]@{ Keep = $keep; AlsoRemove = $also }
}

function Get-TkCleanSettings {
    # The settings Clean apps always changes so the PC stays clean. Data only; Settings.psm1 applies them.
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    return @(
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'Windows stops installing suggested apps on its own.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'PreInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'Promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'PreInstalledAppsEverEnabled'; Value = 0; Kind = 'DWord'; Why = 'Promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'OemPreInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'The PC maker''s promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 0; Kind = 'DWord'; Why = 'No app suggestions in Start.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0; Kind = 'DWord'; Why = 'No app suggestions in Start.' },
        [pscustomobject]@{ Scope = 'Machine'; Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Kind = 'DWord'; Why = 'The Windows policy against consumer app installs. Enterprise and Education honor it; Pro relies on the user settings above.' }
    )
}

function Get-TkChoiceSettings {
    # The settings behind the ticked setting choices. Each one is undone by Undo.
    param([string[]]$Selected = @())
    $out = @()
    if (@($Selected) -contains $script:EdgePreload) {
        $edge = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'
        $out += [pscustomobject]@{ Scope = 'Machine'; Key = $edge; Name = 'StartupBoostEnabled'; Value = 0; Kind = 'DWord'; Why = 'Edge no longer loads itself at sign-in (startup boost). It still opens normally, a moment slower the first time.' }
        $out += [pscustomobject]@{ Scope = 'Machine'; Key = $edge; Name = 'BackgroundModeEnabled'; Value = 0; Kind = 'DWord'; Why = 'Nothing of Edge keeps running after it is closed.' }
    }
    if (@($Selected) -contains $script:OneDriveSignIn) {
        # Marked off the way Task Manager's Startup apps does it; OneDrive itself is not touched. Only for people who do
        # not use OneDrive: no files in it and not signed in (see Invoke-TkApplySettings). Everyone else keeps it starting.
        $out += [pscustomobject]@{ Scope = 'Users'; Condition = 'NoOneDrive'; Key = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Name = 'OneDrive'; Value = ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); Kind = 'Binary'; Why = 'OneDrive does not start at sign-in for people who do not use it. Nothing is removed; Task Manager''s Startup apps can turn it back on.' }
    }
    if (@($Selected) -contains $script:NewUsersOneDrive) {
        $out += [pscustomobject]@{ Scope = 'NewUsers'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'OneDriveSetup'; Value = $null; Kind = 'Delete'; Why = 'New users on this PC do not get OneDrive set up. Existing users are not touched.' }
    }
    return $out
}

function Get-TkRestoreHint {
    param($Entry, [string]$Name)
    if ($Entry) {
        $r = Get-TkProp $Entry 'restore'; if ($r) { return $r }
        $id = Get-TkProp $Entry 'storeId'; if ($id) { return "winget install --source msstore --id $id --accept-package-agreements --accept-source-agreements" }
        $t = Get-TkProp $Entry 'title'; if (-not $t) { $t = $Name }
        return "Reinstall '$t' from the Microsoft Store."
    }
    return "Reinstall '$Name' from where it came from."
}

function New-TkPlanItem {
    param([string]$Name, $Entry, [string]$Action, [string]$Reason, $Packages, $Prov, [string]$Choice = '', [bool]$DefaultOn = $false)
    $title = $Name; $category = ''; $store = $null; $family = $null; $note = ''; $hint = ''
    if ($Entry) {
        $t = Get-TkProp $Entry 'title'; if ($t) { $title = $t }
        $category = [string](Get-TkProp $Entry 'category'); $store = Get-TkProp $Entry 'storeId'; $family = Get-TkProp $Entry 'family'
        $note = [string](Get-TkProp $Entry 'note'); $hint = [string](Get-TkProp $Entry 'hint')
    }
    $pk = @($Packages | Where-Object { $_ })
    if ($pk.Count -and -not $family) { $family = [string](Get-TkProp $pk[0] 'PackageFamilyName') }
    $users = @($pk | ForEach-Object { @(Get-TkProp $_ 'Users') } | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]@{
        Name = $Name; Title = $title; Category = $category; Action = $Action; Reason = $Reason; Note = $note; Hint = $hint
        Choice = $Choice; DefaultOn = $DefaultOn; Selected = $false
        Installed = [bool]$pk.Count; Users = $users; FullNames = @($pk | ForEach-Object { $_.PackageFullName })
        Provisioned = [bool]@($Prov).Count; ProvisionedNames = @(@($Prov) | Where-Object { $_ } | ForEach-Object { $_.PackageName })
        Family = $family; StoreId = $store; Restore = (Get-TkRestoreHint $Entry $Name)
    }
}

function Split-TkList {
    # "a,b" and @('a', 'b') both work (powershell.exe -File passes a list as one string).
    param([string[]]$Value)
    return @(@($Value) | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-TkSelection {
    # Which choices are ticked: the defaults, then -Include, then -Exclude. An entry is an app's package name, a group
    # (such as everyday or communication) or 'all'. An unknown entry is an error, so a typo in a script cannot pass silently.
    param([object[]]$Choices = @(), [string[]]$Include = @(), [string[]]$Exclude = @(), $Catalog)
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($Catalog.apps)) { [void]$known.Add([string]$a.name) }
    foreach ($g in @(Get-TkGroupKeys $Catalog)) { [void]$known.Add($g) }
    foreach ($c in $script:SettingChoices) { [void]$known.Add($c.name) }
    [void]$known.Add('all')
    foreach ($e in @(@($Include) + @($Exclude) | Where-Object { $_ })) {
        if (-not $known.Contains($e)) { throw "'$e' is not an app or a group StillGood knows. Groups: $((Get-TkGroupKeys $Catalog) -join ', '), or all. Apps: their package names, as the report shows them." }
    }
    $hit = {
        param($c, $list)
        foreach ($e in @($list)) {
            foreach ($v in @('all', [string]$c.Name, [string]$c.Category)) { if ($v -and [string]::Equals($e, $v, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        }
        return $false
    }
    $sel = New-Object System.Collections.ArrayList
    foreach ($c in @($Choices)) {
        $on = [bool]$c.DefaultOn
        if (& $hit $c $Include) { $on = $true }
        if (& $hit $c $Exclude) { $on = $false }
        if ($on) { [void]$sel.Add([string]$c.Name) }
    }
    return @($sel)
}

function Complete-TkPlan {
    # Applies a selection to the plan's choices, then fills in the actions, the order, the counts and the settings.
    param([object[]]$Items, [string[]]$Selected = @(), $From)
    foreach ($i in @($Items)) {
        if (-not $i.Choice) { continue }
        $on = @($Selected) -contains $i.Name
        $i.Selected = $on
        switch ($i.Choice) {
            'Remove' { if ($on) { $i.Action = 'Remove'; $i.Reason = ("Ticked, so it is removed. " + $i.Note).Trim() } else { $i.Action = 'Keep'; $i.Reason = ("Not ticked, so it is kept. " + $i.Note).Trim() } }
            'Block' { if ($on) { $i.Action = 'Block'; $i.Reason = 'Not on this PC. Blocked so an upgrade or a feature update does not add it.' } else { $i.Action = 'Skip'; $i.Reason = 'Not on this PC, and not blocked.' } }
            'Setting' { if ($on) { $i.Action = 'Setting'; $i.Reason = ("Ticked: " + $i.Title + " is turned off (" + $i.Hint + ").") } else { $i.Action = 'Skip'; $i.Reason = 'Not ticked.' } }
        }
    }
    $order = @{ Remove = 0; Block = 1; Setting = 2; Keep = 3; Unknown = 4; Protected = 5; Skip = 6 }
    $sorted = @($Items | Sort-Object @{ Expression = { $order[$_.Action] } }, Title)
    $count = { param($a) @($sorted | Where-Object { $_.Action -eq $a }).Count }
    return [pscustomobject]@{
        Kind = 'CleanAppsPlan'; Created = $From.Created; Computer = $From.Computer; CatalogVersion = $From.CatalogVersion
        Include = @($From.Include); Exclude = @($From.Exclude); OrganizationKeep = @($From.OrganizationKeep)
        Items = $sorted
        Settings = @(@(Get-TkCleanSettings) + @(Get-TkChoiceSettings -Selected $Selected))
        Counts = [pscustomobject]@{ Remove = (& $count 'Remove'); Block = (& $count 'Block'); Keep = (& $count 'Keep'); Unknown = (& $count 'Unknown'); Protected = (& $count 'Protected') }
    }
}

function New-TkCleanPlan {
    param([Parameter(Mandatory = $true)]$Inventory, [Parameter(Mandatory = $true)]$Catalog, $Organization, [string[]]$Include = @(), [string[]]$Exclude = @())
    if (-not $Organization) { $Organization = [pscustomobject]@{ Keep = @(); AlsoRemove = @() } }
    Add-TkKeepPatterns -Patterns @($Organization.Keep)
    $also = @($Organization.AlsoRemove)
    $Include = Split-TkList $Include; $Exclude = Split-TkList $Exclude

    $appx = @(@($Inventory.Appx) | Where-Object { $_ })
    $prov = @(@($Inventory.Provisioned) | Where-Object { $_ })
    $names = @(@($appx | ForEach-Object { $_.Name }) + @($prov | ForEach-Object { $_.DisplayName }) | Where-Object { $_ } | Sort-Object -Unique)

    $items = New-Object System.Collections.ArrayList
    foreach ($n in $names) {
        $pk = @($appx | Where-Object { $_.Name -eq $n })
        $pv = @($prov | Where-Object { $_.DisplayName -eq $n })
        $entry = Find-TkCatalogEntry $Catalog $n
        $fw = [bool](@($pk | Where-Object { Get-TkProp $_ 'IsFramework' }).Count)
        $nr = [bool](@($pk | Where-Object { Get-TkProp $_ 'NonRemovable' }).Count)
        $sig = ''; if (@($pk | Where-Object { (Get-TkProp $_ 'SignatureKind') -eq 'System' }).Count) { $sig = 'System' }
        $why = Test-TkProtected -Name $n -IsFramework $fw -NonRemovable $nr -SignatureKind $sig
        if ($why) { [void]$items.Add((New-TkPlanItem $n $entry 'Protected' "Protected: $why." $pk $pv)); continue }
        if (-not $entry) { [void]$items.Add((New-TkPlanItem $n $null 'Unknown' 'Not in the catalog, so it is kept.' $pk $pv)); continue }
        $rd = Get-TkRemoveDefault $entry
        if ($rd -eq 'never' -and $also -notcontains $n) {
            [void]$items.Add((New-TkPlanItem $n $entry 'Keep' ("Known, and never removed. " + [string](Get-TkProp $entry 'note')).Trim() $pk $pv))
            continue
        }
        [void]$items.Add((New-TkPlanItem $n $entry 'Keep' '' $pk $pv -Choice 'Remove' -DefaultOn ($rd -eq 'default' -or $also -contains $n)))
    }
    # Apps that are not here yet but would arrive with an upgrade or a feature update: they can be blocked ahead of time.
    foreach ($a in @($Catalog.apps)) {
        if (-not (Get-TkProp $a 'ahead')) { continue }
        if ($names -contains $a.name) { continue }
        $rd = Get-TkRemoveDefault $a
        if ($rd -eq 'never' -and $also -notcontains $a.name) { continue }
        if (Test-TkProtected -Name $a.name) { continue }
        [void]$items.Add((New-TkPlanItem $a.name $a 'Skip' '' @() @() -Choice 'Block' -DefaultOn ($rd -eq 'default' -or $also -contains $a.name)))
    }
    # The settings, offered like apps (see $script:SettingChoices).
    foreach ($c in $script:SettingChoices) { [void]$items.Add((New-TkPlanItem $c.name $c 'Skip' '' @() @() -Choice 'Setting' -DefaultOn ([bool]$c.on))) }

    $meta = [pscustomobject]@{ Created = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME; CatalogVersion = [string]$Catalog.version; Include = $Include; Exclude = $Exclude; OrganizationKeep = @($Organization.Keep) }
    $selected = Resolve-TkSelection -Choices @($items | Where-Object { $_.Choice }) -Include $Include -Exclude $Exclude -Catalog $Catalog
    return (Complete-TkPlan -Items @($items) -Selected $selected -From $meta)
}

function Select-TkPlanItems {
    # A copy of the plan with exactly these choices ticked (the window's tree). The original plan is not changed.
    # Its Include and Exclude become the difference from the defaults, so an upgrade's clean-up on the new Windows
    # makes the same choices, and apps that arrive with it follow the defaults.
    param([Parameter(Mandatory = $true)]$Plan, [string[]]$Selected = @())
    $items = @(foreach ($i in @($Plan.Items)) { $i.PSObject.Copy() })
    $from = [pscustomobject]@{
        Created = $Plan.Created; Computer = $Plan.Computer; CatalogVersion = $Plan.CatalogVersion; OrganizationKeep = @($Plan.OrganizationKeep)
        Include = @($items | Where-Object { $_.Choice -and -not $_.DefaultOn -and @($Selected) -contains $_.Name } | ForEach-Object { $_.Name })
        Exclude = @($items | Where-Object { $_.Choice -and $_.DefaultOn -and @($Selected) -notcontains $_.Name } | ForEach-Object { $_.Name })
    }
    return (Complete-TkPlan -Items $items -Selected $Selected -From $from)
}

function Get-TkSelectionText {
    # One line for reports and logs: what differs from the defaults.
    param($Plan)
    $inc = @(Get-TkProp $Plan 'Include' | Where-Object { $_ }); $exc = @(Get-TkProp $Plan 'Exclude' | Where-Object { $_ })
    if (-not $inc.Count -and -not $exc.Count) { return 'the defaults' }
    $t = 'the defaults'
    if ($inc.Count) { $t += ', plus ' + ($inc -join ', ') }
    if ($exc.Count) { $t += ', minus ' + ($exc -join ', ') }
    return $t
}

Export-ModuleMember -Function *
