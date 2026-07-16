param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

function Get-TextValue([object]$Data, [string]$Path) {
    $value = $Data
    foreach ($part in $Path.Split('.')) {
        $property = $value.PSObject.Properties[$part]
        if (-not $property) { return $Path }
        $value = $property.Value
    }
    [string]$value
}

$modulesRoot = Join-Path $Root 'modules'
$resourcePath = Join-Path $Root 'resources\ja.json'
if (-not (Test-Path -LiteralPath $modulesRoot)) {
    throw ('Modules directory not found: {0}' -f $modulesRoot)
}
if (-not (Test-Path -LiteralPath $resourcePath)) {
    throw ('Resource file not found: {0}' -f $resourcePath)
}

$resources = [IO.File]::ReadAllText($resourcePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$definitions = New-Object 'System.Collections.Generic.List[object]'

Get-ChildItem -LiteralPath $modulesRoot -Directory | ForEach-Object {
    $manifestPath = Join-Path $_.FullName 'module.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    $data = Import-PowerShellDataFile -LiteralPath $manifestPath
    if (-not $data.Enabled) { return }

    $handlerPath = Join-Path $_.FullName ([string]$data.Handler)
    if (-not (Test-Path -LiteralPath $handlerPath)) {
        throw ('Module handler not found: {0}' -f $handlerPath)
    }

    $definitions.Add([PSCustomObject]@{
        Id = [string]$data.Id
        DisplayName = Get-TextValue $resources ([string]$data.DisplayNameKey)
        Description = Get-TextValue $resources ([string]$data.DescriptionKey)
        SupportsDiagnose = [bool]$data.SupportsDiagnose
        SupportsRepair = [bool]$data.SupportsRepair
        RepairRequiresAdmin = [bool]$data.RepairRequiresAdmin
        Order = [int]$data.Order
    })
}

$duplicateIds = @($definitions | Group-Object Id | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) {
    throw ('Duplicate module ID: {0}' -f (($duplicateIds.Name) -join ', '))
}

$ordered = @($definitions | Sort-Object Order, Id)
ConvertTo-Json -InputObject $ordered -Depth 5 -Compress
