# Runs as SYSTEM in a scheduled task started by StillGood.ps1 -Mode Upgrade. Signing out does not stop it.
# Progress goes to the state file that StillGood.ps1 -Mode Monitor reads.
param([Parameter(Mandatory = $true)][string]$Job)
$ErrorActionPreference = 'Stop'
$env:TK_QUIET = '1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\_load.ps1')
$null = New-TkRun -Name 'upgrade'
$result = Invoke-TkUpgradeJob -JobPath $Job
Write-TkLog "Upgrade job ended: $result"
if ($result -eq 'Failed') { exit 1 }
exit 0
