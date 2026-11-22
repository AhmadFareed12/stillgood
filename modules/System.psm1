# System.psm1 - every call that changes the PC goes through this table of adapters.
# The tests swap in stand-ins; in test mode (TK_TEST_MODE=1) a real adapter refuses to run, so a test can never touch the PC.
Set-StrictMode -Version 2.0

function Assert-TkRealSystem {
    param([string]$What)
    if (Test-TkTestMode) { throw "Test mode: the real system call '$What' was blocked. Give the test a stand-in." }
}

function ConvertTo-TkArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Invoke-TkExe {
    # Runs a program and captures its output without PowerShell's stderr quirks.
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @(), [int]$TimeoutSec = 0)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-TkArg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if ($TimeoutSec -gt 0) {
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; throw "$FilePath did not finish within $TimeoutSec seconds." }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out.Result + $err.Result).Trim() }
}

function Open-TkRegKey {
    param([string]$Key, [bool]$Writable, [bool]$Create)
    $k = ConvertTo-TkRegKey $Key
    $parts = $k -split '\\', 2
    switch ($parts[0]) {
        'HKLM' { $root = [Microsoft.Win32.Registry]::LocalMachine }
        'HKU' { $root = [Microsoft.Win32.Registry]::Users }
        default { throw "Unsupported registry hive in '$Key' (use HKLM or HKU)." }
    }
    if ($Create) { return $root.CreateSubKey($parts[1]) }
    return $root.OpenSubKey($parts[1], $Writable)
}

$script:HasProvAllUsers = $null

function New-TkRealAdapters {
    return @{
        GetInventory      = { Assert-TkRealSystem 'GetInventory'; Get-TkInventory }
        GetOs             = { Get-TkOsInfo }
        FindAppx          = { param($Name) Assert-TkRealSystem 'FindAppx'; @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue) }
        RemoveAppx        = { param($FullName) Assert-TkRealSystem 'RemoveAppx'; Remove-AppxPackage -Package $FullName -AllUsers -ErrorAction Stop }
        FindProvisioned   = { param($Name) Assert-TkRealSystem 'FindProvisioned'; @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Name }) }
        RemoveProvisioned = {
            param($PackageName)
            Assert-TkRealSystem 'RemoveProvisioned'
            if ($null -eq $script:HasProvAllUsers) { $script:HasProvAllUsers = (Get-Command Remove-AppxProvisionedPackage).Parameters.ContainsKey('AllUsers') }
            if ($script:HasProvAllUsers) { Remove-AppxProvisionedPackage -Online -PackageName $PackageName -AllUsers -ErrorAction Stop | Out-Null }
            else { Remove-AppxProvisionedPackage -Online -PackageName $PackageName -ErrorAction Stop | Out-Null }
        }
        RegGet            = {
            param($Key, $Name)
            $h = Open-TkRegKey $Key $false $false
            if (-not $h) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
            try {
                if (@($h.GetValueNames()) -notcontains $Name) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
                return [pscustomobject]@{ Exists = $true; Value = $h.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Kind = [string]$h.GetValueKind($Name) }
            } finally { $h.Close() }
        }
        RegSet            = {
            param($Key, $Name, $Value, $Kind)
            Assert-TkRealSystem 'RegSet'; Assert-TkRegistryWrite -Path $Key -Name $Name
            $h = Open-TkRegKey $Key $true $true
            try { $h.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $h.Close() }
        }
        RegDeleteValue    = {
            param($Key, $Name)
            Assert-TkRealSystem 'RegDeleteValue'; Assert-TkRegistryWrite -Path $Key -Name $Name
            $h = Open-TkRegKey $Key $true $false
            if ($h) { try { $h.DeleteValue($Name, $false) } finally { $h.Close() } }
        }
        RegKeyExists      = { param($Key) $h = Open-TkRegKey $Key $false $false; if ($h) { $h.Close(); return $true }; return $false }
        RegCreateKey      = {
            param($Key)
            Assert-TkRealSystem 'RegCreateKey'; Assert-TkRegistryWrite -Path $Key
            $h = Open-TkRegKey $Key $true $true; $h.Close()
        }
        RegDeleteKey      = {
            param($Key)
            Assert-TkRealSystem 'RegDeleteKey'; Assert-TkRegistryWrite -Path $Key
            $k = ConvertTo-TkRegKey $Key; $parts = $k -split '\\', 2
            if ($parts[0] -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKey($parts[1], $false) }
            else { [Microsoft.Win32.Registry]::Users.DeleteSubKey($parts[1], $false) }
        }
        GetProfiles       = {
            foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
                $sid = $k.PSChildName
                if ($sid -notmatch '^S-1-5-21-|^S-1-12-1-') { continue }
                $path = Get-TkProp (Get-ItemProperty -LiteralPath $k.PSPath) 'ProfileImagePath'
                if ($path) { [pscustomobject]@{ Sid = $sid; Path = [Environment]::ExpandEnvironmentVariables($path) } }
            }
        }
        GetLoadedHives    = { @([Microsoft.Win32.Registry]::Users.GetSubKeyNames()) }
        GetDefaultProfile = {
            # Where new users' profile comes from, as Windows records it (organizations can move profiles).
            $p = Get-TkProp (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue) 'Default'
            if ($p) { [Environment]::ExpandEnvironmentVariables([string]$p) } else { Join-Path $env:SystemDrive 'Users\Default' }
        }
        HiveLoad          = {
            param($Mount, $File)
            Assert-TkRealSystem 'HiveLoad'
            $r = Invoke-TkExe -FilePath "$env:SystemRoot\System32\reg.exe" -Arguments @('load', $Mount, $File) -TimeoutSec 60
            if ($r.ExitCode -ne 0) { throw "Could not load $File ($($r.Output))" }
        }
        HiveUnload        = {
            param($Mount)
            Assert-TkRealSystem 'HiveUnload'
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            for ($i = 0; $i -lt 5; $i++) {
                $r = Invoke-TkExe -FilePath "$env:SystemRoot\System32\reg.exe" -Arguments @('unload', $Mount) -TimeoutSec 60
                if ($r.ExitCode -eq 0) { return }
                Start-Sleep -Milliseconds 500
            }
            throw "Could not unload $Mount ($($r.Output))"
        }
        TestPath          = { param($Path) Test-Path -LiteralPath $Path }
        RunExe            = { param($FilePath, $Arguments, $TimeoutSec) Assert-TkRealSystem 'RunExe'; Invoke-TkExe -FilePath $FilePath -Arguments $Arguments -TimeoutSec $TimeoutSec }
        Download          = { param($Source, $Destination, $OnProgress, $StallSeconds) Assert-TkRealSystem 'Download'; Invoke-TkTransfer -Source $Source -Destination $Destination -OnProgress $OnProgress -StallSeconds $StallSeconds }
        MountIso          = {
            param($Path)
            Assert-TkRealSystem 'MountIso'
            $img = Get-DiskImage -ImagePath $Path -ErrorAction Stop
            if (-not $img.Attached) { $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop }
            for ($i = 0; $i -lt 10; $i++) {
                $letter = (Get-DiskImage -ImagePath $Path | Get-Volume).DriveLetter
                if ($letter) { return "$($letter):" }
                Start-Sleep -Seconds 1
            }
            throw "The image mounted but got no drive letter: $Path"
        }
        DismountIso       = { param($Path) Assert-TkRealSystem 'DismountIso'; Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null }
        RegisterTask      = {
            param($Name, $ScriptPath, $Arguments, $Trigger, $Hours)
            Assert-TkRealSystem 'RegisterTask'
            $folder = "\$((Get-TkProduct).Name)\"
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" " + $Arguments)
            # S-1-5-18 is the SYSTEM account in every Windows language (its display name is translated on some).
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours $Hours)
            $reg = @{ TaskName = $Name; TaskPath = $folder; Action = $action; Principal = $principal; Settings = $settings; Force = $true }
            if ($Trigger -eq 'Logon') { $reg['Trigger'] = New-ScheduledTaskTrigger -AtLogOn }
            Register-ScheduledTask @reg | Out-Null
            if ($Trigger -eq 'Now') { Start-ScheduledTask -TaskName $Name -TaskPath $folder }
        }
        UnregisterTask    = { param($Name) Assert-TkRealSystem 'UnregisterTask'; Unregister-ScheduledTask -TaskName $Name -TaskPath "\$((Get-TkProduct).Name)\" -Confirm:$false -ErrorAction SilentlyContinue }
        Restart           = { param($Seconds, $Message) Assert-TkRealSystem 'Restart'; Invoke-TkExe -FilePath "$env:SystemRoot\System32\shutdown.exe" -Arguments @('/r', '/t', [string]$Seconds, '/c', $Message) | Out-Null }
        LastBoot          = { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
        SetupCpu          = { $p = @(Get-Process -Name SetupHost -ErrorAction SilentlyContinue); if (-not $p.Count) { return $null }; [double]($p | Measure-Object -Property CPU -Sum).Sum }
        Sleep             = { param($Seconds) Start-Sleep -Seconds $Seconds }
        Now               = { Get-Date }
    }
}

$script:Sys = New-TkRealAdapters

function Set-TkSystemAdapter {
    param([Parameter(Mandatory = $true)][hashtable]$Overrides)
    foreach ($k in @($Overrides.Keys)) {
        if (-not $script:Sys.ContainsKey($k)) { throw "Unknown adapter: $k" }
        $script:Sys[$k] = $Overrides[$k]
    }
}

function Reset-TkSystemAdapter { $script:Sys = New-TkRealAdapters }

function Invoke-TkSys {
    param([Parameter(Mandatory = $true)][string]$Name, [object[]]$ArgumentList = @())
    if (-not $script:Sys.ContainsKey($Name)) { throw "Unknown adapter: $Name" }
    return (& $script:Sys[$Name] @ArgumentList)
}

function Invoke-TkTransfer {
    # Download over HTTP(S) with BITS, or copy from a share, with measured progress and stall detection.
    param([string]$Source, [string]$Destination, [scriptblock]$OnProgress, [int]$StallSeconds = 600)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Source -match '^https?://') {
        Import-Module BitsTransfer -ErrorAction Stop
        $job = Start-BitsTransfer -Source $Source -Destination $Destination -Asynchronous -Priority Foreground -DisplayName "$((Get-TkProduct).Name) image download" -ErrorAction Stop
        $last = [uint64]0; $moved = Get-Date
        while ($true) {
            $job = Get-BitsTransfer -JobId $job.JobId -ErrorAction Stop
            $state = [string]$job.JobState
            if ($state -eq 'Transferred') { Complete-BitsTransfer -BitsJob $job; return [pscustomobject]@{ Ok = $true; Stalled = $false; Error = '' } }
            if ($state -eq 'Error') { $msg = [string]$job.ErrorDescription; Remove-BitsTransfer -BitsJob $job; return [pscustomobject]@{ Ok = $false; Stalled = $false; Error = $msg } }
            if ($state -eq 'Suspended') { Resume-BitsTransfer -BitsJob $job -Asynchronous | Out-Null }
            $total = [uint64]$job.BytesTotal; if ($total -eq [uint64]::MaxValue) { $total = [uint64]0 }
            if ([uint64]$job.BytesTransferred -gt $last) { $last = [uint64]$job.BytesTransferred; $moved = Get-Date }
            elseif (((Get-Date) - $moved).TotalSeconds -ge $StallSeconds) {
                Remove-BitsTransfer -BitsJob $job
                return [pscustomobject]@{ Ok = $false; Stalled = $true; Error = "No progress for $StallSeconds seconds." }
            }
            if ($OnProgress) { & $OnProgress $last $total }
            Start-Sleep -Seconds 2
        }
    }
    $tmp = "$Destination.partial"
    $src = [System.IO.File]::Open($Source, 'Open', 'Read', 'Read')
    $dst = [System.IO.File]::Open($tmp, 'Create', 'Write', 'None')
    try {
        $total = [uint64]$src.Length; $done = [uint64]0; $buf = New-Object byte[] (4MB); $tick = Get-Date
        while ($true) {
            $t = $src.ReadAsync($buf, 0, $buf.Length)
            if (-not $t.Wait($StallSeconds * 1000)) { return [pscustomobject]@{ Ok = $false; Stalled = $true; Error = "No data for $StallSeconds seconds." } }
            $n = $t.Result
            if ($n -le 0) { break }
            $dst.Write($buf, 0, $n); $done += [uint64]$n
            if ($OnProgress -and ((Get-Date) - $tick).TotalSeconds -ge 1) { & $OnProgress $done $total; $tick = Get-Date }
        }
    } finally { $src.Close(); $dst.Close() }
    if ($done -ne $total) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; return [pscustomobject]@{ Ok = $false; Stalled = $true; Error = 'The copy stopped early.' } }
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
    if ($OnProgress) { & $OnProgress $done $total }
    return [pscustomobject]@{ Ok = $true; Stalled = $false; Error = '' }
}

Export-ModuleMember -Function *
