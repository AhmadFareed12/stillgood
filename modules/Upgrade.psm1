# Upgrade.psm1 - Windows 11 upgrade: config, the image (download, copy or drop folder, always checked against the pinned
# SHA-256), the Setup command line and its exit codes, state for the monitor, and the hand-off to a background task.
Set-StrictMode -Version 2.0

function Get-TkUpgradePaths {
    $root = Join-Path (Get-TkDataRoot) 'upgrade'
    return [pscustomobject]@{
        Root = $root; State = (Join-Path $root 'state.json'); Job = (Join-Path $root 'job.json')
        Download = (Join-Path $root 'download'); Drop = (Join-Path $root 'drop'); Logs = (Join-Path $root 'setup-logs'); App = (Join-Path $root 'app')
    }
}

$script:LanguageNames = $null

function Get-TkLanguageName {
    # The name Microsoft's download page gives an image language (catalog\languages.json), e.g. he-IL -> Hebrew.
    param([string]$Culture)
    if (-not $script:LanguageNames) {
        $script:LanguageNames = @{}
        $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'catalog\languages.json'
        if (Test-Path -LiteralPath $f) { foreach ($p in (Read-TkJson $f).languages.PSObject.Properties) { $script:LanguageNames[$p.Name] = [string]$p.Value } }
    }
    if ($Culture -and $script:LanguageNames.ContainsKey($Culture)) { return $script:LanguageNames[$Culture] }
    try { return [System.Globalization.CultureInfo]::GetCultureInfo($Culture).EnglishName } catch { return $Culture }
}

function Get-TkUpgradeConfig {
    # upgrade.json lists one image per Windows language under "images" (an in-place upgrade needs an image in the PC's
    # own install language). The older single "source" + "sha256" form still works and is offered to every PC.
    param([Parameter(Mandatory = $true)][string]$Path)
    $c = Read-TkJson $Path
    $images = New-Object System.Collections.ArrayList
    $check = {
        param($label, $src, $sha)
        $sha = ([string]$sha).Trim().ToUpperInvariant()
        if (-not $src) { throw "$Path`: the $label image has no 'source' (where to get it)." }
        if ($sha -notmatch '^[0-9A-F]{64}$') { throw "$Path`: the $label image needs its SHA-256 (64 hex characters) from Microsoft's download page." }
        return $sha
    }
    $im = Get-TkProp $c 'images'
    if ($im) {
        foreach ($p in $im.PSObject.Properties) {
            $sha = & $check $p.Name (Get-TkProp $p.Value 'source') (Get-TkProp $p.Value 'sha256')
            [void]$images.Add([pscustomobject]@{ Culture = $p.Name; Source = [string](Get-TkProp $p.Value 'source'); Sha256 = $sha })
        }
    }
    if (Get-TkProp $c 'source') {
        $sha = & $check 'single' (Get-TkProp $c 'source') (Get-TkProp $c 'sha256')
        [void]$images.Add([pscustomobject]@{ Culture = '*'; Source = [string](Get-TkProp $c 'source'); Sha256 = $sha })
    }
    if (-not $images.Count) { throw "$Path lists no Windows 11 image. Add one under ""images"", keyed by Windows language (for example en-US)." }
    $du = Get-TkProp $c 'dynamicUpdate'; if ($null -eq $du) { $du = $true }
    $stall = Get-TkProp $c 'stallMinutes'; if (-not $stall) { $stall = 10 }
    $wait = Get-TkProp $c 'dropFolderWaitHours'; if (-not $wait) { $wait = 24 }
    return [pscustomobject]@{ Images = @($images); DynamicUpdate = [bool]$du; StallMinutes = [int]$stall; DropFolderWaitHours = [double]$wait }
}

function Resolve-TkUpgradeImage {
    # Picks the image for a PC by the language Windows was installed in: the exact language first, then the only image
    # of the same base language (Arabic, German ...; never across English, French, Spanish, Portuguese or Chinese
    # variants, which are separate images), then a single any-language image. Otherwise it refuses, naming the image.
    param([Parameter(Mandatory = $true)]$Config, [string]$Culture)
    $imgs = @($Config.Images)
    $hit = @($imgs | Where-Object { $_.Culture -eq $Culture } | Select-Object -First 1)
    if (-not $hit.Count -and $Culture) {
        $base = ($Culture -split '-')[0]
        if (@('en', 'fr', 'es', 'pt', 'zh') -notcontains $base) {
            $same = @($imgs | Where-Object { $_.Culture -ne '*' -and ($_.Culture -split '-')[0] -eq $base })
            if ($same.Count -eq 1) { $hit = $same }
        }
    }
    $any = $false
    if (-not $hit.Count) { $hit = @($imgs | Where-Object { $_.Culture -eq '*' } | Select-Object -First 1); $any = [bool]$hit.Count }
    $name = Get-TkLanguageName $Culture
    if (-not $hit.Count) {
        $have = (@($imgs | ForEach-Object { "$(Get-TkLanguageName $_.Culture) ($($_.Culture))" }) -join ', ')
        throw "This PC's Windows is $name ($Culture), and the upgrade settings have no image in that language (they have: $have). Download the '$name' image from Microsoft's Windows 11 page and add it under images.$Culture."
    }
    $img = $hit[0]
    return [pscustomobject]@{
        Culture = $Culture; LanguageName = $name; AnyLanguage = $any; Source = $img.Source; Sha256 = $img.Sha256
        DynamicUpdate = $Config.DynamicUpdate; StallMinutes = $Config.StallMinutes; DropFolderWaitHours = $Config.DropFolderWaitHours
    }
}

function Get-TkSetupArguments {
    # Pure: the Windows Setup command line. Documented switches, plus /product server only when the admin chose the
    # unsupported-hardware option (it makes Setup skip Microsoft's hardware check).
    param([ValidateSet('Scan', 'Upgrade')][string]$Mode, [bool]$DynamicUpdate = $true, [bool]$AllowUnsupported = $false, [bool]$NoRestart = $false, [string]$LogDir)
    $a = New-Object System.Collections.ArrayList
    [void]$a.AddRange(@('/auto', 'upgrade', '/quiet', '/eula', 'accept'))
    if ($Mode -eq 'Scan') { [void]$a.AddRange(@('/compat', 'scanonly', '/noreboot')) }
    else {
        [void]$a.AddRange(@('/compat', 'ignorewarning', '/migratedrivers', 'all', '/showoobe', 'none'))
        if ($NoRestart) { [void]$a.Add('/noreboot') }
    }
    $du = 'enable'; if (-not $DynamicUpdate) { $du = 'disable' }
    [void]$a.AddRange(@('/dynamicupdate', $du, '/telemetry', 'disable'))
    if ($LogDir) { [void]$a.AddRange(@('/copylogs', $LogDir)) }
    if ($AllowUnsupported) { [void]$a.AddRange(@('/product', 'server')) }
    return @($a)
}

function Resolve-TkSetupExitCode {
    # Pure: what Windows Setup's exit code means.
    param([int64]$Code, [ValidateSet('Scan', 'Upgrade')][string]$Mode = 'Scan')
    $hex = '0x{0:X8}' -f [uint32]($Code -band [int64]4294967295)
    $map = @{
        '0xC1900210' = @('Compatible', 'No compatibility issues found.')
        '0xC1900208' = @('AppBlock', 'An installed app blocks the upgrade. Its name is in the compatibility log (CompatData*.xml).')
        '0xC1900204' = @('MigrationBlock', 'This image cannot keep the files and apps on this PC. Check its edition, language and architecture.')
        '0xC1900200' = @('HardwareBlock', 'This PC does not meet Windows 11''s hardware requirements.')
        '0xC190020E' = @('DiskSpace', 'Not enough free disk space.')
        '0xC1900101' = @('DriverError', 'A driver made Setup roll back.')
    }
    if ($Code -eq 0) {
        if ($Mode -eq 'Scan') { return [pscustomobject]@{ Code = $hex; Result = 'Compatible'; Meaning = 'No compatibility issues found.' } }
        return [pscustomobject]@{ Code = $hex; Result = 'Success'; Meaning = 'Setup finished its first part. A restart completes the upgrade.' }
    }
    if ($map.ContainsKey($hex)) { return [pscustomobject]@{ Code = $hex; Result = $map[$hex][0]; Meaning = $map[$hex][1] } }
    return [pscustomobject]@{ Code = $hex; Result = 'Failed'; Meaning = "Setup stopped with code $hex. The Setup logs have the details." }
}

function Get-TkEta {
    # Pure: progress from measurements. No estimate until there is enough to measure.
    param([double]$Done, [double]$Total, [double]$ElapsedSec)
    if ($Total -le 0 -or $Done -le 0 -or $ElapsedSec -lt 5) { return [pscustomobject]@{ Percent = $null; RateMBs = $null; EtaSec = $null } }
    $rate = $Done / $ElapsedSec
    return [pscustomobject]@{
        Percent = [math]::Round(100 * $Done / $Total, 1); RateMBs = [math]::Round($rate / 1MB, 1)
        EtaSec = [int][math]::Ceiling(($Total - $Done) / $rate)
    }
}

function Format-TkDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "$Seconds s" }
    $m = [int][math]::Floor($Seconds / 60)
    if ($m -lt 60) { return "$m min" }
    return ('{0} h {1} min' -f [math]::Floor($m / 60), ($m % 60))
}

function Format-TkProgress {
    param([string]$Verb, [double]$Done, [double]$Total, $Eta)
    $s = '{0}: {1:N1} GB' -f $Verb, ($Done / 1GB)
    if ($Total -gt 0) { $s += (' of {0:N1} GB' -f ($Total / 1GB)) }
    if ($Eta -and $null -ne $Eta.Percent) { $s += " ($($Eta.Percent)%, $($Eta.RateMBs) MB/s, about $(Format-TkDuration $Eta.EtaSec) left)" }
    return $s
}

function Get-TkSha256 {
    # SHA-256 of a file, reporting measured progress to -OnProgress (done, total, elapsed seconds) about once a second.
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$OnProgress)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        $total = $fs.Length; $buf = New-Object byte[] (4MB); $done = [int64]0; $start = Get-Date; $tick = $start
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0); $done += $n
            if ($OnProgress -and ((Get-Date) - $tick).TotalSeconds -ge 1) { & $OnProgress $done $total ((Get-Date) - $start).TotalSeconds; $tick = Get-Date }
        }
        [void]$sha.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($sha.Hash) -replace '-', '')
    } finally { $fs.Close(); $sha.Dispose() }
}

function Write-TkUpgradeState {
    # The one place the monitor reads. Written atomically; the stage history keeps when each stage began.
    param([Parameter(Mandatory = $true)][string]$Stage, [string]$Message, [hashtable]$Extra, [switch]$Quiet)
    $paths = Get-TkUpgradePaths
    New-Item -ItemType Directory -Path $paths.Root -Force | Out-Null
    $old = Read-TkUpgradeState
    $history = @(); $prev = $null
    if ($old) { $history = @(@(Get-TkProp $old 'History') | Where-Object { $_ }); $prev = Get-TkProp $old 'Stage' }
    if ($Stage -ne $prev) { $history += [pscustomobject]@{ Stage = $Stage; At = (Get-Date).ToString('s') } }
    $o = [ordered]@{ Stage = $Stage; Message = $Message; Updated = (Get-Date).ToString('s'); History = @($history) }
    if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
    $tmp = "$($paths.State).tmp"
    Save-TkJson ([pscustomobject]$o) $tmp
    Move-Item -LiteralPath $tmp -Destination $paths.State -Force
    if (-not $Quiet) {
        $level = 'Info'
        if ($Stage -eq 'Failed' -or $Stage -eq 'RolledBack') { $level = 'Error' } elseif ($Stage -eq 'Done') { $level = 'Ok' }
        Write-TkLog "[$Stage] $Message" $level
    }
}

function Read-TkUpgradeState {
    $p = (Get-TkUpgradePaths).State
    for ($i = 0; $i -lt 3; $i++) {
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        try { return (Read-TkJson $p) } catch { Start-Sleep -Milliseconds 200 }
    }
    return $null
}

function Test-TkImageHash {
    # Checks an image against the pinned SHA-256, with measured progress in the state file.
    param([string]$Path, [string]$Sha256)
    Write-TkUpgradeState 'Verifying' "Checking the image against the pinned SHA-256: $Path"
    $t = @{ Last = [datetime]::MinValue }
    $onProgress = {
        param($done, $total, $elapsed)
        if (((Get-Date) - $t.Last).TotalSeconds -lt 5) { return }
        $eta = Get-TkEta $done $total $elapsed
        Write-TkUpgradeState 'Verifying' (Format-TkProgress 'Checking' $done $total $eta) @{ Progress = $eta } -Quiet
        $t.Last = Get-Date
    }.GetNewClosure()
    $hash = Get-TkSha256 -Path $Path -OnProgress $onProgress
    $ok = ($hash -eq $Sha256)
    if ($ok) { Write-TkLog 'The image matches the pinned SHA-256.' 'Ok' } else { Write-TkLog "The image does not match the pinned SHA-256 (got $hash)." 'Warn' }
    return $ok
}

function Initialize-TkDropFolder {
    param([string]$Folder, [string]$Sha256, [string]$Language)
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $which = 'the Windows 11 image (.iso)'
    if ($Language) { $which = "the $Language Windows 11 image (.iso), the language this PC's Windows was installed in" }
    $text = @(
        "Put $which in this folder.", '',
        "It must be Microsoft's image with this SHA-256: $Sha256",
        "Microsoft's Windows 11 download page lists the SHA-256 of each language's image under 'Verify your download'.", '',
        'Any file name works. The upgrade continues on its own within a minute or two of the file arriving.',
        'Images that do not match are ignored and left where they are.'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $Folder 'READ ME.txt') -Value $text -Encoding UTF8
}

function Find-TkDroppedImage {
    # One pass over the drop folder. Returns an image that matches the pinned SHA-256, or $null.
    # A file is checked only once its size and time stop changing between passes (it is not still being copied).
    param([string]$Folder, [string]$Sha256, [hashtable]$Seen)
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
        $sig = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        if (-not $Seen.ContainsKey($f.FullName)) { $Seen[$f.FullName] = @{ Sig = $sig; State = 'new' }; continue }
        $s = $Seen[$f.FullName]
        if ($s.Sig -ne $sig) { $s.Sig = $sig; $s.State = 'new'; continue }
        if ($s.State -eq 'bad') { continue }
        try { $h = Get-TkSha256 -Path $f.FullName } catch { continue }   # still locked by the copy: next pass
        if ($h -eq $Sha256) { return $f.FullName }
        $s.State = 'bad'
        Write-TkLog "$($f.Name) in the drop folder does not match the pinned SHA-256 - ignored." 'Warn'
    }
    return $null
}

function Wait-TkDroppedImage {
    param([string]$Folder, [string]$Sha256, [double]$Hours, [int]$PollSeconds = 30)
    $seen = @{}
    $deadline = (Invoke-TkSys 'Now').AddHours($Hours)
    while ((Invoke-TkSys 'Now') -lt $deadline) {
        $hit = Find-TkDroppedImage -Folder $Folder -Sha256 $Sha256 -Seen $seen
        if ($hit) { return $hit }
        Invoke-TkSys 'Sleep' @($PollSeconds)
    }
    return $null
}

function Get-TkImage {
    # Returns a verified Windows 11 image: one kept from an earlier attempt, a fresh download or copy, or the drop folder.
    param([Parameter(Mandatory = $true)]$Config)
    $paths = Get-TkUpgradePaths
    $dest = Join-Path $paths.Download 'windows11.iso'
    if (Test-Path -LiteralPath $dest) {
        if (Test-TkImageHash -Path $dest -Sha256 $Config.Sha256) { return $dest }
        Remove-Item -LiteralPath $dest -Force
    }
    Write-TkUpgradeState 'Downloading' "Getting the image from $($Config.Source)"
    $t = @{ Start = (Get-Date); Last = [datetime]::MinValue }
    $onProgress = {
        param($done, $total)
        if (((Get-Date) - $t.Last).TotalSeconds -lt 5) { return }
        $eta = Get-TkEta $done $total ((Get-Date) - $t.Start).TotalSeconds
        Write-TkUpgradeState 'Downloading' (Format-TkProgress 'Downloading' $done $total $eta) @{ Progress = $eta } -Quiet
        $t.Last = Get-Date
    }.GetNewClosure()
    $r = Invoke-TkSys 'Download' @($Config.Source, $dest, $onProgress, ($Config.StallMinutes * 60))
    if ($r.Ok) {
        if (Test-TkImageHash -Path $dest -Sha256 $Config.Sha256) { return $dest }
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        Write-TkLog 'The downloaded image was deleted because it does not match.' 'Warn'
    } else { Write-TkLog "The download did not finish: $($r.Error)" 'Warn' }

    Initialize-TkDropFolder -Folder $paths.Drop -Sha256 $Config.Sha256 -Language ([string](Get-TkProp $Config 'LanguageName'))
    Write-TkUpgradeState 'WaitingForImage' "The download did not finish. Copy the Windows 11 image into $($paths.Drop) - the READ ME there says which one." @{ DropFolder = $paths.Drop }
    return (Wait-TkDroppedImage -Folder $paths.Drop -Sha256 $Config.Sha256 -Hours $Config.DropFolderWaitHours)
}

function Copy-TkAppFiles {
    # The background task runs from a local copy, so it never depends on a USB stick or a network share.
    param([string]$Destination)
    $src = Split-Path -Parent $PSScriptRoot
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($d in @('modules', 'catalog', 'worker')) { Copy-Item -LiteralPath (Join-Path $src $d) -Destination $Destination -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $src 'StillGood.ps1') -Destination $Destination -Force -ErrorAction SilentlyContinue
}

function Start-TkUpgrade {
    # Writes the job, copies the toolkit locally and starts the background task. Returns at once; the monitor shows progress.
    param([Parameter(Mandatory = $true)]$Config, [bool]$AllowUnsupported, [bool]$NoRestart, [bool]$CleanAfter, [string]$Profile = 'office', [string]$OrganizationPath)
    $paths = Get-TkUpgradePaths
    $state = Read-TkUpgradeState
    if ($state -and @('Queued', 'Preparing', 'Downloading', 'WaitingForImage', 'Verifying', 'Scanning', 'Upgrading', 'Restarting') -contains $state.Stage) {
        throw "An upgrade is already in progress on this PC (stage: $($state.Stage)). Watch it with -Mode Monitor."
    }
    $app = Join-Path $paths.App (Get-TkProduct).Version
    Copy-TkAppFiles -Destination $app
    $org = $null
    if ($OrganizationPath) { $org = Join-Path $app 'catalog\organization.json'; Copy-Item -LiteralPath $OrganizationPath -Destination $org -Force }
    $job = [pscustomobject]@{
        Created = (Get-Date).ToString('s'); StartBuild = (Invoke-TkSys 'GetOs').Build; Config = $Config
        AllowUnsupported = $AllowUnsupported; NoRestart = $NoRestart; CleanAfter = $CleanAfter; Profile = $Profile; Organization = $org; AppDir = $app
    }
    Save-TkJson $job $paths.Job
    Write-TkUpgradeState 'Queued' 'The upgrade task is starting in the background.' @{ Progress = $null }
    Invoke-TkSys 'RegisterTask' @('Upgrade', (Join-Path $app 'worker\Upgrade-Worker.ps1'), "-Job `"$($paths.Job)`"", 'Now', 12)
    return $paths
}

Export-ModuleMember -Function *
