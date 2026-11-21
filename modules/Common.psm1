# Common.psm1 - run folders, logging, OS facts, safety guards, small helpers.
# Every run writes a readable log (run.log) and a machine log (events.jsonl) under %ProgramData%\StillGood\runs.
Set-StrictMode -Version 2.0

$script:Run = $null
# The product name lives here only, so naming the toolkit later is a one-line change.
$script:Product = [pscustomobject]@{ Name = 'StillGood'; Version = '0.3.0' }

function Get-TkProduct { return $script:Product }

function Get-TkDataRoot {
    if (Test-TkTestMode) { return (Join-Path ([IO.Path]::GetTempPath()) "$($script:Product.Name)-test") }
    return (Join-Path $env:ProgramData $script:Product.Name)
}

function Get-TkProp {
    # Read a property that may not exist (StrictMode-safe).
    param($Obj, [string]$Name)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

function Test-TkLike {
    param([string]$Value, [string[]]$Patterns)
    if (-not $Value) { return $false }
    foreach ($p in $Patterns) { if ($p -and $Value -like $p) { return $true } }
    return $false
}

function Test-TkTestMode { return ($env:TK_TEST_MODE -eq '1') }

function New-TkRun {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Root)
    if (-not $Root) { $Root = Join-Path (Get-TkDataRoot) 'runs' }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path $Root "$stamp-$Name"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:Run = [pscustomobject]@{
        Name = $Name; Dir = $dir; Started = (Get-Date)
        Log = (Join-Path $dir 'run.log'); Events = (Join-Path $dir 'events.jsonl')
    }
    Write-TkLog -Message "Run started: $Name" -Data @{ dir = $dir }
    return $script:Run
}

function Get-TkRun { return $script:Run }

function Write-TkLog {
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error', 'Ok')][string]$Level = 'Info', [hashtable]$Data)
    $ts = (Get-Date).ToString('s')
    $line = "$ts [$Level] $Message"
    if (-not $env:TK_QUIET) {
        $color = 'Gray'
        if ($Level -eq 'Warn') { $color = 'Yellow' } elseif ($Level -eq 'Error') { $color = 'Red' } elseif ($Level -eq 'Ok') { $color = 'Green' }
        Write-Host $line -ForegroundColor $color
    }
    if ($script:Run) {
        Add-Content -LiteralPath $script:Run.Log -Value $line -Encoding UTF8
        $evt = [ordered]@{ ts = $ts; level = $Level; message = $Message }
        if ($Data) { $evt['data'] = $Data }
        Add-Content -LiteralPath $script:Run.Events -Value (ConvertTo-Json -InputObject $evt -Compress -Depth 6) -Encoding UTF8
    }
}

function Test-TkElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TkOsInfo {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int](Get-TkProp $cv 'CurrentBuild')
    return [pscustomobject]@{
        Caption        = $os.Caption
        Edition        = Get-TkProp $cv 'EditionID'
        Build          = $build
        Ubr            = Get-TkProp $cv 'UBR'
        DisplayVersion = Get-TkProp $cv 'DisplayVersion'
        IsWindows11    = ($build -ge 22000)
        IsServer       = ($os.ProductType -ne 1)
        Is64Bit        = [Environment]::Is64BitOperatingSystem
        Architecture   = $env:PROCESSOR_ARCHITECTURE
    }
}

function Assert-TkWorkstation {
    param($Os)
    if (-not $Os) { $Os = Get-TkOsInfo }
    if ($Os.IsServer) { throw 'This toolkit runs on Windows 10 and 11 workstations only, never on servers.' }
    if (-not $Os.Is64Bit -or $Os.Architecture -ne 'AMD64') { throw 'This toolkit supports 64-bit x64 Windows only, from 64-bit PowerShell.' }
    if ($Os.Build -lt 19041) { throw "Windows build $($Os.Build) is too old: Windows 10 version 2004 (build 19041) or newer is required." }
}

function Save-TkJson {
    param([Parameter(Mandatory = $true)]$InputObject, [Parameter(Mandatory = $true)][string]$Path)
    (ConvertTo-Json -InputObject $InputObject -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-TkJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

Export-ModuleMember -Function *
