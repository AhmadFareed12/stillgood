# Speed.psm1 - "Make this PC faster": what slows this PC down, most important first, and what to do about each.
# Read-only, like the rest of the check. Get-TkSpeedFacts reads the PC, each reading on its own, so one that fails
# never stops the check. Get-TkSpeedFindings is pure: it turns the facts into findings. Only causes with a known,
# real effect are reported. No registry "speed tweaks".
Set-StrictMode -Version 2.0

$script:PowerSaver = 'a1841308-3541-4fab-bc81-f71556f20b4a'   # the plan's ID is the same in every Windows language

function Get-TkSum {
    # Adds up a property over a list; 0 for an empty list (Measure-Object gives nothing back then).
    param($Items, [string]$Property)
    $t = [double]0
    foreach ($i in @($Items)) { if ($null -ne $i) { $v = Get-TkProp $i $Property; if ($v) { $t += [double]$v } } }
    return $t
}

function Get-TkTempFolders {
    # Windows' own temp folder and each profile's. Profiles this account may not read are skipped quietly.
    $list = @(Join-Path $env:SystemRoot 'Temp')
    foreach ($u in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive '\Users') -Directory -Force -ErrorAction SilentlyContinue)) {
        $t = Join-Path $u.FullName 'AppData\Local\Temp'
        try { if (Test-Path -LiteralPath $t -ErrorAction SilentlyContinue) { $list += $t } } catch { }
    }
    return $list
}

function Get-TkFolderBytes {
    # The size of the files in these folders, counting at most MaxFiles of them, so it stays quick on a hard drive.
    param([string[]]$Folders, [int]$MaxFiles = 20000)
    $total = [double]0; $left = $MaxFiles
    foreach ($d in @($Folders)) {
        if ($left -le 0) { break }
        $files = @(Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First $left)
        $left -= $files.Count
        $total += Get-TkSum $files 'Length'
    }
    return $total
}

function Test-TkStartupOn {
    # Programs switched off in Task Manager stay in the Run key, marked off under StartupApproved (odd first byte).
    param($Item)
    $m = [regex]::Match([string]$Item.Location, '^(HKLM|HKU\\[^\\]+)\\SOFTWARE\\(WOW6432NODE\\)?MICROSOFT\\WINDOWS\\CURRENTVERSION\\RUN$', 'IgnoreCase, CultureInvariant')
    if (-not $m.Success) { return $true }
    $root = $m.Groups[1].Value -replace '^HKLM', 'HKEY_LOCAL_MACHINE' -replace '^HKU', 'HKEY_USERS'
    $key = "Registry::$root\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    if ($m.Groups[2].Success) { $key += '32' }
    try {
        $v = (Get-ItemProperty -LiteralPath $key -Name ([string]$Item.Name) -ErrorAction Stop).([string]$Item.Name)
        if ($v -is [byte[]] -and $v.Length) { return (($v[0] -band 1) -eq 0) }
    } catch { }
    return $true
}

function Get-TkSpeedFacts {
    param($Inventory, [int]$CleanCount = 0)
    Assert-TkRealSystem 'GetSpeedFacts'
    $f = [ordered]@{
        DiskMedia = $null; DiskHealth = $null; DiskWear = $null; DiskReadErrors = $null
        RamGB = $null; Slots = $null; SlotsUsed = $null; MemInUsePct = $null
        FreeGB = $null; SizeGB = $null; TempGB = $null; HiberGB = $null; WindowsOld = $false
        StartupCount = $null; StartupNames = @()
        PowerScheme = $null; UptimeDays = $null; RebootPending = $false
        Antivirus = @(); BatteryPct = $null; CleanCount = $CleanCount
    }
    $sys = $env:SystemDrive; if (-not $sys) { $sys = 'C:' }
    try {
        $part = Get-Partition -DriveLetter $sys.Substring(0, 1) -ErrorAction Stop | Select-Object -First 1
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($pd) {
            $f.DiskMedia = [string]$pd.MediaType; $f.DiskHealth = [string]$pd.HealthStatus
            try { $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop; $f.DiskWear = $rc.Wear; $f.DiskReadErrors = $rc.ReadErrorsUncorrected } catch { }
        }
    } catch { }
    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $f.SlotsUsed = $sticks.Count
        $installed = Get-TkSum $sticks 'Capacity'
        if (-not $installed) { $installed = [double](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory }
        $f.RamGB = [math]::Round($installed / 1GB, 1)
        $arr = @(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop | Where-Object { $_.Use -eq 3 })   # 3: system memory
        if ($arr.Count) { $f.Slots = [int](Get-TkSum $arr 'MemoryDevices') }
    } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.TotalVisibleMemorySize) { $f.MemInUsePct = [int](100 - 100 * [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize) }
        $f.UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    } catch { }
    try {
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -ErrorAction Stop
        $f.FreeGB = [math]::Round([double]$ld.FreeSpace / 1GB, 1); $f.SizeGB = [math]::Round([double]$ld.Size / 1GB, 1)
    } catch { }
    try { $f.HiberGB = [math]::Round((Get-Item -LiteralPath (Join-Path $sys '\hiberfil.sys') -Force -ErrorAction Stop).Length / 1GB, 1) } catch { }
    $f.WindowsOld = Test-Path -LiteralPath (Join-Path $sys '\Windows.old')
    try { $f.TempGB = [math]::Round((Get-TkFolderBytes -Folders (Get-TkTempFolders)) / 1GB, 1) } catch { }
    try {
        $on = @(@(Get-TkProp $Inventory 'Startup') | Where-Object { $_ -and (Test-TkStartupOn $_) })
        $f.StartupCount = $on.Count; $f.StartupNames = @($on | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    } catch { }
    try {
        $out = (& (Join-Path $env:SystemRoot 'System32\powercfg.exe') /getactivescheme 2>$null | Out-String)
        $m = [regex]::Match($out, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($m.Success) { $f.PowerScheme = $m.Value.ToLowerInvariant() }
    } catch { }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path -LiteralPath $k) { $f.RebootPending = $true }
    }
    try {
        # Real-time protection on: bits 12-15 of productState are 1 (0x61100 on, 0x60100 off for Windows Security).
        $f.Antivirus = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { (([int64]$_.productState -shr 12) -band 0xF) -eq 1 } | ForEach-Object { [string]$_.displayName } | Sort-Object -Unique)
    } catch { }
    try {
        if (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count) {
            $design = [double](@(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryStaticData -ErrorAction Stop)[0].DesignedCapacity)
            $full = [double](@(Get-CimInstance -Namespace 'root\wmi' -ClassName BatteryFullChargedCapacity -ErrorAction Stop)[0].FullChargedCapacity)
            if ($design -gt 0 -and $full -gt 0) { $f.BatteryPct = [int](100 * $full / $design) }
        }
    } catch { }
    return [pscustomobject]$f
}

function New-TkFinding {
    param([string]$Id, [string]$Impact, [string]$Title, [string]$Found, [string]$Fix, [string]$By)
    return [pscustomobject]@{ Id = $Id; Impact = $Impact; Title = $Title; Found = $Found; Fix = $Fix; By = $By }
}

function Get-TkSpeedFindings {
    # Pure: the facts in, the findings out (High, Medium, Low), plus what is already good. A fact that could not be
    # read is simply left out.
    param([Parameter(Mandatory = $true)]$Facts)
    $p = { param($n) Get-TkProp $Facts $n }
    $out = New-Object System.Collections.ArrayList; $good = New-Object System.Collections.ArrayList

    # The disk: failing first, then a spinning hard drive.
    $health = [string](& $p 'DiskHealth'); $wear = & $p 'DiskWear'; $rerr = & $p 'DiskReadErrors'; $media = [string](& $p 'DiskMedia')
    $bad = @()
    if ($health -eq 'Warning' -or $health -eq 'Unhealthy') { $bad += "Windows rates the Windows disk '$health'" }
    if ($rerr -and [int64]$rerr -gt 0) { $bad += "it has $rerr read errors it could not correct" }
    if ($wear -and [int]$wear -ge 90) { $bad += "the SSD is $wear% worn out" }
    if ($bad.Count) { [void]$out.Add((New-TkFinding 'disk-health' 'High' 'The disk is failing' (($bad -join '; ') + '.') 'Back up this PC now and replace the disk before upgrading or cleaning: a failing disk is slow, and it can lose everything.' 'Hardware')) }
    if ($media -eq 'HDD') { [void]$out.Add((New-TkFinding 'hdd' 'High' 'A spinning hard drive' 'Windows runs from a hard drive (HDD).' 'Replace it with an SSD: the biggest single speed-up an old PC can get. Start-up, sign-in and opening programs get several times faster, and a disk clone moves Windows, programs and files over unchanged.' 'Hardware')) }
    elseif ($media -eq 'SSD' -and -not $bad.Count) { [void]$good.Add('Windows runs from an SSD') }

    # Memory.
    $ram = & $p 'RamGB'
    if ($ram) {
        $gb = [int][math]::Round([double]$ram)
        $found = "$gb GB installed"
        $inuse = & $p 'MemInUsePct'; if ($null -ne $inuse) { $found += ", $inuse% of it in use right now" }
        $slots = & $p 'Slots'; $used = & $p 'SlotsUsed'; $slotText = ''
        if ($slots -and $used) {
            $free = [int]$slots - [int]$used
            if ($free -gt 0) { $slotText = " $free of its $slots memory slots $(if ($free -eq 1) { 'is' } else { 'are' }) free, so adding one module is enough." }
            elseif ([int]$slots -eq 1) { $slotText = ' Its only memory slot is in use, so the module needs replacing with a larger one.' }
            elseif ([int]$slots -eq 2) { $slotText = ' Both memory slots are in use, so the modules need replacing with larger ones.' }
            else { $slotText = " All $slots memory slots are in use, so the modules need replacing with larger ones." }
        }
        if ([double]$ram -le 4.5) { [void]$out.Add((New-TkFinding 'memory' 'High' "Only $gb GB of memory" "$found." ("Windows 11 runs on 4 GB, but 8 GB makes it comfortable with a browser and Office open." + $slotText) 'Hardware')) }
        elseif ([double]$ram -lt 7.5) { [void]$out.Add((New-TkFinding 'memory' 'Medium' "$gb GB of memory" "$found." ("8 GB or more makes Windows 11 comfortable with a browser and Office open." + $slotText) 'Hardware')) }
        else { [void]$good.Add("$gb GB of memory") }
    }

    # Disk space, and what can be freed.
    $freeGb = & $p 'FreeGB'; $size = & $p 'SizeGB'; $temp = & $p 'TempGB'; $hiber = & $p 'HiberGB'
    $clean = @()
    if ($temp -and [double]$temp -ge 0.5) { $clean += "temporary files (about $temp GB)" }
    if ($hiber -and [double]$hiber -ge 1) { $clean += "the hibernation file ($hiber GB, if nobody uses hibernate: powercfg /h off)" }
    if ([bool](& $p 'WindowsOld')) { $clean += 'the previous Windows in Windows.old (Disk Cleanup, Clean up system files)' }
    if ($null -ne $freeGb) {
        $pct = 100; if ($size) { $pct = [int](100 * [double]$freeGb / [double]$size) }
        $freeGb = [int][math]::Round([double]$freeGb); if ($size) { $size = [int][math]::Round([double]$size) }
        $fix = 'Windows slows down when its disk is nearly full, and the Windows 11 upgrade needs about 20 GB.'
        if ($clean.Count) { $fix += ' Can be freed: ' + ($clean -join '; ') + '.' }
        if ([double]$freeGb -lt 10 -or $pct -lt 5) { [void]$out.Add((New-TkFinding 'space' 'High' "Only $freeGb GB free on the Windows disk" "$freeGb GB free of $size GB." $fix 'You')) }
        elseif ([double]$freeGb -lt 25 -or $pct -lt 10) { [void]$out.Add((New-TkFinding 'space' 'Medium' "Only $freeGb GB free on the Windows disk" "$freeGb GB free of $size GB." $fix 'You')) }
        else {
            [void]$good.Add("$freeGb GB free on the disk")
            if ($temp -and [double]$temp -ge 2) { [void]$out.Add((New-TkFinding 'temp' 'Low' "$temp GB of temporary files" "$temp GB of temporary files in Windows and the user profiles." 'Disk Cleanup, or Settings > Storage > Temporary files, clears them. Nothing anyone needs is in there.' 'You')) }
        }
    }

    # Programs that start with Windows.
    $n = & $p 'StartupCount'
    if ($null -ne $n) {
        $names = @(& $p 'StartupNames' | Where-Object { $_ })
        $list = ''; if ($names.Count) { $list = ': ' + (@($names | Select-Object -First 6) -join ', ') + $(if ($names.Count -gt 6) { ', ...' } else { '' }) }
        $fix = 'Each one slows start-up and sign-in and takes memory all day. Turn off the ones nobody needs (updaters, chat and game launchers) in Task Manager > Startup apps; nothing is uninstalled.'
        if ([int]$n -ge 15) { [void]$out.Add((New-TkFinding 'startup' 'High' "$n programs start with Windows" "$n programs start with Windows or the sign-in$list." $fix 'You')) }
        elseif ([int]$n -ge 8) { [void]$out.Add((New-TkFinding 'startup' 'Medium' "$n programs start with Windows" "$n programs start with Windows or the sign-in$list." $fix 'You')) }
        elseif ([int]$n -le 5) { [void]$good.Add("only $n programs start with Windows") }
    }

    # Two antivirus programs at once.
    $av = @(& $p 'Antivirus' | Where-Object { $_ })
    if ($av.Count -ge 2) { [void]$out.Add((New-TkFinding 'antivirus' 'High' "$($av.Count) antivirus programs are on at once" ('Real-time protection is on in: ' + ($av -join ', ') + '.') 'They scan every file more than once, which makes an old PC crawl. Keep one: Windows Security alone protects a business PC well, or keep the one your company pays for.' 'You')) }

    # The Power saver plan.
    if ([string](& $p 'PowerScheme') -eq $script:PowerSaver) { [void]$out.Add((New-TkFinding 'power' 'Medium' 'The Power saver plan is on' 'Windows is set to Power saver.' 'It holds the processor back on purpose. Choose Balanced in Control Panel > Power Options.' 'You')) }

    # A restart that is waiting, or weeks without one.
    $days = & $p 'UptimeDays'
    $restartFix = 'Choose Restart, not Shut down: Windows'' fast start-up keeps the old session when you shut down.'
    if ([bool](& $p 'RebootPending')) { [void]$out.Add((New-TkFinding 'restart' 'Medium' 'A restart is waiting' 'Windows is waiting for a restart to finish installing updates.' "Restart it. $restartFix" 'You')) }
    elseif ($days -and [double]$days -ge 7) {
        $d = [int][math]::Floor([double]$days)
        $imp = 'Low'; if ($d -ge 14) { $imp = 'Medium' }
        [void]$out.Add((New-TkFinding 'restart' $imp "Not restarted for $d days" "Running without a restart for $d days." "Restart it: it clears memory and finishes updates. $restartFix" 'You'))
    }

    # A worn battery (laptops).
    $bat = & $p 'BatteryPct'
    if ($bat -and [int]$bat -lt 60) { [void]$out.Add((New-TkFinding 'battery' 'Medium' 'The battery is worn' "It holds $bat% of the charge it held when new." 'A new battery brings back the hours away from the charger. It does not change speed.' 'Hardware')) }

    # Clean apps.
    $c = & $p 'CleanCount'
    if ($c -and [int]$c -gt 0) {
        $imp = 'Low'; if ([int]$c -ge 15) { $imp = 'Medium' }
        [void]$out.Add((New-TkFinding 'clean-apps' $imp "$c apps Windows added can go" "$c apps on the Clean apps list are on this PC." 'They run and update in the background and take space. Clean apps removes them for every user and keeps them from coming back.' 'StillGood'))
    }

    $rank = @{ High = 0; Medium = 1; Low = 2 }
    $i = 0
    $sorted = @($out | ForEach-Object { [pscustomobject]@{ F = $_; R = $rank[$_.Impact]; I = $i++ } } | Sort-Object R, I | ForEach-Object { $_.F })
    return [pscustomobject]@{ Findings = $sorted; Good = @($good) }
}

function Get-TkSpeedReport {
    # The facts and the findings. Never throws: the speed part must not stop a check.
    param($Inventory, [int]$CleanCount = 0)
    try { $facts = Get-TkSpeedFacts -Inventory $Inventory -CleanCount $CleanCount }
    catch { return [pscustomobject]@{ Findings = @(); Good = @(); Facts = $null; Error = $_.Exception.Message } }
    $r = Get-TkSpeedFindings -Facts $facts
    return [pscustomobject]@{ Findings = @($r.Findings); Good = @($r.Good); Facts = $facts; Error = '' }
}

Export-ModuleMember -Function *
