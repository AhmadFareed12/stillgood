# Integration-Test.ps1 - the real-Windows test. It removes apps for real (kiosk profile), checks the result, runs again,
# then undoes the settings. It runs only on a throwaway machine:
#   - Windows Sandbox (as SYSTEM):  lab\Invoke-SandboxTest.ps1 -ToolPath <this toolkit> -TestScript tests\Integration-Test.ps1
#   - a lab VM marked C:\Lab.marker (as its signed-in admin):  lab\Invoke-LabTest.ps1 -Vm <vm> -ToolPath ... -TestScript ...
# Anywhere else it refuses.
param([Parameter(Mandatory = $true)][string]$ResultsDir, [string]$Culture = '')
$ErrorActionPreference = 'Continue'
$steps = New-Object System.Collections.ArrayList

function Step {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    [void]$steps.Add([pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail })
    $mark = 'ok'; if (-not $Ok) { $mark = 'FAIL' }
    Add-Content -LiteralPath (Join-Path $ResultsDir 'steps.log') -Value "[$mark] $Name - $Detail"
}
function Finish {
    try { Stop-Transcript | Out-Null } catch { }
    $all = -not @($steps | Where-Object { -not $_.ok }).Count
    [pscustomobject]@{ ok = $all; steps = @($steps); finished = (Get-Date).ToString('s') } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $ResultsDir 'done.json') -Encoding UTF8
    exit 0
}

$inSandbox = Test-Path 'C:\Users\WDAGUtilityAccount'
if (-not $inSandbox -and -not (Test-Path 'C:\Lab.marker')) { Step 'throwaway machine check' $false 'Not Windows Sandbox and not a lab VM - refused.'; Finish }
$userName = 'lab'; if ($inSandbox) { $userName = 'WDAGUtilityAccount' }
Start-Transcript -LiteralPath (Join-Path $ResultsDir 'transcript.txt') | Out-Null

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$setCulture = ''
if ($Culture) {
    # Every StillGood run below starts with this region format (dates, numbers, text comparison), set inside its own
    # process, the way it would run on a PC set up for that country. (Set-Culture for SYSTEM only reaches new
    # sign-ins on a full Windows, so it is not relied on.)
    $setCulture = "[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('$Culture'); "
    $seen = (& $ps -NoProfile -Command ($setCulture + '[System.Globalization.CultureInfo]::CurrentCulture.Name + '' '' + (Get-Date -Format yyyy)') | Out-String).Trim()
    Step 'region format' ($seen -like "$Culture *") "StillGood runs with: $seen (culture and its calendar year)"
}
$work = 'C:\Work\toolkit'
New-Item -ItemType Directory -Path 'C:\Work' -Force | Out-Null
Copy-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Destination $work -Recurse -Force
$tk = Join-Path $work 'StillGood.ps1'
$runs = 'C:\ProgramData\StillGood\runs'

function Invoke-Tk {
    param([string[]]$TkArgs, [string]$Log)
    if ($setCulture) {
        $out = & $ps -NoProfile -ExecutionPolicy Bypass -Command ($setCulture + "& '$tk' $($TkArgs -join ' '); exit `$LASTEXITCODE") 2>&1 | Out-String
    } else {
        $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $tk @TkArgs 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $ResultsDir $Log) -Value $out -Encoding UTF8
    return [pscustomobject]@{ Code = $code; Out = $out }
}
function Get-LatestRun { param([string]$Like) return (Get-ChildItem -LiteralPath $runs -Directory | Where-Object { $_.Name -like $Like } | Sort-Object Name | Select-Object -Last 1) }
function Get-State {
    $all = @(Get-AppxPackage -AllUsers)
    return [pscustomobject]@{
        Appx = @($all | ForEach-Object { $_.Name } | Sort-Object -Unique)
        Frameworks = @($all | Where-Object { $_.IsFramework } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        Provisioned = @(Get-AppxProvisionedPackage -Online | ForEach-Object { $_.DisplayName } | Sort-Object -Unique)
    }
}
$sid = (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | Where-Object { (Get-ItemProperty $_.PSPath).ProfileImagePath -like "*\$userName" } | Select-Object -First 1).PSChildName
$cdm = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
$deprov = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Copilot_8wekyb3d8bbwe'
function Get-RegSnap {
    # The sandbox user may be signed in (hive open under HKU) or not (hive only in NTUSER.DAT): read whichever is true.
    $root = "Registry::HKEY_USERS\$sid"; $mounted = $false
    if (-not (Test-Path -LiteralPath $root)) {
        $null = & reg.exe load 'HKU\SBXUSER' "C:\Users\$userName\NTUSER.DAT" 2>&1
        $root = 'Registry::HKEY_USERS\SBXUSER'; $mounted = $true
    }
    $key = "$root\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    $o = [ordered]@{}
    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled') { $o[$n] = (Get-ItemProperty -LiteralPath $key -Name $n -ErrorAction SilentlyContinue).$n }
    $o['Policy'] = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name DisableWindowsConsumerFeatures -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
    $o['Hive'] = $(if ($mounted) { 'profile file' } else { 'signed in' })
    if ($mounted) {
        for ($i = 0; $i -lt 5; $i++) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $null = & reg.exe unload 'HKU\SBXUSER' 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    return [pscustomobject]$o
}
function Show { param($v) if ($null -eq $v) { return '(none)' }; return [string]$v }

# 1. The offline suite, on a clean Windows.
try {
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'tests\Run-Tests.ps1') 2>&1 | Out-String
    $code = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $ResultsDir '1-unit-tests.txt') -Value $out -Encoding UTF8
    Step 'offline tests' ($code -eq 0) ([regex]::Match($out, '\d+ tests: \d+ passed, \d+ failed').Value)
} catch { Step 'offline tests' $false $_.Exception.Message }

# 2. What is on this Windows before anything changes.
$before = Get-State
$before | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResultsDir '2-before.json') -Encoding UTF8
$regBefore = Get-RegSnap
Step 'inventory before' ($before.Appx.Count -gt 0) ("{0} apps for users, {1} set up for new users" -f $before.Appx.Count, $before.Provisioned.Count)

# 3. The read-only report and its plan.
$plan = $null
try {
    $r = Invoke-Tk @('-Mode', 'Report', '-Profile', 'kiosk') '3-report.txt'
    $rep = Get-LatestRun '*-report-kiosk'
    Copy-Item -LiteralPath (Join-Path $rep.FullName 'report.html') -Destination $ResultsDir
    Copy-Item -LiteralPath (Join-Path $rep.FullName 'report.json') -Destination $ResultsDir
    $plan = (Get-Content -LiteralPath (Join-Path $rep.FullName 'report.json') -Raw | ConvertFrom-Json).Plan
    $c = $plan.Counts
    $greg = (Get-Date).ToString('yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    Step 'file stamps use the Gregorian calendar' ($rep.Name.StartsWith($greg)) "run folder: $($rep.Name)"
    Step 'report (kiosk)' ($r.Code -eq 0) ("exit {0}; plan: {1} to remove, {2} to block, {3} kept, {4} unknown, {5} protected" -f $r.Code, $c.Remove, $c.Block, $c.Keep, $c.Unknown, $c.Protected)
} catch { Step 'report (kiosk)' $false $_.Exception.Message }
if (-not $plan) { Finish }
$toRemove = @($plan.Items | Where-Object { $_.Action -eq 'Remove' } | ForEach-Object { $_.Name })
$mustStay = @($plan.Items | Where-Object { $_.Action -eq 'Protected' -or $_.Action -eq 'Unknown' -or $_.Action -eq 'Keep' } | ForEach-Object { $_.Name })

# 4. Clean apps for real.
$firstUndo = $null
try {
    $r = Invoke-Tk @('-Mode', 'CleanApps', '-Profile', 'kiosk', '-Apply', '-Yes') '4-clean.txt'
    $run = Get-LatestRun '*-clean-apps-kiosk'
    $firstUndo = Join-Path $run.FullName 'undo.json'
    Copy-Item -LiteralPath (Join-Path $run.FullName 'result.json') -Destination (Join-Path $ResultsDir '4-result.json')
    $after = Get-State
    $after | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResultsDir '4-after.json') -Encoding UTF8
    $left = @($toRemove | Where-Object { $after.Appx -contains $_ -or $after.Provisioned -contains $_ })
    $detail = "exit {0}; removed {1} of {2}" -f $r.Code, ($toRemove.Count - $left.Count), $toRemove.Count
    if ($left.Count) { $detail += "; still there: $($left -join ', ')" }
    Step 'clean apps (kiosk)' ($r.Code -eq 0 -and -not $left.Count) $detail
    # Windows removes a shared runtime by itself once the last app using it is gone: list those, fail on anything else.
    $vanished = @($mustStay | Where-Object { $before.Appx -contains $_ -and $after.Appx -notcontains $_ })
    $retired = @($vanished | Where-Object { $before.Frameworks -contains $_ })
    $lost = @($vanished | Where-Object { $before.Frameworks -notcontains $_ })
    $detail = "$($mustStay.Count) apps checked"
    if ($lost.Count) { $detail = "gone: $($lost -join ', ')" }
    if ($retired.Count) { $detail += "; Windows retired $($retired.Count) runtime(s) no app uses any more: $($retired -join ', ')" }
    Step 'kept, unknown and protected apps untouched' (-not $lost.Count) $detail
    # StillGood's own log must show removals of planned apps only.
    $removedLines = @(Select-String -LiteralPath (Join-Path $run.FullName 'run.log') -Pattern 'Removed (\S+) for ' -CaseSensitive | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $offPlan = @($removedLines | Where-Object { $toRemove -notcontains ($_ -split '_')[0] })
    Step 'StillGood removed only what the plan listed' (-not $offPlan.Count) ($(if ($offPlan.Count) { "off plan: $($offPlan -join ', ')" } else { "$($removedLines.Count) removals, all on the plan" }))
    Copy-Item -LiteralPath (Join-Path $run.FullName 'run.log') -Destination (Join-Path $ResultsDir '4-run.log') -ErrorAction SilentlyContinue
    # Diagnostics: every profile Windows knows, every open hive, and where the stay-clean value ended up.
    $diag = New-Object System.Collections.ArrayList
    foreach ($k in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')) { [void]$diag.Add("profile $($k.PSChildName) -> $((Get-ItemProperty $k.PSPath).ProfileImagePath)") }
    foreach ($h in @(Get-ChildItem 'Registry::HKEY_USERS')) {
        $v = (Get-ItemProperty -LiteralPath "Registry::HKEY_USERS\$($h.PSChildName)\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name SilentInstalledAppsEnabled -ErrorAction SilentlyContinue).SilentInstalledAppsEnabled
        [void]$diag.Add("hive HKU\$($h.PSChildName): SilentInstalledAppsEnabled=$(Show $v)")
    }
    [void]$diag.Add("test reads the signed-in user as SID $sid")
    Set-Content -LiteralPath (Join-Path $ResultsDir '4-profiles.txt') -Value $diag -Encoding UTF8
    $reg = Get-RegSnap
    Step 'stay-clean settings applied' ($reg.SilentInstalledAppsEnabled -eq 0 -and $reg.Policy -eq 1) ("user ({0}): SilentInstalledAppsEnabled={1}; consumer-features policy={2}" -f $reg.Hive, (Show $reg.SilentInstalledAppsEnabled), (Show $reg.Policy))
    Step 'Copilot blocked before it arrives' (Test-Path $deprov) 'Deprovisioned marker present'
    $null = & reg.exe load 'HKU\SBXTEST' 'C:\Users\Default\NTUSER.DAT' 2>&1
    $silent = (Get-ItemProperty 'Registry::HKEY_USERS\SBXTEST\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name SilentInstalledAppsEnabled -ErrorAction SilentlyContinue).SilentInstalledAppsEnabled
    $ods = (Get-ItemProperty 'Registry::HKEY_USERS\SBXTEST\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDriveSetup -ErrorAction SilentlyContinue).OneDriveSetup
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $null = & reg.exe unload 'HKU\SBXTEST' 2>&1
    Step 'new users (default profile)' ($silent -eq 0 -and -not $ods) ("SilentInstalledAppsEnabled={0}, OneDrive setup for new users: {1}" -f (Show $silent), $(if ($ods) { 'still there' } else { 'off' }))
} catch { Step 'clean apps (kiosk)' $false $_.Exception.Message }

# 5. Run again: it must find nothing left to do.
try {
    $r = Invoke-Tk @('-Mode', 'CleanApps', '-Profile', 'kiosk', '-Apply', '-Yes') '5-rerun.txt'
    $res = Get-Content -LiteralPath (Join-Path (Get-LatestRun '*-clean-apps-kiosk').FullName 'result.json') -Raw | ConvertFrom-Json
    Step 'second run changes nothing' ($r.Code -eq 0 -and $res.AppsRemoved -eq 0 -and $res.SettingsChanged -eq 0) ("exit {0}; removed {1}, settings changed {2}" -f $r.Code, $res.AppsRemoved, $res.SettingsChanged)
} catch { Step 'second run changes nothing' $false $_.Exception.Message }

# 6. Undo the first run.
try {
    $r = Invoke-Tk @('-Mode', 'Undo', '-UndoFile', $firstUndo, '-Apply', '-Yes') '6-undo.txt'
    $reg = Get-RegSnap
    $same = ($reg.SilentInstalledAppsEnabled -eq $regBefore.SilentInstalledAppsEnabled) -and ($reg.SystemPaneSuggestionsEnabled -eq $regBefore.SystemPaneSuggestionsEnabled) -and ($reg.Policy -eq $regBefore.Policy)
    Step 'undo puts the settings back' ($r.Code -eq 0 -and $same) ("exit {0}; before: {1}/{2}/{3}, after undo: {4}/{5}/{6}" -f $r.Code, (Show $regBefore.SilentInstalledAppsEnabled), (Show $regBefore.SystemPaneSuggestionsEnabled), (Show $regBefore.Policy), (Show $reg.SilentInstalledAppsEnabled), (Show $reg.SystemPaneSuggestionsEnabled), (Show $reg.Policy))
    Step 'undo lifts the blocks' (-not (Test-Path $deprov)) 'Copilot marker removed'
} catch { Step 'undo' $false $_.Exception.Message }

Finish
