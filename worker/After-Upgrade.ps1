# Runs as SYSTEM at each sign-in until the upgrade is confirmed (or found rolled back), then removes itself.
# A sign-in on the newer build is the proof the upgrade worked; only then is the downloaded image deleted.
param([Parameter(Mandatory = $true)][string]$Job)
$ErrorActionPreference = 'Stop'
$env:TK_QUIET = '1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\_load.ps1')
$null = New-TkRun -Name 'after-upgrade'
$result = Invoke-TkAfterUpgrade -JobPath $Job
Write-TkLog "After-upgrade check: $result"
exit 0
