param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Mode -eq 'Diagnose') {
    Write-Output 'Add read-only diagnosis here.'
    return
}

Write-Output 'Add a bounded, reversible repair here.'
