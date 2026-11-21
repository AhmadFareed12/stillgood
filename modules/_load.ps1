# Dot-source this file to load the toolkit's modules in order.
foreach ($tkModule in @('Common', 'Guard', 'System', 'Inventory', 'Compat', 'Catalog', 'Settings', 'Apps', 'Report', 'Upgrade', 'UpgradeJob')) {
    Import-Module (Join-Path $PSScriptRoot "$tkModule.psm1") -Force -DisableNameChecking -Global
}
Remove-Variable tkModule
