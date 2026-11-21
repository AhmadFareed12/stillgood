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
    if ($n -match 'Core\(TM\) Ultra|Core Ultra') { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Core Ultra' } }
    if ($n -match 'Core\(TM\)2|Core 2 ') { return [pscustomobject]@{ Status = 'Fail'; Generation = 'Core 2' } }
    if ($n -match 'Core\(TM\) i[357] CPU') { return [pscustomobject]@{ Status = 'Fail'; Generation = 'Intel gen 1' } }   # "Core(TM) i7 CPU 920"
    if ($n -match 'Core\(TM\) [3579] \d{3}') { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Intel Core series 1 or later' } }
    if ($n -match 'Intel.*\bi[3579]-(\d{3,5})') {
        $d = $Matches[1]
        if ($d.Length -eq 3) { $gen = 1 }
        elseif ($d.Length -eq 5 -or $d.StartsWith('1')) { $gen = [int]$d.Substring(0, 2) }   # 10700 -> 10, 1165G7 -> 11
        else { $gen = [int]$d.Substring(0, 1) }
        if ($gen -ge 8) { return [pscustomobject]@{ Status = 'Pass'; Generation = "Intel gen $gen" } }
        return [pscustomobject]@{ Status = 'Fail'; Generation = "Intel gen $gen" }
    }
    if ($n -match 'Ryzen AI') { return [pscustomobject]@{ Status = 'Pass'; Generation = 'Ryzen AI' } }
    if ($n -match 'Ryzen\s+(?:Threadripper\s+)?(?:PRO\s+)?[3579]\s+(?:PRO\s+)?(\d)\d{3}') {
        $series = [int]$Matches[1]
        if ($series -ge 3) { return [pscustomobject]@{ Status = 'Pass'; Generation = "Ryzen $($series)000" } }
        if ($series -eq 2) { return [pscustomobject]@{ Status = 'Unknown'; Generation = 'Ryzen 2000 (some models are not on the list)' } }
        return [pscustomobject]@{ Status = 'Fail'; Generation = "Ryzen $($series)000" }
    }
    return [pscustomobject]@{ Status = 'Unknown'; Generation = 'not recognised' }
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
    elseif ($bypass.Count) { $v = 'UnsupportedButUpgradeable'; $text = 'This PC fails Windows 11''s hardware check, but the unsupported-hardware option can upgrade it. Microsoft does not support Windows 11 on this hardware and does not guarantee updates there.' }
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
    $sizeGb = [math]::Round($disk.Size / 1GB); $freeGb = [math]::Round($disk.FreeSpace / 1GB)
    $s = 'Fail'; if ($sizeGb -ge 64) { $s = 'Pass' }
    [void]$checks.Add((New-TkCheck 'System disk size' '64 GB' "$sizeGb GB" $s $true 'Part of Microsoft''s hardware check.'))
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

    $sb = $null; $sbNote = 'Part of Microsoft''s hardware check.'
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop }
    catch {
        if ($_.Exception.Message -match 'not supported') { $sb = 'legacy' } else { $sb = 'unknown' }
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
