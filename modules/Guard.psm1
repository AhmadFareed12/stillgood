# Guard.psm1 - the safety rules, enforced in code. No catalog file, organization file or switch can turn them off.
# The organization file can only ADD protection.
Set-StrictMode -Version 2.0

# 1. Packages that are never removed, whatever a catalog says.
$script:Protected = @(
    # Runtimes and frameworks (any package flagged as a framework is protected too)
    'Microsoft.VCLibs.*', 'Microsoft.NET.*', 'Microsoft.UI.Xaml.*', 'Microsoft.WindowsAppRuntime*', 'MicrosoftCorporationII.WinAppRuntime*',
    'Microsoft.DirectXRuntime', 'Microsoft.Services.Store.Engagement', 'Microsoft.Advertising.Xaml', 'Microsoft.WidgetsPlatformRuntime',
    # The Windows shell, Start, Search, Settings, sign-in and setup
    'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.Search', 'windows.immersivecontrolpanel',
    'MicrosoftWindows.Client.CBS', 'MicrosoftWindows.Client.Core', 'MicrosoftWindows.Client.FileExp', 'MicrosoftWindows.Client.OOBE',
    'MicrosoftWindows.Client.AIX', 'MicrosoftWindows.Client.Photon', 'MicrosoftWindows.Client.LKG', 'MicrosoftWindows.Client.CoreAI',
    'MicrosoftWindows.UndockedDevKit', 'MicrosoftWindows.CrossDevice', 'Microsoft.Windows.CloudExperienceHost', 'Microsoft.Windows.OOBENetwork*',
    'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.CredDialogHost', 'Microsoft.BioEnrollment', 'Microsoft.LockApp',
    'Microsoft.Windows.AssignedAccessLockApp', 'Microsoft.Windows.ContentDeliveryManager', 'Microsoft.Windows.PeopleExperienceHost',
    'Microsoft.Windows.CapturePicker', 'Microsoft.Windows.PinningConfirmationDialog', 'Microsoft.Windows.PrintQueueActionCenter',
    'Microsoft.Windows.XGpuEjectDialog', 'Microsoft.Windows.NarratorQuickStart', 'Microsoft.Windows.SecureAssessmentBrowser',
    'Microsoft.Windows.ParentalControls', 'Microsoft.Windows.DevicesFlowHost', 'Microsoft.Win32WebViewHost', 'Microsoft.ECApp',
    'Microsoft.AsyncTextService', 'Microsoft.ApplicationCompatibilityEnhancements', 'NcsiUwpApp', 'Windows.PrintDialog', 'Windows.CBSPreview',
    '1527c705-839a-4832-9118-54d4Bd6a0c89', 'c5e2524a-ea46-4f67-841f-6a9465d9d515', 'E2A4F912-2574-4A75-9BB0-0D023378592B',
    'F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE',
    # Languages, handwriting, speech and accessibility
    'Microsoft.LanguageExperiencePack*', 'Microsoft.Ink.Handwriting.*', 'MicrosoftWindows.Speech.*', 'MicrosoftWindows.Narrator*',
    # More Windows parts: Start, the winget source, the app runtime installer, Sandbox, Edge and Office helpers
    'Microsoft.StartExperiencesApp', 'Microsoft.Winget.Source', 'Microsoft.WinAppRuntime.DDLM.*', 'MicrosoftWindows.WindowsSandbox',
    'Microsoft.Edge.*', 'Microsoft.Office.ActionsServer', 'Microsoft.OfficePushNotificationUtility',
    # Windows Security and SmartScreen
    'Microsoft.SecHealthUI', 'Microsoft.Windows.SecHealthUI', 'Microsoft.Windows.Apprep.ChxApp',
    # Edge and WebView2 (too much of Windows depends on them), App Installer (winget), Store purchases, OneDrive
    'Microsoft.MicrosoftEdge*', 'Microsoft.DesktopAppInstaller', 'Microsoft.StorePurchaseApp', 'Microsoft.OneDriveSync',
    # Codecs and media extensions
    'Microsoft.*ImageExtension', 'Microsoft.*VideoExtension', 'Microsoft.*VideoExtensions', 'Microsoft.WebMediaExtensions',
    'Microsoft.DolbyAudioExtensions',
    # Driver companion apps
    'RealtekSemiconductorCorp.*', 'AppUp.*', 'NVIDIACorp.*', 'AdvancedMicroDevicesInc*', 'WavesAudio.*', 'DolbyLaboratories.*',
    'SynapticsIncorporated.*', 'ElanMicroelectronicsCorp.*', '*Thunderbolt*', 'IntelCorp*'
)
$script:OrgKeep = New-Object System.Collections.ArrayList

# 2. The only registry places the toolkit may write. Everything else is refused.
$script:RegistryAllow = @(
    @{ Key = 'HKU\*\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
       Names = @('SilentInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'OemPreInstalledAppsEnabled',
                 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled') },
    @{ Key = 'HKU\*\Software\Microsoft\Windows\CurrentVersion\Run'; Names = @('OneDriveSetup') },
    @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Names = @('DisableWindowsConsumerFeatures') },
    @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\*'; Names = @() },
    @{ Key = 'HKLM\SYSTEM\Setup\MoSetup'; Names = @('AllowUpgradesWithUnsupportedTPMOrCPU') }
)
# 3. Security, update and licensing territory: refused even if a rule above were ever widened by mistake.
$script:RegistryDeny = @('*Windows Defender*', '*WindowsFirewall*', '*\SharedAccess*', '*WindowsUpdate*', '*\CurrentVersion\Policies\System*',
    '*\FVE*', '*BitLocker*', '*SoftwareProtectionPlatform*', '*\Control\Lsa*', '*SecurityHealth*', '*\DeviceGuard*')

function Test-TkProtected {
    # Returns why a package is protected, or $null when it may be removed.
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$IsFramework, [bool]$NonRemovable, [string]$SignatureKind)
    if ($IsFramework) { return 'a framework or runtime' }
    if ($NonRemovable) { return 'Windows marks it as non-removable' }
    if ($SignatureKind -eq 'System') { return 'part of Windows (a system component)' }
    foreach ($p in $script:Protected) { if (Test-TkLike $Name @($p)) { return "on the protected list ($p)" } }
    foreach ($p in $script:OrgKeep) { if (Test-TkLike $Name @($p)) { return "kept by your organization file ($p)" } }
    return $null
}

function Assert-TkRemovable {
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$IsFramework, [bool]$NonRemovable, [string]$SignatureKind)
    $why = Test-TkProtected -Name $Name -IsFramework $IsFramework -NonRemovable $NonRemovable -SignatureKind $SignatureKind
    if ($why) { throw "Refused: $Name is protected ($why)." }
}

function Add-TkKeepPatterns {
    # The organization file's "keep" list. It can only add protection, never remove it.
    param([string[]]$Patterns)
    foreach ($p in @($Patterns)) { if ($p -and -not $script:OrgKeep.Contains($p)) { [void]$script:OrgKeep.Add($p) } }
}

function Reset-TkKeepPatterns { $script:OrgKeep.Clear() }   # used by the tests between cases

function Get-TkProtectedList { return @($script:Protected) + @($script:OrgKeep) }

function ConvertTo-TkRegKey {
    # One spelling for every registry path: HKLM\... or HKU\...
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM' -replace '^HKEY_USERS', 'HKU' -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^(HKLM|HKU|HKCU):', '$1'
    return $p.TrimEnd('\')
}

function Assert-TkRegistryWrite {
    # Name empty = creating or deleting the key itself.
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Name = '')
    $key = ConvertTo-TkRegKey $Path
    foreach ($d in $script:RegistryDeny) {
        if (Test-TkLike $key @($d)) { throw "Refused: $key is security, update or licensing territory. This toolkit never writes there." }
    }
    $product = (Get-TkProduct).Name
    $allow = @($script:RegistryAllow) + @(@{ Key = "HKLM\SOFTWARE\$product"; Names = @('*') }, @{ Key = "HKLM\SOFTWARE\$product\*"; Names = @('*') })
    foreach ($a in $allow) {
        if (Test-TkLike $key @($a.Key)) {
            if (-not $Name) { return }
            if (Test-TkLike $Name $a.Names) { return }
        }
    }
    $shown = $key; if ($Name) { $shown = "$key\$Name" }
    throw "Refused: $shown is not on the toolkit's list of settings it may change."
}

Export-ModuleMember -Function *
