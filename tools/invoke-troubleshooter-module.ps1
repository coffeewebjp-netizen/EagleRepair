param(
    [Parameter(Mandatory = $true)]
    [string]$ModuleId,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$moduleDirectory = Join-Path (Join-Path $root 'modules') $ModuleId
$manifestPath = Join-Path $moduleDirectory 'module.psd1'

function Write-RunLog([string]$Message) {
    $line = $Message.TrimEnd("`r", "`n") + [Environment]::NewLine
    [IO.File]::AppendAllText($LogPath, $line, (New-Object Text.UTF8Encoding($false)))
}

$logDirectory = Split-Path -Parent $LogPath
$resultDirectory = Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null
[IO.File]::WriteAllText($LogPath, '', (New-Object Text.UTF8Encoding($false)))

$success = $false
$exitCode = 1
$message = 'Module failed.'
$started = Get-Date

try {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw ('Module manifest not found: {0}' -f $manifestPath)
    }
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    if (-not $manifest.Enabled) { throw ('Module is disabled: {0}' -f $ModuleId) }
    $handlerPath = Join-Path $moduleDirectory ([string]$manifest.Handler)
    if (-not (Test-Path -LiteralPath $handlerPath)) {
        throw ('Module handler not found: {0}' -f $handlerPath)
    }

    Write-RunLog ('TroubleRepair / {0} / {1}' -f $ModuleId, $Mode)
    Write-RunLog ('Started: {0}' -f $started.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-RunLog ('Administrator: {0}' -f ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))
    Write-RunLog ''

    & $handlerPath -Mode $Mode *>&1 |
        Out-String -Stream -Width 240 |
        ForEach-Object {
            if ($_ -ne $null) { Write-RunLog ([string]$_) }
    }
    $success = $true
    $exitCode = 0
    $message = 'Completed successfully.'
    Write-RunLog ''
    Write-RunLog $message
} catch {
    $message = $_.Exception.Message
    Write-RunLog ''
    Write-RunLog ('ERROR: {0}' -f $message)
    if ($_.ScriptStackTrace) { Write-RunLog $_.ScriptStackTrace }
}

$result = [PSCustomObject]@{
    ModuleId = $ModuleId
    Mode = $Mode
    Success = $success
    ExitCode = $exitCode
    Message = $message
    Started = $started.ToString('o')
    Finished = (Get-Date).ToString('o')
    LogPath = $LogPath
}
[IO.File]::WriteAllText(
    $ResultPath,
    ($result | ConvertTo-Json -Depth 5),
    (New-Object Text.UTF8Encoding($false))
)
exit $exitCode
