# Catalog.psm1 - loads the catalog and the organization file, and turns an inventory into a plan.
# Pure: nothing here changes the PC. The plan is what the preview shows and what Clean apps carries out.
Set-StrictMode -Version 2.0

function Get-TkCatalog {
    param([string]$Path)
    if (-not $Path) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\apps.json' }
    $c = Read-TkJson $Path
    $profiles = @($c.profiles.PSObject.Properties | ForEach-Object { $_.Name })
    $seen = @{}
    foreach ($a in @($c.apps)) {
        $name = [string](Get-TkProp $a 'name')
        if (-not $name) { throw "A catalog entry has no name ($Path)." }
        if ($name -match '[\*\?\[\]]') { throw "Catalog names are exact package names, without wildcards: $name" }
        if ($seen.ContainsKey($name)) { throw "The catalog lists $name twice." }
        $seen[$name] = $true
        foreach ($p in @(Get-TkProp $a 'remove')) { if ($p -and $profiles -notcontains $p) { throw "Catalog entry $name names an unknown profile '$p'." } }
    }
    return $c
}

function Get-TkProfileNames { param($Catalog) return @($Catalog.profiles.PSObject.Properties | ForEach-Object { $_.Name }) }

function Find-TkCatalogEntry {
    param($Catalog, [string]$Name)
    foreach ($a in @($Catalog.apps)) { if ($a.name -eq $Name) { return $a } }   # -eq is case-insensitive
    return $null
}

function Get-TkOrganization {
    # Optional organization.json: 'keep' (adds protection) and 'alsoRemove' (extra catalog apps per profile).
    param([string]$Path, $Catalog)
    if (-not $Path) { return [pscustomobject]@{ Keep = @(); AlsoRemove = @{} } }
    $o = Read-TkJson $Path
    $keep = @(@(Get-TkProp $o 'keep') | Where-Object { $_ })
    $also = @{}
    $ar = Get-TkProp $o 'alsoRemove'
    if ($ar) {
        $profiles = Get-TkProfileNames $Catalog
        foreach ($prop in $ar.PSObject.Properties) {
            if ($profiles -notcontains $prop.Name) { throw "Organization file: unknown profile '$($prop.Name)' under alsoRemove." }
            $names = @(@($prop.Value) | Where-Object { $_ })
            foreach ($n in $names) {
                if (-not (Find-TkCatalogEntry $Catalog $n)) { throw "Organization file: '$n' under alsoRemove is not in the catalog. Only catalog apps can be removed." }
            }
            $also[$prop.Name] = $names
        }
    }
    return [pscustomobject]@{ Keep = $keep; AlsoRemove = $also }
}

function Get-TkCleanSettings {
    # The settings Clean apps changes so the PC stays clean. Data only; Settings.psm1 applies them.
    param([string]$Profile)
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $list = @(
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'Windows stops installing suggested apps on its own.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'PreInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'Promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'PreInstalledAppsEverEnabled'; Value = 0; Kind = 'DWord'; Why = 'Promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'OemPreInstalledAppsEnabled'; Value = 0; Kind = 'DWord'; Why = 'The PC maker''s promoted apps are not added back.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 0; Kind = 'DWord'; Why = 'No app suggestions in Start.' },
        [pscustomobject]@{ Scope = 'Users'; Key = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0; Kind = 'DWord'; Why = 'No app suggestions in Start.' },
        [pscustomobject]@{ Scope = 'Machine'; Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1; Kind = 'DWord'; Why = 'The Windows policy against consumer app installs. Enterprise and Education honor it; Pro relies on the user settings above.' }
    )
    if ($Profile -eq 'kiosk') {
        $list += [pscustomobject]@{ Scope = 'NewUsers'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run'; Name = 'OneDriveSetup'; Value = $null; Kind = 'Delete'; Why = 'New users on this kiosk do not get OneDrive set up. Existing users are not touched.' }
    }
    return $list
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
    param([string]$Name, $Entry, [string]$Action, [string]$Reason, $Packages, $Prov)
    $title = $Name; $category = ''; $store = $null; $family = $null
    if ($Entry) {
        $t = Get-TkProp $Entry 'title'; if ($t) { $title = $t }
        $category = [string](Get-TkProp $Entry 'category'); $store = Get-TkProp $Entry 'storeId'; $family = Get-TkProp $Entry 'family'
    }
    $pk = @($Packages | Where-Object { $_ })
    if ($pk.Count -and -not $family) { $family = [string](Get-TkProp $pk[0] 'PackageFamilyName') }
    $users = @($pk | ForEach-Object { @(Get-TkProp $_ 'Users') } | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]@{
        Name = $Name; Title = $title; Category = $category; Action = $Action; Reason = $Reason
        Installed = [bool]$pk.Count; Users = $users; FullNames = @($pk | ForEach-Object { $_.PackageFullName })
        Provisioned = [bool]@($Prov).Count; ProvisionedNames = @(@($Prov) | Where-Object { $_ } | ForEach-Object { $_.PackageName })
        Family = $family; StoreId = $store; Restore = (Get-TkRestoreHint $Entry $Name)
    }
}

function New-TkCleanPlan {
    param([Parameter(Mandatory = $true)]$Inventory, [Parameter(Mandatory = $true)]$Catalog, [Parameter(Mandatory = $true)][string]$Profile, $Organization)
    if ((Get-TkProfileNames $Catalog) -notcontains $Profile) { throw "Unknown profile '$Profile'. Use one of: $((Get-TkProfileNames $Catalog) -join ', ')." }
    if (-not $Organization) { $Organization = [pscustomobject]@{ Keep = @(); AlsoRemove = @{} } }
    Add-TkKeepPatterns -Patterns @($Organization.Keep)
    $also = @(); if ($Organization.AlsoRemove.ContainsKey($Profile)) { $also = @($Organization.AlsoRemove[$Profile]) }

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
        $note = [string](Get-TkProp $entry 'note')
        if (@($entry.remove) -contains $Profile -or $also -contains $n) {
            [void]$items.Add((New-TkPlanItem $n $entry 'Remove' ("The $Profile profile removes it. $note").Trim() $pk $pv))
        } else {
            [void]$items.Add((New-TkPlanItem $n $entry 'Keep' ("The $Profile profile keeps it. $note").Trim() $pk $pv))
        }
    }
    # Apps that are not here yet but would arrive with an upgrade or a feature update: block them ahead of time.
    foreach ($a in @($Catalog.apps)) {
        if (-not (Get-TkProp $a 'ahead')) { continue }
        if ($names -contains $a.name) { continue }
        if (-not (@($a.remove) -contains $Profile -or $also -contains $a.name)) { continue }
        if (Test-TkProtected -Name $a.name) { continue }
        [void]$items.Add((New-TkPlanItem $a.name $a 'Block' 'Not on this PC. Blocked so an upgrade or a feature update does not add it.' @() @()))
    }

    $order = @{ Remove = 0; Block = 1; Keep = 2; Unknown = 3; Protected = 4 }
    $sorted = @($items | Sort-Object @{ Expression = { $order[$_.Action] } }, Title)
    $count = { param($a) @($sorted | Where-Object { $_.Action -eq $a }).Count }
    return [pscustomobject]@{
        Kind = 'CleanAppsPlan'; Created = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME
        Profile = $Profile; ProfileText = [string](Get-TkProp $Catalog.profiles $Profile); CatalogVersion = [string]$Catalog.version
        OrganizationKeep = @($Organization.Keep)
        Items = $sorted
        Settings = @(Get-TkCleanSettings -Profile $Profile)
        Counts = [pscustomobject]@{ Remove = (& $count 'Remove'); Block = (& $count 'Block'); Keep = (& $count 'Keep'); Unknown = (& $count 'Unknown'); Protected = (& $count 'Protected') }
    }
}

Export-ModuleMember -Function *
