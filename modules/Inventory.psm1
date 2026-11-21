# Inventory.psm1 - READ-ONLY. What is installed: apps (all users), apps provisioned for new users, desktop programs,
# startup items. Nothing here changes the PC.
Set-StrictMode -Version 2.0

function Get-TkAppxInventory {
    param([switch]$AllUsers)
    if ($AllUsers) { $pkgs = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) }
    else { $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    foreach ($p in $pkgs) {
        $users = @()
        $info = Get-TkProp $p 'PackageUserInformation'
        if ($AllUsers -and $info) {
            $users = @($info | ForEach-Object { '{0}={1}' -f $_.UserSecurityId.Username, $_.InstallState })
        }
        [pscustomobject]@{
            Name              = $p.Name
            PackageFullName   = $p.PackageFullName
            PackageFamilyName = $p.PackageFamilyName
            Publisher         = $p.Publisher
            Version           = [string]$p.Version
            IsFramework       = [bool](Get-TkProp $p 'IsFramework')
            NonRemovable      = [bool](Get-TkProp $p 'NonRemovable')
            SignatureKind     = [string](Get-TkProp $p 'SignatureKind')
            Users             = $users
        }
    }
}

function Get-TkProvisionedInventory {
    # Needs administrator rights; returns nothing without them.
    try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { return @() }
    foreach ($p in $prov) {
        [pscustomobject]@{ DisplayName = $p.DisplayName; PackageName = $p.PackageName; Version = [string]$p.Version }
    }
}

function Get-TkDesktopPrograms {
    $roots = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine (32-bit)' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'CurrentUser' }
    )
    foreach ($r in $roots) {
        foreach ($e in @(Get-ItemProperty -Path $r.Path -ErrorAction SilentlyContinue)) {
            $name = Get-TkProp $e 'DisplayName'
            if (-not $name) { continue }
            if ((Get-TkProp $e 'SystemComponent') -eq 1) { continue }
            [pscustomobject]@{
                DisplayName          = $name
                Publisher            = Get-TkProp $e 'Publisher'
                Version              = Get-TkProp $e 'DisplayVersion'
                UninstallString      = Get-TkProp $e 'UninstallString'
                QuietUninstallString = Get-TkProp $e 'QuietUninstallString'
                Scope                = $r.Scope
            }
        }
    }
}

function Get-TkStartupItems {
    return @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
}

function Get-TkInventory {
    $elevated = Test-TkElevated
    $appx = @(Get-TkAppxInventory -AllUsers:$elevated)
    $prov = @()
    if ($elevated) { $prov = @(Get-TkProvisionedInventory) }
    $prog = @(Get-TkDesktopPrograms)
    $startup = @(Get-TkStartupItems)
    return [pscustomobject]@{
        Collected   = (Get-Date).ToString('s')
        Elevated    = $elevated
        Os          = Get-TkOsInfo
        Appx        = $appx
        Provisioned = $prov
        Programs    = $prog
        Startup     = $startup
        Summary     = [pscustomobject]@{ Apps = $appx.Count; ProvisionedForNewUsers = $prov.Count; DesktopPrograms = $prog.Count; StartupItems = $startup.Count }
    }
}

Export-ModuleMember -Function *
