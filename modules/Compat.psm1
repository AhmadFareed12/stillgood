# Compat.psm1 - READ-ONLY. Can this PC run Windows 11, and what stands in the way?
# Separates hard blockers (nothing gets around them) from Microsoft's hardware checks (the unsupported-hardware option
# gets around them, at the admin's own risk). Unknown is never reported as a pass.
Set-StrictMode -Version 2.0

if (-not ('TkNative.Cpu' -as [type])) {
    Add-Type -Namespace TkNative -Name Cpu -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
}

function New-TkCheck {
    param([string]$Name, [string]$Required, [string]$Found, [ValidateSet('Pass', 'Fail', 'Unknown')][string]$Status, [bool]$Bypassable, [string]$Note, [bool]$Fixable = $false)
    return [pscustomobject]@{ Name = $Name; Required = $Required; Found = $Found; Status = $Status; Bypassable = $Bypassable; Fixable = $Fixable; Note = $Note }
}

function Get-TkCpuSupport {
    # Pure function: a best-effort reading of the processor name against Windows 11's processor list.
    # Unrecognised names come back as Unknown, never as a pass.
    param([string]$Name)
    $n = [string]$Name
    $rx = { param($p) [regex]::Match($n, $p, 'IgnoreCase, CultureInvariant') }   # same result in every Windows language
    if ((& $rx 'Core\(TM\) Ultra|Core Ultra').Success) { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Core Ultra' } }
    if ((& $rx 'Core\(TM\)2|Core 2 ').Success) { return [pscustomobject]@{ Status = 'Fail'; Generation = 'Core 2' } }
    if ((& $rx 'Core\(TM\) i[357] CPU').Success) { return [pscustomobject]@{ Status = 'Fail'; Generation = 'Intel gen 1' } }   # "Core(TM) i7 CPU 920"
    if ((& $rx 'Core\(TM\) [3579] \d{3}').Success) { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Intel Core series 1 or later' } }
    $m = & $rx 'Intel.*\bi[3579]-(\d{3,5})'
    if ($m.Success) {
        $d = $m.Groups[1].Value
        if ($d.Length -eq 3) { $gen = 1 }
        elseif ($d.Length -eq 5 -or $d.StartsWith('1')) { $gen = [int]$d.Substring(0, 2) }   # 10700 -> 10, 1165G7 -> 11
        else { $gen = [int]$d.Substring(0, 1) }
        if ($gen -ge 8) { return [pscustomobject]@{ Status = 'Pass'; Generation = "Intel gen $gen" } }
        return [pscustomobject]@{ Status = 'Fail'; Generation = "Intel gen $gen" }
    }
    # Intel Xeon E3, E5 and E7, versions 1 to 6 (2011-2017): none are on the list. (Xeon E-2xxx, a later family, is not matched.)
    $m = & $rx 'Xeon\(R\)\s+CPU\s+E([357])-\d{4}\w*(?:\s+v(\d))?'
    if ($m.Success) {
        $v = 1; if ($m.Groups[2].Success) { $v = [int]$m.Groups[2].Value }
        return [pscustomobject]@{ Status = 'Fail'; Generation = "Intel Xeon E$($m.Groups[1].Value) v$v" }
    }
    # Atom-class Celeron and Pentium of 2013-2016 (Bay Trail, Braswell, Apollo Lake): J1/J2/N2/N3/J3 models, Pentium N4200
    # and J4205. Their successors (J4105, N4020 and on) are on the list for some models, so they stay Unknown here.
    $m = & $rx '(Celeron|Pentium)\(R\)\s+(?:Silver\s+)?(?:CPU\s+)?([JN]\d{4})'
    if ($m.Success) {
        $model = $m.Groups[2].Value.ToUpperInvariant()
        if ([regex]::IsMatch($model, '^(J1|J2|N2|N3|J3)\d{3}$') -or @('N4200', 'J4205') -contains $model) {
            return [pscustomobject]@{ Status = 'Fail'; Generation = "Intel $($m.Groups[1].Value) $model (2013-2016)" }
        }
    }
    if ((& $rx 'Ryzen AI').Success) { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Ryzen AI' } }
    $m = & $rx 'Ryzen\s+(?:Threadripper\s+)?(?:PRO\s+)?[3579]\s+(?:PRO\s+)?(\d)\d{3}'
    if ($m.Success) {
        $series = [int]$m.Groups[1].Value
        if ($series -ge 3) { return [pscustomobject]@{ Status = 'Pass'; Generation = "Ryzen $($series)000" } }
        if ($series -eq 2) { return [pscustomobject]@{ Status = 'Unknown'; Generation = 'Ryzen 2000 (some models are not on the list)' } }
        return [pscustomobject]@{ Status = 'Fail'; Generation = "Ryzen $($series)000" }
    }
    return [pscustomobject]@{ Status = 'Unknown'; Generation = 'not recognised' }
}

function Get-TkSystemDiskBytes {
    # The physical disk that holds the Windows volume (no admin rights needed). Falls back to the volume itself.
    param($Volume)
    try {
        $part = Get-CimAssociatedInstance -InputObject $Volume -ResultClassName Win32_DiskPartition -ErrorAction Stop | Select-Object -First 1
        $drive = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive -ErrorAction Stop | Select-Object -First 1
        if ($drive -and $drive.Size) { return [double]$drive.Size }
    } catch { }
    return [double]$Volume.Size
}

function Get-TkBypassReason {
    # A failed check the unsupported-hardware option gets around, in a few plain words.
    param($Check)
    switch ([string]$Check.Name) {
        'TPM' { if ([string]$Check.Found -eq 'none') { return 'no TPM 2.0' } else { return "$($Check.Found) instead of TPM 2.0" } }
        'Processor model' { return 'its processor is not on Microsoft''s list' }
        'UEFI and Secure Boot' { return 'legacy BIOS instead of UEFI' }
        default { return "$($Check.Name): $($Check.Found)" }
    }
}

function Get-TkVerdict {
    # Pure function: turns the checks into one verdict.
    param([object[]]$Checks)
    $blockers = @($Checks | Where-Object { $_.Status -eq 'Fail' -and -not $_.Bypassable -and -not $_.Fixable })
    $fixable = @($Checks | Where-Object { $_.Status -eq 'Fail' -and $_.Fixable })
    $bypass = @($Checks | Where-Object { $_.Status -eq 'Fail' -and $_.Bypassable })
    $unknown = @($Checks | Where-Object { $_.Status -eq 'Unknown' })
    if ($blockers.Count) { $v = 'NotUpgradeable'; $text = 'This PC cannot run Windows 11.' }
    elseif ($fixable.Count) { $v = 'FixFirst'; $text = 'Fix the items marked below first; then this PC can be upgraded.' }
    elseif ($bypass.Count) {
        # What works comes first, then the plain reason and Microsoft's position (never hidden: the admin decides).
        $why = (@($bypass | ForEach-Object { Get-TkBypassReason $_ }) -join ', ')
        $v = 'UnsupportedButUpgradeable'
        $text = "StillGood can upgrade this PC to Windows 11. It doesn't pass Microsoft's hardware check ($why), so it upgrades with the unsupported-hardware option. Microsoft doesn't officially support Windows 11 on this hardware or promise updates for it."
    }
    elseif ($unknown.Count) { $v = 'ProbablySupported'; $text = 'No failed checks, but some could not be read (run as administrator for TPM and Secure Boot).' }
    else { $v = 'Supported'; $text = 'This PC meets Windows 11''s requirements.' }
    return [pscustomobject]@{
        Verdict    = $v
        Summary    = $text
        Blockers   = @($blockers | ForEach-Object { "$($_.Name): $($_.Found)" })
        Fixable    = @($fixable | ForEach-Object { "$($_.Name): $($_.Found)" })
        Bypassable = @($bypass | ForEach-Object { "$($_.Name): $($_.Found)" })
        Unknown    = @($unknown | ForEach-Object { $_.Name })
    }
}

function Get-TkWin11Readiness {
    $checks = New-Object System.Collections.ArrayList

    $is64 = [Environment]::Is64BitOperatingSystem
    $f = 'x86'; $s = 'Fail'; if ($is64) { $f = 'x64'; $s = 'Pass' }
    [void]$checks.Add((New-TkCheck '64-bit Windows' 'x64' $f $s $false 'Windows 11 is 64-bit only.'))

    $sse42 = $false
    try { $sse42 = [TkNative.Cpu]::IsProcessorFeaturePresent(38) } catch { }   # 38 = PF_SSE4_2_INSTRUCTIONS_AVAILABLE
    $f = 'missing'; $s = 'Fail'; if ($sse42) { $f = 'present'; $s = 'Pass' }
    [void]$checks.Add((New-TkCheck 'Processor instructions (SSE4.2 and POPCNT)' 'present' $f $s $false 'Windows 11 24H2 and later do not start without them. No option gets around this.'))

    # Installed memory (what the PC has), falling back to what Windows can use when the modules can't be read.
    $installed = 0
    try { $installed = [double](Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum } catch { }
    if ($installed -gt 0) { $ramGb = [math]::Round($installed / 1GB, 1); $minGb = 4 }
    else { $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1); $minGb = 3.5 }
    $s = 'Fail'; if ($ramGb -ge $minGb) { $s = 'Pass' }
    [void]$checks.Add((New-TkCheck 'Memory' '4 GB' "$ramGb GB" $s $false 'Below 4 GB, Windows 11 is not usable.'))

    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $freeGb = [math]::Round($disk.FreeSpace / 1GB)
    # Microsoft's requirement is the storage device ("64 GB" as printed on it), not the Windows partition, which is
    # always a little smaller. A 63 GB floor allows for disks that report a few hundred MB under their label.
    $devBytes = Get-TkSystemDiskBytes -Volume $disk
    $s = 'Fail'; if ($devBytes -ge 63e9) { $s = 'Pass' }
    [void]$checks.Add((New-TkCheck 'Storage device size' '64 GB' ('{0} GB' -f [math]::Round($devBytes / 1e9)) $s $true 'Part of Microsoft''s hardware check: the whole disk, not the Windows partition.'))
    $s = 'Fail'; if ($freeGb -ge 30) { $s = 'Pass' }
    [void]$checks.Add((New-TkCheck 'Free space for the upgrade' '30 GB' "$freeGb GB" $s $false 'Setup needs room for the image, the new Windows and the old one until it is removed.' $true))

    $tpm = $null; $tpmReadable = $true
    try { $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop } catch { $tpmReadable = $false }
    if (-not $tpmReadable) {
        [void]$checks.Add((New-TkCheck 'TPM' '2.0' 'not readable' 'Unknown' $true 'Run as administrator to read the TPM.'))
    }
    elseif (-not $tpm) {
        [void]$checks.Add((New-TkCheck 'TPM' '2.0' 'none' 'Fail' $true 'No TPM: only the unsupported-hardware option can upgrade this PC.'))
    }
    else {
        $spec = ([string]$tpm.SpecVersion -split ',')[0].Trim()
        $s = 'Fail'; if ($spec -like '2.0*') { $s = 'Pass' }
        [void]$checks.Add((New-TkCheck 'TPM' '2.0' "TPM $spec" $s $true 'Part of Microsoft''s hardware check.'))
    }

    # Firmware and Secure Boot, read the same way in every Windows language and without admin rights:
    # Windows sets %firmware_type% (UEFI or Legacy) and keeps the Secure Boot state in the registry.
    # (The old way read Confirm-SecureBootUEFI's error message, which is translated on non-English Windows.)
    $sb = $null; $sbNote = 'Part of Microsoft''s hardware check.'
    $fw = [string]$env:firmware_type
    $sbReg = Get-TkProp (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue) 'UEFISecureBootEnabled'
    if ($fw -eq 'Legacy') { $sb = 'legacy' }
    elseif ($null -ne $sbReg) { $sb = ([int]$sbReg -eq 1) }
    else {
        try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop }
        catch [System.PlatformNotSupportedException] { $sb = 'legacy' }
        catch { $sb = 'unknown' }
        if ($sb -eq 'unknown' -and $fw -eq 'UEFI') { $sb = $false }   # UEFI without a readable state: Secure Boot capable, state unknown
    }
    if ($sb -eq $true) { [void]$checks.Add((New-TkCheck 'UEFI and Secure Boot' 'UEFI, Secure Boot capable' 'UEFI, Secure Boot on' 'Pass' $true $sbNote)) }
    elseif ($sb -eq $false) { [void]$checks.Add((New-TkCheck 'UEFI and Secure Boot' 'UEFI, Secure Boot capable' 'UEFI, Secure Boot off' 'Pass' $true 'Secure Boot capable; turning it on is recommended.')) }
    elseif ($sb -eq 'legacy') { [void]$checks.Add((New-TkCheck 'UEFI and Secure Boot' 'UEFI, Secure Boot capable' 'legacy BIOS' 'Fail' $true $sbNote)) }
    else { [void]$checks.Add((New-TkCheck 'UEFI and Secure Boot' 'UEFI, Secure Boot capable' 'not readable' 'Unknown' $true 'Run as administrator to read Secure Boot.')) }

    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $cpu = Get-TkCpuSupport -Name $cpuName
    [void]$checks.Add((New-TkCheck 'Processor model' 'on Microsoft''s Windows 11 list' "$($cpuName.Trim()) ($($cpu.Generation))" $cpu.Status $true 'Part of Microsoft''s hardware check. Read from the model name, so unrecognised models show as unknown.'))

    $verdict = Get-TkVerdict -Checks @($checks)
    return [pscustomobject]@{
        Checked  = (Get-Date).ToString('s')
        Verdict  = $verdict.Verdict
        Summary  = $verdict.Summary
        Blockers = $verdict.Blockers
        Fixable  = $verdict.Fixable
        Bypassable = $verdict.Bypassable
        Unknown  = $verdict.Unknown
        Checks   = @($checks)
    }
}

Export-ModuleMember -Function *
