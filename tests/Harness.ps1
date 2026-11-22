# Harness.ps1 - a tiny test runner and a fake PC. Dot-sourced by Run-Tests.ps1.
# The fake PC stands in for every adapter in System.psm1, so the tests never touch the real machine.
Set-StrictMode -Version 2.0

$global:TkResults = New-Object System.Collections.ArrayList

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        [void]$global:TkResults.Add([pscustomobject]@{ Name = $Name; Ok = $true; Error = '' })
        Write-Host "  ok    $Name" -ForegroundColor Green
    } catch {
        $where = ''; if ($_.InvocationInfo) { $where = " (line $($_.InvocationInfo.ScriptLineNumber))" }
        [void]$global:TkResults.Add([pscustomobject]@{ Name = $Name; Ok = $false; Error = "$($_.Exception.Message)$where" })
        Write-Host "  FAIL  $Name - $($_.Exception.Message)$where" -ForegroundColor Red
    }
}

function Should-Be { param($Actual, $Expected, [string]$What = 'value') if ($Actual -ne $Expected) { throw "${What}: expected [$Expected], got [$Actual]" } }
function Should-BeTrue { param($Condition, [string]$What) if (-not $Condition) { throw "expected: $What" } }
function Should-BeFalse { param($Condition, [string]$What) if ($Condition) { throw "did not expect: $What" } }
function Should-Throw {
    param([scriptblock]$Body, [string]$Like = '*')
    try { & $Body } catch {
        if ($_.Exception.Message -notlike $Like) { throw "threw '$($_.Exception.Message)', expected something like '$Like'" }
        return
    }
    throw "expected an error like '$Like', but nothing was thrown"
}

function Use-Culture {
    # Runs $Body as if the PC's region format were $Name (dates, number formats, text comparison).
    param([string]$Name, [scriptblock]$Body)
    $t = [System.Threading.Thread]::CurrentThread; $old = $t.CurrentCulture
    try { $t.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Name); & $Body } finally { $t.CurrentCulture = $old }
}

function New-List { param($Items) $l = New-Object System.Collections.ArrayList; foreach ($i in @($Items)) { if ($null -ne $i) { [void]$l.Add($i) } }; return , $l }

function New-FakePkg {
    param([string]$Name, [string]$Family, [switch]$Framework, [switch]$NonRemovable, [string]$Sig = 'Store', [string[]]$Users = @('PC\ana=Installed'))
    if (-not $Family) { $Family = "$($Name)_8wekyb3d8bbwe" }
    return [pscustomobject]@{
        Name = $Name; PackageFullName = "$($Name)_1.0.0.0_x64__8wekyb3d8bbwe"; PackageFamilyName = $Family; Publisher = 'CN=Test'
        Version = '1.0.0.0'; IsFramework = [bool]$Framework; NonRemovable = [bool]$NonRemovable; SignatureKind = $Sig; Users = $Users
    }
}

function New-FakeProv { param([string]$Name) return [pscustomobject]@{ DisplayName = $Name; PackageName = "$($Name)_1.0.0.0_neutral_~_8wekyb3d8bbwe"; Version = '1.0.0.0' } }

function New-FakeOs { param([int]$Build = 19045) return [pscustomobject]@{ Caption = 'Microsoft Windows 10 Pro'; Edition = 'Professional'; Build = $Build; Ubr = 1; DisplayVersion = '22H2'; IsWindows11 = ($Build -ge 22000); IsServer = $false; Is64Bit = $true; Architecture = 'AMD64' } }

function New-FakeInventory {
    param([object[]]$Appx = @(), [object[]]$Prov = @(), [object[]]$Programs = @())
    return [pscustomobject]@{
        Collected = (Get-Date).ToString('s'); Elevated = $true; Os = (New-FakeOs)
        Appx = @($Appx | Where-Object { $_ }); Provisioned = @($Prov | Where-Object { $_ }); Programs = @($Programs | Where-Object { $_ }); Startup = @()
        Summary = [pscustomobject]@{ Apps = @($Appx).Count; ProvisionedForNewUsers = @($Prov).Count; DesktopPrograms = @($Programs).Count; StartupItems = 0 }
    }
}

function Get-FakeKey { param([string]$Key) return (ConvertTo-TkRegKey $Key).ToUpperInvariant() }

function Assert-FakeMounted {
    param([string]$Key)
    $k = ConvertTo-TkRegKey $Key
    if ($k -like 'HKU\*') {
        $hive = ($k -split '\\')[1]
        if (@($global:Fake.Loaded) -notcontains $hive) { throw "Fake PC: wrote to $k while the hive $hive was not loaded." }
    }
}

function Install-FakeSystem {
    param([object[]]$Appx = @(), [object[]]$Prov = @(), [object[]]$Profiles = @(), [string[]]$Loaded = @(), [string[]]$FailRemove = @())
    $global:Fake = [pscustomobject]@{
        Appx = (New-List $Appx); Prov = (New-List $Prov); Reg = @{}; Keys = @{}
        Profiles = @($Profiles); Loaded = (New-List $Loaded); Files = @{}; Calls = (New-List @())
        FailRemove = @($FailRemove); Os = (New-FakeOs); ExitCodes = (New-List @()); LastBoot = [datetime]'2026-11-01T08:00:00'
        SetupCpu = $null; Now = [datetime]'2026-11-21T10:00:00'; ProvisionedRemovesInstalled = $false
        Download = { param($Source, $Destination, $OnProgress) [pscustomobject]@{ Ok = $false; Stalled = $true; Error = 'fake stall' } }
    }
    foreach ($p in @($Profiles)) { $global:Fake.Files[(Join-Path $p.Path 'NTUSER.DAT')] = $true }
    $global:Fake.Files[(Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT')] = $true
    Set-TkSystemAdapter @{
        GetInventory      = { New-FakeInventory -Appx @($global:Fake.Appx) -Prov @($global:Fake.Prov) }
        GetOs             = { $global:Fake.Os }
        FindAppx          = { param($Name) @($global:Fake.Appx | Where-Object { $_.Name -eq $Name }) }
        RemoveAppx        = {
            param($FullName)
            [void]$global:Fake.Calls.Add("RemoveAppx $FullName")
            if ($global:Fake.FailRemove -contains $FullName) { throw 'Removal failed (fake)' }
            foreach ($i in @($global:Fake.Appx | Where-Object { $_.PackageFullName -eq $FullName })) { $global:Fake.Appx.Remove($i) }
        }
        FindProvisioned   = { param($Name) @($global:Fake.Prov | Where-Object { $_.DisplayName -eq $Name }) }
        RemoveProvisioned = {
            param($PackageName)
            [void]$global:Fake.Calls.Add("RemoveProvisioned $PackageName")
            foreach ($i in @($global:Fake.Prov | Where-Object { $_.PackageName -eq $PackageName })) {
                $global:Fake.Prov.Remove($i)
                # Real Windows 10 (1803+) and 11, with -AllUsers: the installed copies go with the new-user copy.
                if ($global:Fake.ProvisionedRemovesInstalled) { foreach ($x in @($global:Fake.Appx | Where-Object { $_.Name -eq $i.DisplayName })) { $global:Fake.Appx.Remove($x) } }
            }
        }
        RegGet            = {
            param($Key, $Name)
            $k = Get-FakeKey $Key
            if ($global:Fake.Reg.ContainsKey($k) -and $global:Fake.Reg[$k].ContainsKey($Name)) { $v = $global:Fake.Reg[$k][$Name]; return [pscustomobject]@{ Exists = $true; Value = $v.Value; Kind = $v.Kind } }
            return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null }
        }
        RegSet            = {
            param($Key, $Name, $Value, $Kind)
            Assert-TkRegistryWrite -Path $Key -Name $Name; Assert-FakeMounted $Key
            $k = Get-FakeKey $Key
            if (-not $global:Fake.Reg.ContainsKey($k)) { $global:Fake.Reg[$k] = @{} }
            $global:Fake.Reg[$k][$Name] = @{ Value = $Value; Kind = $Kind }; $global:Fake.Keys[$k] = $true
            [void]$global:Fake.Calls.Add("RegSet $k\$Name=$Value")
        }
        RegDeleteValue    = {
            param($Key, $Name)
            Assert-TkRegistryWrite -Path $Key -Name $Name; Assert-FakeMounted $Key
            $k = Get-FakeKey $Key
            if ($global:Fake.Reg.ContainsKey($k)) { $global:Fake.Reg[$k].Remove($Name) }
            [void]$global:Fake.Calls.Add("RegDeleteValue $k\$Name")
        }
        RegKeyExists      = { param($Key) $global:Fake.Keys.ContainsKey((Get-FakeKey $Key)) }
        RegCreateKey      = { param($Key) Assert-TkRegistryWrite -Path $Key; $global:Fake.Keys[(Get-FakeKey $Key)] = $true; [void]$global:Fake.Calls.Add("RegCreateKey $(Get-FakeKey $Key)") }
        RegDeleteKey      = { param($Key) Assert-TkRegistryWrite -Path $Key; $global:Fake.Keys.Remove((Get-FakeKey $Key)); [void]$global:Fake.Calls.Add("RegDeleteKey $(Get-FakeKey $Key)") }
        GetProfiles       = { @($global:Fake.Profiles) }
        GetLoadedHives    = { @($global:Fake.Loaded) }
        GetDefaultProfile = { Join-Path $env:SystemDrive 'Users\Default' }
        HiveLoad          = { param($Mount, $File) [void]$global:Fake.Loaded.Add($Mount.Substring(4)); [void]$global:Fake.Calls.Add("HiveLoad $Mount") }
        HiveUnload        = { param($Mount) $global:Fake.Loaded.Remove($Mount.Substring(4)); [void]$global:Fake.Calls.Add("HiveUnload $Mount") }
        TestPath          = { param($Path) $global:Fake.Files.ContainsKey($Path) }
        RunExe            = {
            param($FilePath, $Arguments, $TimeoutSec)
            [void]$global:Fake.Calls.Add("RunExe $FilePath $(@($Arguments) -join ' ')")
            $code = 0
            if ($global:Fake.ExitCodes.Count) { $code = $global:Fake.ExitCodes[0]; $global:Fake.ExitCodes.RemoveAt(0) }
            return [pscustomobject]@{ ExitCode = $code; Output = '' }
        }
        Download          = { param($Source, $Destination, $OnProgress, $StallSeconds) [void]$global:Fake.Calls.Add("Download $Source"); & $global:Fake.Download $Source $Destination $OnProgress }
        MountIso          = { param($Path) [void]$global:Fake.Calls.Add("MountIso $Path"); return 'X:' }
        DismountIso       = { param($Path) [void]$global:Fake.Calls.Add("DismountIso $Path") }
        RegisterTask      = { param($Name, $ScriptPath, $Arguments, $Trigger, $Hours) [void]$global:Fake.Calls.Add("RegisterTask $Name $Trigger") }
        UnregisterTask    = { param($Name) [void]$global:Fake.Calls.Add("UnregisterTask $Name") }
        Restart           = { param($Seconds, $Message) [void]$global:Fake.Calls.Add('Restart') }
        LastBoot          = { $global:Fake.LastBoot }
        SetupCpu          = { $global:Fake.SetupCpu }
        Sleep             = { param($Seconds) $global:Fake.Now = $global:Fake.Now.AddSeconds($Seconds) }
        Now               = { $global:Fake.Now }
    }
}

function Test-Called { param([string]$Like) return [bool]@($global:Fake.Calls | Where-Object { $_ -like $Like }).Count }

function Reset-TkTestData {
    $root = Get-TkDataRoot
    if ($root -notlike '*-test') { throw "Refusing to clear ${root}: not a test folder." }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
}
