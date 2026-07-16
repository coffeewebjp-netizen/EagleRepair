param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repairScript = Join-Path $root 'tools\eagle-library-repair.ps1'
if (-not (Test-Path -LiteralPath $repairScript)) {
    throw ('Eagle repair script not found: {0}' -f $repairScript)
}

if ($Mode -eq 'Diagnose') {
    & $repairScript
} else {
    & $repairScript -Repair -RestartDriveFS
}
