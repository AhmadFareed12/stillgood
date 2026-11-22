# Run-Tests.ps1 - offline tests. Nothing here touches the real PC: every system call goes to the fake PC in Harness.ps1,
# and test mode makes any real system call fail loudly.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
$ErrorActionPreference = 'Stop'
$env:TK_TEST_MODE = '1'
$env:TK_QUIET = '1'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'modules\_load.ps1')
. (Join-Path $PSScriptRoot 'Harness.ps1')
Reset-TkTestData
$null = New-TkRun -Name 'tests'
$catalog = Get-TkCatalog -Path (Join-Path $root 'catalog\apps.json')
$tmp = Join-Path (Get-TkDataRoot) 'tmp'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-StandardPc {
    # A typical office PC: two users (one signed in), inbox apps, a framework, a system app and the company's own app.
    $profiles = @([pscustomobject]@{ Sid = 'S-1-5-21-1-1001'; Path = 'C:\Users\ana' }, [pscustomobject]@{ Sid = 'S-1-5-21-1-1002'; Path = 'C:\Users\ben' })
    $appx = @(
        (New-FakePkg 'Microsoft.BingNews'), (New-FakePkg 'Microsoft.WindowsCalculator'), (New-FakePkg 'Microsoft.WindowsStore'),
        (New-FakePkg 'MSTeams'), (New-FakePkg 'Microsoft.GamingApp'), (New-FakePkg 'Microsoft.VCLibs.140.00' -Framework),
        (New-FakePkg 'Microsoft.Windows.ShellExperienceHost' -Sig 'System'), (New-FakePkg 'Contoso.Kiosk' -Family 'Contoso.Kiosk_abc123')
    )
    $prov = @((New-FakeProv 'Microsoft.BingNews'), (New-FakeProv 'Clipchamp.Clipchamp'), (New-FakeProv 'Microsoft.WindowsCalculator'))
    Install-FakeSystem -Appx $appx -Prov $prov -Profiles $profiles -Loaded @('S-1-5-21-1-1001')
    return (New-FakeInventory -Appx $appx -Prov $prov)
}

function Get-PlanItem { param($Plan, [string]$Name) $i = @($Plan.Items | Where-Object { $_.Name -eq $Name }); if ($i.Count -ne 1) { throw "the plan has $($i.Count) items named $Name" }; return $i[0] }

function New-TestJob {
    param([bool]$AllowUnsupported = $false, [bool]$CleanAfter = $false)
    $paths = Get-TkUpgradePaths
    if (Test-Path -LiteralPath $paths.Root) { Remove-Item -LiteralPath $paths.Root -Recurse -Force }
    New-Item -ItemType Directory -Path $paths.Download -Force | Out-Null
    $b = New-Object byte[] 8192; (New-Object Random 4).NextBytes($b)
    $src = Join-Path $tmp 'source.iso'; [IO.File]::WriteAllBytes($src, $b)
    $cfg = [pscustomobject]@{ Source = $src; Sha256 = (Get-TkSha256 -Path $src); DynamicUpdate = $true; StallMinutes = 1; DropFolderWaitHours = 1 }
    $global:Fake.Download = { param($Source, $Destination, $OnProgress) Copy-Item -LiteralPath $Source -Destination $Destination -Force; & $OnProgress 8192 8192; [pscustomobject]@{ Ok = $true; Stalled = $false; Error = '' } }
    $global:Fake.Files['X:\setup.exe'] = $true
    $job = [pscustomobject]@{ Created = (Get-Date).ToString('s'); StartBuild = 19045; Config = $cfg; AllowUnsupported = $AllowUnsupported; NoRestart = $false; CleanAfter = $CleanAfter; Profile = 'office'; Organization = $null; AppDir = $root }
    Save-TkJson $job $paths.Job
    return $paths
}

Write-Host ''; Write-Host 'Safety rules' -ForegroundColor Cyan
It 'protects frameworks, non-removable and system packages' {
    Should-BeTrue (Test-TkProtected -Name 'Anything' -IsFramework $true) 'framework'
    Should-BeTrue (Test-TkProtected -Name 'Anything' -NonRemovable $true) 'non-removable'
    Should-BeTrue (Test-TkProtected -Name 'Anything' -SignatureKind 'System') 'system component'
}
It 'protects the shell, App Installer, Edge, Windows Security, codecs, OneDrive and driver apps by name' {
    foreach ($n in 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.DesktopAppInstaller', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.SecHealthUI',
        'Microsoft.HEVCVideoExtension', 'Microsoft.VP9VideoExtensions', 'Microsoft.OneDriveSync', 'RealtekSemiconductorCorp.RealtekAudioControl', 'AppUp.IntelGraphicsExperience',
        'Microsoft.LanguageExperiencePackhe-IL', 'MicrosoftWindows.Speech.en-US.1', 'Microsoft.StartExperiencesApp') {
        Should-BeTrue (Test-TkProtected -Name $n) $n
    }
}
It 'lets catalog apps through' { Should-Be (Test-TkProtected -Name 'Microsoft.BingNews') $null 'News' }
It 'adds the organization''s keep list' { Reset-TkKeepPatterns; Add-TkKeepPatterns 'Contoso.*'; Should-BeTrue (Test-TkProtected -Name 'Contoso.Kiosk') 'kept'; Reset-TkKeepPatterns }
It 'allows only the listed registry settings' {
    Assert-TkRegistryWrite -Path 'HKU\S-1-5-21-1-1001\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled'
    Assert-TkRegistryWrite -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\X_8wekyb3d8bbwe'
    Assert-TkRegistryWrite -Path 'HKLM:\SYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKU\S-1-5-21-1-1001\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' } '*not on the toolkit*'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' } '*not on the toolkit*'
}
It 'refuses security, update and licensing settings' {
    Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' } '*security*'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableLUA' } '*security*'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' } '*security*'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\Policies\Microsoft\FVE' -Name 'UseTPM' } '*security*'
    Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform' -Name 'KeyManagementServiceName' } '*security*'
}
It 'blocks every real system call in test mode' {
    Reset-TkSystemAdapter
    Should-Throw { Invoke-TkSys 'RemoveAppx' @('Microsoft.BingNews_1_x64__8wekyb3d8bbwe') } 'Test mode*'
    Should-Throw { Invoke-TkSys 'RegSet' @('HKLM\SOFTWARE\StillGood', 'x', 1, 'DWord') } 'Test mode*'
    Should-Throw { Invoke-TkSys 'RunExe' @('cmd.exe', @('/c', 'echo'), 5) } 'Test mode*'
}

Write-Host ''; Write-Host 'Windows 11 readiness' -ForegroundColor Cyan
It 'reads processor names, and says Unknown rather than guess' {
    $cases = [ordered]@{
        'Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz' = 'Pass'; 'Intel(R) Core(TM) i7-7700 CPU @ 3.60GHz' = 'Fail'; 'Intel(R) Core(TM) i3-1115G4 @ 3.00GHz' = 'Pass'
        'Intel(R) Core(TM) i9-14900K' = 'Pass'; 'Intel(R) Core(TM) i7 CPU         920  @ 2.67GHz' = 'Fail'; 'Intel(R) Core(TM)2 Duo CPU E8400 @ 3.00GHz' = 'Fail'
        'AMD Ryzen 5 3600 6-Core Processor' = 'Pass'; 'AMD Ryzen 7 1700 Eight-Core Processor' = 'Fail'; 'AMD Ryzen 5 2600 Six-Core Processor' = 'Unknown'
        'AMD Ryzen AI 9 HX 370 w/ Radeon 890M' = 'Pass'; 'Intel(R) Core(TM) Ultra 7 155H' = 'Pass'; 'Intel(R) Core(TM) 5 120U' = 'Pass'
        'Intel(R) Celeron(R) N4020 CPU @ 1.10GHz' = 'Unknown'; 'AMD Ryzen 5 PRO 4650G with Radeon Graphics' = 'Pass'
    }
    foreach ($k in $cases.Keys) { Should-Be (Get-TkCpuSupport -Name $k).Status $cases[$k] $k }
}
It 'turns the checks into one honest verdict' {
    $all = @((New-TkCheck 'A' 'x' 'x' 'Pass' $true ''), (New-TkCheck 'B' 'x' 'x' 'Pass' $false ''))
    $tpm = New-TkCheck 'TPM' '2.0' 'none' 'Fail' $true ''
    $sse = New-TkCheck 'SSE4.2' 'present' 'missing' 'Fail' $false ''
    $space = New-TkCheck 'Free space' '30 GB' '9 GB' 'Fail' $false '' $true
    $unk = New-TkCheck 'Secure Boot' 'UEFI' 'not readable' 'Unknown' $true ''
    Should-Be (Get-TkVerdict -Checks $all).Verdict 'Supported' 'all pass'
    Should-Be (Get-TkVerdict -Checks ($all + $tpm)).Verdict 'UnsupportedButUpgradeable' 'TPM'
    Should-Be (Get-TkVerdict -Checks ($all + $sse)).Verdict 'NotUpgradeable' 'SSE4.2'
    Should-Be (Get-TkVerdict -Checks ($all + $space)).Verdict 'FixFirst' 'disk space'
    Should-Be (Get-TkVerdict -Checks ($all + $unk)).Verdict 'ProbablySupported' 'unknown'
    Should-Be (Get-TkVerdict -Checks ($all + $sse + $space)).Verdict 'NotUpgradeable' 'blocker beats fixable'
}

Write-Host ''; Write-Host 'Catalog and plans' -ForegroundColor Cyan
It 'loads the shipped catalog' { Should-BeTrue (@($catalog.apps).Count -gt 40) 'catalog size'; Should-BeTrue ((Get-TkProfileNames $catalog) -contains 'kiosk') 'kiosk profile' }
It 'rejects catalogs with wildcards or duplicates' {
    $bad = Join-Path $tmp 'bad.json'
    Set-Content -LiteralPath $bad -Value '{"version":"1","profiles":{"office":"x"},"apps":[{"name":"Microsoft.*","title":"x","remove":["office"]}]}'
    Should-Throw { Get-TkCatalog -Path $bad } '*wildcards*'
    Set-Content -LiteralPath $bad -Value '{"version":"1","profiles":{"office":"x"},"apps":[{"name":"A","title":"x","remove":["office"]},{"name":"a","title":"y","remove":[]}]}'
    Should-Throw { Get-TkCatalog -Path $bad } '*twice*'
}
It 'plans an office PC' {
    Reset-TkKeepPatterns
    $plan = New-TkCleanPlan -Inventory (New-StandardPc) -Catalog $catalog -Profile 'office'
    Should-Be (Get-PlanItem $plan 'Microsoft.BingNews').Action 'Remove' 'News'
    Should-Be (Get-PlanItem $plan 'Microsoft.WindowsCalculator').Action 'Keep' 'Calculator'
    Should-Be (Get-PlanItem $plan 'Microsoft.WindowsStore').Action 'Keep' 'Store'
    Should-Be (Get-PlanItem $plan 'MSTeams').Action 'Keep' 'Teams'
    Should-Be (Get-PlanItem $plan 'Contoso.Kiosk').Action 'Unknown' 'company app'
    Should-Be (Get-PlanItem $plan 'Microsoft.VCLibs.140.00').Action 'Protected' 'framework'
    Should-Be (Get-PlanItem $plan 'Microsoft.Windows.ShellExperienceHost').Action 'Protected' 'shell'
    $clip = Get-PlanItem $plan 'Clipchamp.Clipchamp'
    Should-Be $clip.Action 'Remove' 'Clipchamp'; Should-BeTrue $clip.Provisioned 'set up for new users'; Should-BeFalse $clip.Installed 'installed'
    Should-Be (Get-PlanItem $plan 'Microsoft.Copilot').Action 'Block' 'Copilot ahead'
    Should-BeFalse (@($plan.Settings | Where-Object { $_.Name -eq 'OneDriveSetup' }).Count) 'office keeps OneDrive for new users'
}
It 'plans a kiosk PC' {
    $plan = New-TkCleanPlan -Inventory (New-StandardPc) -Catalog $catalog -Profile 'kiosk'
    foreach ($n in 'Microsoft.WindowsCalculator', 'Microsoft.WindowsStore', 'MSTeams', 'Microsoft.BingNews') { Should-Be (Get-PlanItem $plan $n).Action 'Remove' $n }
    Should-Be (Get-PlanItem $plan 'Microsoft.OutlookForWindows').Action 'Block' 'Outlook ahead'
    Should-BeTrue (@($plan.Settings | Where-Object { $_.Name -eq 'OneDriveSetup' -and $_.Scope -eq 'NewUsers' }).Count) 'no OneDrive setup for new kiosk users'
}
It 'applies the organization file' {
    $org = Join-Path $tmp 'org.json'
    Set-Content -LiteralPath $org -Value '{"keep":["Microsoft.WindowsCalculator"],"alsoRemove":{"office":["Microsoft.OutlookForWindows"]}}'
    $o = Get-TkOrganization -Path $org -Catalog $catalog
    $inv = New-StandardPc
    Should-Be (Get-PlanItem (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'kiosk' -Organization $o) 'Microsoft.WindowsCalculator').Action 'Protected' 'kept by the organization'
    Should-Be (Get-PlanItem (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office' -Organization $o) 'Microsoft.OutlookForWindows').Action 'Block' 'extra removal'
    Set-Content -LiteralPath $org -Value '{"alsoRemove":{"office":["Contoso.Kiosk"]}}'
    Should-Throw { Get-TkOrganization -Path $org -Catalog $catalog } '*not in the catalog*'
    Reset-TkKeepPatterns
}
It 'lets the safety rules overrule a catalog' {
    $c = Join-Path $tmp 'cat.json'
    Set-Content -LiteralPath $c -Value '{"version":"1","profiles":{"office":"x"},"apps":[{"name":"Microsoft.DesktopAppInstaller","title":"App Installer","remove":["office"]}]}'
    $plan = New-TkCleanPlan -Inventory (New-FakeInventory -Appx @((New-FakePkg 'Microsoft.DesktopAppInstaller'))) -Catalog (Get-TkCatalog -Path $c) -Profile 'office'
    Should-Be (Get-PlanItem $plan 'Microsoft.DesktopAppInstaller').Action 'Protected' 'App Installer'
}

Write-Host ''; Write-Host 'Clean apps' -ForegroundColor Cyan
It 'cleans an office PC for every user and for new users' {
    Reset-TkKeepPatterns
    $inv = New-StandardPc
    $script:FirstPlan = New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office'
    $res = Invoke-TkCleanApps -Plan $script:FirstPlan -Apply
    Should-BeTrue (Test-Called 'RemoveAppx Microsoft.BingNews_*') 'News removed'
    Should-BeTrue (Test-Called 'RemoveProvisioned Microsoft.BingNews_*') 'News removed for new users'
    Should-BeTrue (Test-Called 'RemoveProvisioned Clipchamp.Clipchamp_*') 'Clipchamp removed for new users'
    Should-BeTrue (Test-Called 'RemoveAppx Microsoft.GamingApp_*') 'Xbox removed'
    Should-BeFalse (Test-Called 'RemoveAppx Microsoft.WindowsCalculator*') 'Calculator kept'
    Should-BeFalse (Test-Called 'RemoveProvisioned Microsoft.WindowsCalculator*') 'Calculator kept for new users'
    Should-BeFalse (Test-Called 'RemoveAppx Contoso*') 'company app kept'
    Should-BeTrue (Test-Called 'RegCreateKey *DEPROVISIONED\MICROSOFT.COPILOT_8WEKYB3D8BBWE') 'Copilot blocked ahead'
    Should-BeTrue (Test-Called 'RegCreateKey *DEPROVISIONED\MICROSOFT.BINGNEWS_8WEKYB3D8BBWE') 'News blocked from coming back'
    Should-BeTrue (Test-Called 'HiveLoad HKU\TK_S-1-5-21-1-1002') 'signed-out profile opened'
    Should-BeTrue (Test-Called 'HiveUnload HKU\TK_S-1-5-21-1-1002') 'and closed'
    Should-BeTrue (Test-Called 'HiveLoad HKU\TK_Default') 'default profile opened'
    Should-BeFalse (Test-Called 'HiveLoad HKU\S-1-5-21-1-1001') 'signed-in profile used where it is'
    Should-BeTrue (Test-Called 'RegSet HKU\S-1-5-21-1-1001\*SilentInstalledAppsEnabled=0') 'signed-in user set'
    Should-Be @($global:Fake.Loaded).Count 1 'open profiles afterwards'
    Should-Be $res.Failed 0 'errors'; Should-Be @($res.StillPresent).Count 0 'left over'
    Should-BeTrue (Test-Path -LiteralPath $res.UndoFile) 'undo file'
}
It 'runs again safely: nothing new to do, nothing new to undo' {
    $global:Fake.Calls.Clear()
    $res = Invoke-TkCleanApps -Plan $script:FirstPlan -Apply
    Should-BeFalse (Test-Called 'RemoveAppx*') 'no removals'
    Should-BeFalse (Test-Called 'RegSet*') 'settings already right'
    Should-BeFalse (Test-Called 'RegCreateKey*') 'blocks already there'
    Should-BeTrue ($res.AlreadyGone -gt 0) 'already-gone apps counted'
    Should-Be @(@((Read-TkJson $res.UndoFile).Registry) | Where-Object { $_ }).Count 0 'undo records'
}
It 'keeps going when one removal fails, and says so' {
    $inv = New-StandardPc
    $global:Fake.FailRemove = @('Microsoft.GamingApp_1.0.0.0_x64__8wekyb3d8bbwe')
    $res = Invoke-TkCleanApps -Plan (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office') -Apply
    Should-Be $res.Failed 1 'items with errors'
    Should-BeTrue (@($res.StillPresent) -contains 'Microsoft.GamingApp') 'Xbox reported as still present'
    Should-BeTrue (Test-Called 'RemoveAppx Microsoft.BingNews_*') 'the rest still ran'
}
It 'does not count it as an error when Windows already removed the new-user copy (24H2 and later)' {
    $inv = New-StandardPc
    $global:Fake.AllUsersRemovesProvisioned = $true
    $res = Invoke-TkCleanApps -Plan (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office') -Apply
    Should-Be $res.Failed 0 'items with errors'
    Should-BeFalse (Test-Called 'RemoveProvisioned Microsoft.BingNews_*') 'no second removal for an app already gone'
    Should-BeTrue (Test-Called 'RemoveProvisioned Clipchamp.Clipchamp_*') 'apps only set up for new users are still removed'
    Should-Be @($res.StillPresent).Count 0 'left over'
}
It 'refuses a forged plan at the last moment' {
    Install-FakeSystem -Appx @((New-FakePkg 'Microsoft.DesktopAppInstaller'), (New-FakePkg 'Microsoft.BingNews' -NonRemovable))
    $forged = [pscustomobject]@{ Profile = 'office'; Settings = @(); Items = @(
            [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; Title = 'App Installer'; Action = 'Remove'; Family = $null; Restore = '' },
            [pscustomobject]@{ Name = 'Microsoft.BingNews'; Title = 'News'; Action = 'Remove'; Family = $null; Restore = '' }) }
    $res = Invoke-TkCleanApps -Plan $forged -Apply
    Should-BeFalse (Test-Called 'RemoveAppx*') 'nothing removed'
    Should-Be $res.Failed 2 'both refused'
}
It 'changes nothing without -Apply' { Should-Throw { Invoke-TkCleanApps -Plan ([pscustomobject]@{ Profile = 'office'; Items = @(); Settings = @() }) } '*without -Apply*' }
It 'undoes a run: settings back, blocks lifted, apps listed for reinstall' {
    $inv = New-StandardPc
    $cdm = 'HKU\S-1-5-21-1-1001\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $global:Fake.Reg[(Get-FakeKey $cdm)] = @{ SilentInstalledAppsEnabled = @{ Value = 1; Kind = 'DWord' } }
    $res = Invoke-TkCleanApps -Plan (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office') -Apply
    Should-Be (Invoke-TkSys 'RegGet' @($cdm, 'SilentInstalledAppsEnabled')).Value 0 'changed by the run'
    Should-BeTrue ((Invoke-TkUndo -UndoFile $res.UndoFile).Settings -gt 0) 'preview counts settings'
    $u = Invoke-TkUndo -UndoFile $res.UndoFile -Apply
    Should-Be (Invoke-TkSys 'RegGet' @($cdm, 'SilentInstalledAppsEnabled')).Value 1 'old value back'
    Should-BeFalse (Invoke-TkSys 'RegGet' @($cdm, 'SystemPaneSuggestionsEnabled')).Exists 'new value removed again'
    Should-BeFalse (Invoke-TkSys 'RegKeyExists' @('HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Copilot_8wekyb3d8bbwe')) 'block lifted'
    Should-BeTrue (@($u.ToReinstall | Where-Object { $_.Name -eq 'Microsoft.BingNews' }).Count) 'News listed to reinstall'
    Should-Be $u.Failed 0 'undo errors'
}
It 'reinstalls from the Store when asked' {
    $inv = New-StandardPc
    $res = Invoke-TkCleanApps -Plan (New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office') -Apply
    $u = Invoke-TkUndo -UndoFile $res.UndoFile -Apply -Reinstall
    Should-BeTrue (Test-Called 'RunExe winget.exe install --source msstore --id 9WZDNCRFHVFW*') 'winget for News'
    Should-BeTrue ($u.Reinstalled -gt 0) 'reinstalled'
}

Write-Host ''; Write-Host 'Report' -ForegroundColor Cyan
It 'writes an HTML report that escapes what it shows' {
    $inv = New-FakeInventory -Appx @((New-FakePkg 'Microsoft.BingNews')) -Programs @([pscustomobject]@{ DisplayName = '<script>alert(1)</script>'; Publisher = 'X'; Version = '1' })
    $plan = New-TkCleanPlan -Inventory $inv -Catalog $catalog -Profile 'office'
    $checks = @((New-TkCheck 'TPM' '2.0' 'none' 'Fail' $true 'n'), (New-TkCheck 'Memory' '4 GB' '8 GB' 'Pass' $false 'n'))
    $v = Get-TkVerdict -Checks $checks
    $ready = [pscustomobject]@{ Verdict = $v.Verdict; Summary = $v.Summary; Blockers = $v.Blockers; Fixable = $v.Fixable; Bypassable = $v.Bypassable; Unknown = $v.Unknown; Checks = $checks }
    $rep = New-TkReport -Inventory $inv -Readiness $ready -Plan $plan -OneDrive @([pscustomobject]@{ Sid = 'S'; Profile = 'ana'; State = 'Uses'; Folders = @('OneDrive') })
    $paths = Save-TkReport -Report $rep -Dir $tmp
    $html = Get-Content -LiteralPath $paths.Html -Raw
    Should-BeTrue ($html -like '*Windows 11 readiness*') 'readiness section'
    Should-BeTrue ($html -like '*Clean apps preview: office profile*') 'plan section'
    Should-BeTrue ($html -like '*&lt;script&gt;alert(1)&lt;/script&gt;*') 'escaped'
    Should-BeFalse ($html -like '*<script>alert*') 'no raw script'
    Should-BeTrue (Test-Path -LiteralPath $paths.Json) 'JSON written'
}

Write-Host ''; Write-Host 'Upgrade' -ForegroundColor Cyan
It 'builds the Setup command line' {
    $scan = Get-TkSetupArguments -Mode Scan -LogDir 'C:\L'
    Should-BeTrue (($scan -join ' ') -like '*/compat scanonly /noreboot*') 'scan only'
    Should-BeFalse ($scan -contains '/product') 'no hardware option unless chosen'
    $up = Get-TkSetupArguments -Mode Upgrade -AllowUnsupported $true -DynamicUpdate $false
    Should-BeTrue (($up -join ' ') -like '*/compat ignorewarning*') 'upgrade'
    Should-BeFalse ($up -contains '/noreboot') 'restarts on its own by default'
    Should-BeTrue (($up -join ' ') -like '*/dynamicupdate disable*') 'dynamic update off'
    Should-BeTrue (($up -join ' ') -like '*/product server') 'hardware option'
    Should-BeTrue ((Get-TkSetupArguments -Mode Upgrade -NoRestart $true) -contains '/noreboot') 'no restart when asked'
}
It 'reads Setup exit codes' {
    Should-Be (Resolve-TkSetupExitCode -Code -1047526896 -Mode Scan).Result 'Compatible' '0xC1900210'
    Should-Be (Resolve-TkSetupExitCode -Code -1047526904 -Mode Scan).Result 'AppBlock' '0xC1900208'
    Should-Be (Resolve-TkSetupExitCode -Code -1047526912 -Mode Scan).Result 'HardwareBlock' '0xC1900200'
    Should-Be (Resolve-TkSetupExitCode -Code -1047526898 -Mode Scan).Result 'DiskSpace' '0xC190020E'
    Should-Be (Resolve-TkSetupExitCode -Code 0 -Mode Upgrade).Result 'Success' 'zero'
    Should-Be (Resolve-TkSetupExitCode -Code 5 -Mode Upgrade).Code '0x00000005' 'other'
}
It 'estimates time left only from measurements' {
    Should-Be (Get-TkEta 100 1000 2).EtaSec $null 'too early'
    $e = Get-TkEta 500 1000 10
    Should-Be $e.Percent 50 'percent'; Should-Be $e.EtaSec 10 'seconds left'
    Should-Be (Get-TkEta 500 0 10).Percent $null 'unknown size'
}
It 'hashes files exactly like Get-FileHash' {
    $f = Join-Path $tmp 'blob.bin'; $b = New-Object byte[] 300000; (New-Object Random 7).NextBytes($b); [IO.File]::WriteAllBytes($f, $b)
    Should-Be (Get-TkSha256 -Path $f) (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash 'SHA-256'
}
It 'checks the upgrade settings file' {
    $c = Join-Path $tmp 'up.json'
    Set-Content -LiteralPath $c -Value '{"source":"\\\\srv\\w11.iso","sha256":"abc"}'
    Should-Throw { Get-TkUpgradeConfig -Path $c } '*SHA-256*'
    Set-Content -LiteralPath $c -Value ('{"source":"\\\\srv\\w11.iso","sha256":"' + ('a' * 64) + '"}')
    $cfg = Get-TkUpgradeConfig -Path $c
    Should-Be $cfg.Images[0].Sha256 ('A' * 64) 'upper case'; Should-Be $cfg.Images[0].Culture '*' 'single image offered to any language'; Should-Be $cfg.StallMinutes 10 'default stall time'
}
It 'picks the upgrade image in the PC''s own Windows language' {
    $c = Join-Path $tmp 'up-lang.json'
    Set-Content -LiteralPath $c -Value ('{"images":{"en-US":{"source":"\\\\s\\en.iso","sha256":"' + ('A' * 64) + '"},"he-IL":{"source":"\\\\s\\he.iso","sha256":"' + ('B' * 64) + '"},"ar-SA":{"source":"\\\\s\\ar.iso","sha256":"' + ('C' * 64) + '"}}}')
    $cfg = Get-TkUpgradeConfig -Path $c
    $he = Resolve-TkUpgradeImage -Config $cfg -Culture 'he-IL'
    Should-Be $he.Source '\\s\he.iso' 'Hebrew PC'; Should-Be $he.Sha256 ('B' * 64) 'Hebrew checksum'; Should-Be $he.LanguageName 'Hebrew' 'named like Microsoft does'
    Should-Be (Resolve-TkUpgradeImage -Config $cfg -Culture 'ar-EG').Source '\\s\ar.iso' 'same base language, one image'
    Should-Throw { Resolve-TkUpgradeImage -Config $cfg -Culture 'en-GB' } "*'English International' image*"
    Should-Throw { Resolve-TkUpgradeImage -Config $cfg -Culture 'fr-FR' } "*'French' image*"
    Set-Content -LiteralPath $c -Value ('{"source":"\\\\s\\w.iso","sha256":"' + ('D' * 64) + '"}')
    $any = Resolve-TkUpgradeImage -Config (Get-TkUpgradeConfig -Path $c) -Culture 'de-DE'
    Should-Be $any.Source '\\s\w.iso' 'older single-image settings still work'; Should-BeTrue $any.AnyLanguage 'and say the language is not stated'
}
It 'names every Microsoft image language, and falls back to Windows'' own name' {
    Should-Be (Get-TkLanguageName 'pt-BR') 'Brazilian Portuguese' 'pt-BR'
    Should-Be (Get-TkLanguageName 'sr-Latn-RS') 'Serbian Latin' 'sr-Latn-RS'
    Should-Be (Get-TkLanguageName 'zh-TW') 'Chinese (Traditional)' 'zh-TW'
    Should-Be (Get-TkLanguageName 'cy-GB') 'Welsh (United Kingdom)' 'a language Microsoft has no image for'
    Should-Be @((Read-TkJson (Join-Path $root 'catalog\languages.json')).languages.PSObject.Properties).Count 38 'all 38 image languages listed'
}
It 'gives the same answers under Turkish, Thai, Saudi and Persian region settings' {
    $year = [string](Get-Date).Year
    foreach ($c in 'tr-TR', 'th-TH', 'ar-SA', 'fa-IR') {
        Use-Culture $c {
            Should-Be (Get-TkStamp).Substring(0, 4) $year "Gregorian file stamps in $c"
            Should-BeTrue (Test-TkProtected -Name 'MICROSOFT.WINDOWS.SHELLEXPERIENCEHOST') "protected list matches in $c"
            Should-BeTrue (Test-TkProtected -Name 'APPUP.INTELGRAPHICSEXPERIENCE') "driver apps protected in $c"
            Should-Throw { Assert-TkRegistryWrite -Path 'HKLM\SOFTWARE\POLICIES\MICROSOFT\WINDOWS DEFENDER' -Name 'DisableAntiSpyware' } '*security*'
            Assert-TkRegistryWrite -Path 'HKU\S-1-5-21-1-1001\SOFTWARE\MICROSOFT\WINDOWS\CURRENTVERSION\CONTENTDELIVERYMANAGER' -Name 'SILENTINSTALLEDAPPSENABLED'
            $plan = New-TkCleanPlan -Inventory (New-FakeInventory -Appx @((New-FakePkg 'MICROSOFT.WINDOWSCALCULATOR'))) -Catalog $catalog -Profile 'kiosk'
            Should-Be (Get-PlanItem $plan 'MICROSOFT.WINDOWSCALCULATOR').Action 'Remove' "catalog match in $c"
            Should-Be (Get-TkCpuSupport -Name 'INTEL(R) CORE(TM) I5-8250U CPU @ 1.60GHZ').Status 'Pass' "processor read in $c"
        }
    }
}
It 'takes a dropped image only once it matches and has stopped growing' {
    $drop = Join-Path $tmp 'drop'; New-Item -ItemType Directory -Path $drop -Force | Out-Null
    $good = Join-Path $drop 'win11.iso'; $bad = Join-Path $drop 'other.iso'
    $g = New-Object byte[] 4096; (New-Object Random 1).NextBytes($g); [IO.File]::WriteAllBytes($good, $g)
    $x = New-Object byte[] 4096; (New-Object Random 2).NextBytes($x); [IO.File]::WriteAllBytes($bad, $x)
    $sha = Get-TkSha256 -Path $good; $seen = @{}
    Should-Be (Find-TkDroppedImage -Folder $drop -Sha256 $sha -Seen $seen) $null 'first pass only notes the files'
    Should-Be (Find-TkDroppedImage -Folder $drop -Sha256 $sha -Seen $seen) $good 'second pass finds the match'
}
It 'falls back to the guided drop folder when the download stalls' {
    Install-FakeSystem
    $paths = Get-TkUpgradePaths
    if (Test-Path -LiteralPath $paths.Root) { Remove-Item -LiteralPath $paths.Root -Recurse -Force }
    New-Item -ItemType Directory -Path $paths.Drop -Force | Out-Null
    $img = Join-Path $paths.Drop 'Win11.iso'; $b = New-Object byte[] 8192; (New-Object Random 3).NextBytes($b); [IO.File]::WriteAllBytes($img, $b)
    $cfg = [pscustomobject]@{ Source = 'https://example.invalid/w11.iso'; Sha256 = (Get-TkSha256 -Path $img); DynamicUpdate = $true; StallMinutes = 1; DropFolderWaitHours = 1 }
    Should-Be (Get-TkImage -Config $cfg) $img 'image from the drop folder'
    Should-BeTrue (Test-Path -LiteralPath (Join-Path $paths.Drop 'READ ME.txt')) 'instructions written'
    Should-Be (Read-TkUpgradeState).Stage 'WaitingForImage' 'the monitor shows the wait'
}
It 'runs the upgrade job: verified image, scan, then Setup' {
    Install-FakeSystem
    $paths = New-TestJob -AllowUnsupported $true
    [void]$global:Fake.ExitCodes.Add(-1047526896); [void]$global:Fake.ExitCodes.Add(0)
    Should-Be (Invoke-TkUpgradeJob -JobPath $paths.Job) 'Restarting' 'result'
    Should-BeTrue (Test-Called 'RunExe X:\setup.exe /auto upgrade /quiet /eula accept /compat scanonly*') 'scan first'
    Should-BeTrue (Test-Called 'RunExe X:\setup.exe *ignorewarning*/product server') 'then the upgrade, with the hardware option'
    Should-BeTrue (Test-Called 'RegisterTask AfterUpgrade Logon') 'after-upgrade check scheduled'
    Should-BeTrue (Test-Called 'RegSet HKLM\SYSTEM\SETUP\MOSETUP\AllowUpgradesWithUnsupportedTPMOrCPU=1') 'hardware option value'
    Should-BeTrue (Test-Called 'DismountIso*') 'image unmounted'
    Should-Be (Read-TkUpgradeState).Stage 'Restarting' 'state'
}
It 'stops before Setup when the scan finds a blocker' {
    Install-FakeSystem
    $paths = New-TestJob
    [void]$global:Fake.ExitCodes.Add(-1047526904)
    Should-Be (Invoke-TkUpgradeJob -JobPath $paths.Job) 'Failed' 'result'
    Should-Be @($global:Fake.Calls | Where-Object { $_ -like 'RunExe*' }).Count 1 'Setup runs'
    Should-BeFalse (Test-Called 'RegisterTask*') 'nothing scheduled'
    Should-BeTrue ((Read-TkUpgradeState).Message -like '*blocks the upgrade*') 'the reason is shown'
}
It 'refuses an image that does not match the pinned SHA-256' {
    Install-FakeSystem
    $paths = New-TestJob
    $job = Read-TkJson $paths.Job; $job.Config.Sha256 = ('0' * 64); $job.Config.DropFolderWaitHours = 0.01; Save-TkJson $job $paths.Job
    Should-Be (Invoke-TkUpgradeJob -JobPath $paths.Job) 'Failed' 'result'
    Should-BeFalse (Test-Called 'MountIso*') 'never mounted'
    Should-BeFalse (Test-Path -LiteralPath (Join-Path $paths.Download 'windows11.iso')) 'bad download deleted'
}
It 'finishes after the first sign-in on the new build' {
    Install-FakeSystem -Appx @((New-FakePkg 'Microsoft.Copilot'))
    $paths = New-TestJob -AllowUnsupported $true -CleanAfter $true
    $global:Fake.Reg[(Get-FakeKey 'HKLM\SYSTEM\Setup\MoSetup')] = @{ AllowUpgradesWithUnsupportedTPMOrCPU = @{ Value = 1; Kind = 'DWord' } }
    Write-TkUpgradeState 'Restarting' 'test'
    Copy-Item -LiteralPath (Join-Path $tmp 'source.iso') -Destination (Join-Path $paths.Download 'windows11.iso')
    $global:Fake.Os = New-FakeOs -Build 26200
    Should-Be (Invoke-TkAfterUpgrade -JobPath $paths.Job) 'Done' 'result'
    Should-BeFalse (Test-Path -LiteralPath $paths.Download) 'image removed'
    Should-BeTrue (Test-Called 'RemoveAppx Microsoft.Copilot_*') 'clean apps ran on Windows 11'
    Should-BeTrue (Test-Called 'UnregisterTask AfterUpgrade') 'the check removed itself'
    Should-BeTrue (Test-Called 'RegDeleteValue HKLM\SYSTEM\SETUP\MOSETUP\AllowUpgradesWithUnsupportedTPMOrCPU') 'hardware option value removed'
    Should-Be (Read-TkUpgradeState).Stage 'Done' 'state'
}
It 'notices a rollback and keeps the image for another try' {
    Install-FakeSystem
    $paths = New-TestJob
    Write-TkUpgradeState 'Restarting' 'test'
    $global:Fake.LastBoot = (Get-Date).AddMinutes(5)
    Should-Be (Invoke-TkAfterUpgrade -JobPath $paths.Job) 'RolledBack' 'result'
    Should-BeTrue (Test-Path -LiteralPath $paths.Job) 'job kept'
}
It 'waits while Setup is still working' {
    Install-FakeSystem
    $paths = New-TestJob
    Write-TkUpgradeState 'Upgrading' 'test'
    $global:Fake.LastBoot = (Get-Date).AddDays(-1)
    Should-Be (Invoke-TkAfterUpgrade -JobPath $paths.Job) 'InProgress' 'result'
}
It 'hands the upgrade to a background task, once' {
    Install-FakeSystem
    $paths = Get-TkUpgradePaths
    if (Test-Path -LiteralPath $paths.Root) { Remove-Item -LiteralPath $paths.Root -Recurse -Force }
    $cfg = [pscustomobject]@{ Source = 'C:\x.iso'; Sha256 = ('A' * 64); DynamicUpdate = $true; StallMinutes = 10; DropFolderWaitHours = 24 }
    $null = Start-TkUpgrade -Config $cfg -AllowUnsupported $false -NoRestart $false -CleanAfter $false
    Should-BeTrue (Test-Called 'RegisterTask Upgrade Now') 'task started'
    $job = Read-TkJson $paths.Job
    Should-Be $job.StartBuild 19045 'start build recorded'
    Should-BeTrue (Test-Path -LiteralPath (Join-Path $job.AppDir 'worker\Upgrade-Worker.ps1')) 'runs from a local copy'
    Should-Throw { Start-TkUpgrade -Config $cfg } '*already in progress*'
}

Write-Host ''; Write-Host 'The window' -ForegroundColor Cyan
Import-Module (Join-Path $root 'modules\GuiCore.psm1') -Force -DisableNameChecking -Global
It 'groups the plan for the window, and an unticked group is kept' {
    Reset-TkKeepPatterns
    $plan = New-TkCleanPlan -Inventory (New-StandardPc) -Catalog $catalog -Profile 'office'
    $groups = @(Get-TkPlanGroups -Plan $plan)
    Should-BeTrue (@($groups | Where-Object { $_.Key -eq 'gaming' }).Count) 'an Xbox and games group'
    Should-BeTrue (@($groups | Where-Object { $_.Key -eq 'ai' -and $_.Block -ge 1 }).Count) 'Copilot shows as blocked ahead'
    $trim = Select-TkPlanGroups -Plan $plan -Unticked @('gaming')
    Should-Be (Get-PlanItem $trim 'Microsoft.GamingApp').Action 'Keep' 'unticked group kept'
    Should-Be (Get-PlanItem $trim 'Microsoft.BingNews').Action 'Remove' 'other groups still removed'
    Should-Be (Get-PlanItem $plan 'Microsoft.GamingApp').Action 'Remove' 'the original plan is untouched'
    Should-Be $trim.Counts.Remove ($plan.Counts.Remove - 1) 'counts follow the trim'
}
It 'runs work in the background and streams its log' {
    $sync = New-TkSync
    $job = Start-TkBackground -Root $root -Body { param($a) Write-TkLog "hello $($a.Name)"; 40 + 2 }.ToString() -Arguments @{ Name = 'window' } -Sync $sync
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $job.Handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Complete-TkBackground $job
    Should-Be $sync.Error $null 'no error'
    Should-Be $sync.Result 42 'result'
    $lines = @(); $l = $null; while ($sync.Log.TryDequeue([ref]$l)) { $lines += $l }
    Should-BeTrue (@($lines | Where-Object { $_ -like '*hello window*' }).Count) 'log line streamed'
}
It 'loads the window module without opening anything' {
    Import-Module (Join-Path $root 'modules\Gui.psm1') -Force -DisableNameChecking -Global
    Should-BeTrue ([bool](Get-Command Show-TkWindow -ErrorAction SilentlyContinue)) 'Show-TkWindow'
    Should-Be (Get-TkStageName 'WaitingForImage') 'Waiting for the image' 'stage names for the monitor'
}

Write-Host ''; Write-Host 'Source files' -ForegroundColor Cyan
It 'keeps every script ASCII-only (Windows PowerShell 5.1 reads files without a BOM as ANSI)' {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { @('.ps1', '.psm1', '.json') -contains $_.Extension })) {
        $n = @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 }).Count
        Should-Be $n 0 $f.Name
    }
}
It 'parses every script without errors' {
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1' })) {
        $errs = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        Should-Be @($errs).Count 0 "$($f.Name): $(@($errs) -join '; ')"
    }
}

Reset-TkSystemAdapter
$failed = @($global:TkResults | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ('{0} tests: {1} passed, {2} failed' -f $global:TkResults.Count, ($global:TkResults.Count - $failed.Count), $failed.Count)
if ($failed.Count) { exit 1 }
exit 0
