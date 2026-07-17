param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DdpmInstallation {
    $roots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            $_.DisplayName -eq 'Dell Display and Peripheral Manager'
        } |
        Select-Object -First 1
}

function Get-TailLines([string]$Path, [int]$Count = 5000) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($queue.Count -ge $Count) { [void]$queue.Dequeue() }
            $queue.Enqueue($line)
        }
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    @($queue.ToArray())
}

function Get-LatestLog([string]$RelativeRoot, [string]$Filter) {
    $root = Join-Path $env:LOCALAPPDATA $RelativeRoot
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-LogTimestamp([string]$Line) {
    $match = [regex]::Match($Line, '^(?<time>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}\.\d{3})')
    if (-not $match.Success) { return [datetime]::MinValue }
    try {
        [datetime]::ParseExact(
            $match.Groups['time'].Value,
            'yyyy.MM.dd HH:mm:ss.fff',
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        [datetime]::MinValue
    }
}

function Get-BackendStatus([datetime]$After = [datetime]::MinValue) {
    $log = Get-LatestLog 'Dell\Dell Display and Peripheral Manager\Log\DDPM.Subagent.User' '*.log'
    if (-not $log) {
        return [PSCustomObject]@{ Count = 0; Names = @(); Log = $null }
    }
    $lines = Get-TailLines $log.FullName 6000
    $count = 0
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in $lines) {
        if ($After -gt [datetime]::MinValue) {
            $lineTime = Get-LogTimestamp $line
            if ($lineTime -eq [datetime]::MinValue -or $lineTime -lt $After) { continue }
        }
        $match = [regex]::Match($line, 'AllInfoMonitors count is (?<count>\d+)')
        if ($match.Success) { $count = [int]$match.Groups['count'].Value }
        $match = [regex]::Match($line, 'Initialize2TypesMonitorInfo finish\s*:\s*count\s*=>\s*(?<count>\d+)')
        if ($match.Success) { $count = [int]$match.Groups['count'].Value }

        $match = [regex]::Match($line, 'Show\*+\s+AliasDeviceName\s*:\s*(?<name>Dell .*?)<--->')
        if ($match.Success) { [void]$names.Add($match.Groups['name'].Value.Trim()) }
        $match = [regex]::Match($line, 'TargetMonitor AliasDeviceName is (?<name>Dell .+?)(?:,\s*Caller Name:|$)')
        if ($match.Success) { [void]$names.Add($match.Groups['name'].Value.Trim()) }
    }
    [PSCustomObject]@{ Count = $count; Names = @($names | Sort-Object); Log = $log.FullName }
}

function Wait-ForBackendStatus([datetime]$After, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $status = Get-BackendStatus $After
    while ((Get-Date) -lt $deadline) {
        $status = Get-BackendStatus $After
        if ($status.Count -gt 0) { return $status }
        Start-Sleep -Seconds 1
    }
    $status
}

function Get-GuiStatus([int]$ProcessId) {
    $log = Get-LatestLog 'Dell\Dell Display and Peripheral Manager\Log\DDPM.GUI' 'DDPMConsole.log'
    if (-not $log) {
        return [PSCustomObject]@{ MonitorCount = 0; WaitCount = 0; AccessDenied = 0; Unelevated = 0; Log = $null }
    }
    $tag = '[{0}]' -f $ProcessId
    $monitorCount = 0
    $waitCount = 0
    $accessDenied = 0
    $unelevated = 0
    foreach ($line in (Get-TailLines $log.FullName 8000)) {
        if (-not $line.Contains($tag)) { continue }
        if ($line -match 'Wait_DevMgr') { $waitCount++ }
        if ($line -match 'Access is denied|access is denied|\u30a2\u30af\u30bb\u30b9\u304c\u62d2\u5426') { $accessDenied++ }
        if ($line -match 'running unelevated') { $unelevated++ }
        foreach ($pattern in @(
            'Monitor count is (?<count>\d+)',
            '_monitorInfos\.Count=(?<count>\d+)',
            'current HomeDevice Count\s*=\s*(?<count>\d+)'
        )) {
            $match = [regex]::Match($line, $pattern)
            if ($match.Success) {
                $candidate = [int]$match.Groups['count'].Value
                if ($candidate -gt $monitorCount) { $monitorCount = $candidate }
            }
        }
    }
    [PSCustomObject]@{
        MonitorCount = $monitorCount
        WaitCount = $waitCount
        AccessDenied = $accessDenied
        Unelevated = $unelevated
        Log = $log.FullName
    }
}

function Get-ConnectedDellMonitors {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'pnputil.exe'
    $startInfo.Arguments = '/enum-devices /class Monitor /connected'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch {}
            Write-Warning 'PnP monitor query timed out after 15 seconds.'
            return @()
        }
        $process.WaitForExit()
        $names = New-Object 'System.Collections.Generic.HashSet[string]'
        $output = $outputTask.Result + [Environment]::NewLine + $errorTask.Result
        foreach ($match in [regex]::Matches(
            $output,
            'Dell\s+(?:AW|SE|S|U|P|E|C|G)\d+[A-Z0-9-]*(?:\s+\([^)]*\))?',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )) {
            [void]$names.Add($match.Value.Trim())
        }
        @($names | Sort-Object)
    } finally {
        $process.Dispose()
    }
}

function Wait-ForDdpmProcess([datetime]$After, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Name DDPM -ErrorAction SilentlyContinue |
            Where-Object { $_.StartTime -ge $After } |
            Sort-Object StartTime -Descending |
            Select-Object -First 1
        if ($process) { return $process }
        Start-Sleep -Milliseconds 500
    }
    $null
}

function Wait-ForGuiMonitors([int]$ProcessId, [int]$ExpectedCount, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    $status = Get-GuiStatus $ProcessId
    while ((Get-Date) -lt $deadline) {
        $status = Get-GuiStatus $ProcessId
        if ($status.MonitorCount -gt 0 -and ($ExpectedCount -le 0 -or $status.MonitorCount -ge $ExpectedCount)) {
            return $status
        }
        Start-Sleep -Seconds 1
    }
    $status
}

function Stop-DdpmProcesses {
    foreach ($name in @('DDPM', 'DDPM.Subagent.User', 'DPM', 'DPMCrashHandler')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -ne 0 } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
}

function Restart-DdpmServices {
    $dpmService = Get-Service -Name DPMService -ErrorAction SilentlyContinue
    $techHub = Get-Service -Name DellTechHub -ErrorAction SilentlyContinue
    if (-not $dpmService) { throw 'DPMService is not installed.' }
    if (-not $techHub) { throw 'DellTechHub service is not installed.' }

    if ($dpmService.Status -ne 'Stopped') { Stop-Service -Name DPMService -Force }
    if ($techHub.Status -ne 'Stopped') { Stop-Service -Name DellTechHub -Force }
    Start-Sleep -Seconds 1
    Start-Service -Name DellTechHub
    Start-Service -Name DPMService
    (Get-Service -Name DellTechHub).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    (Get-Service -Name DPMService).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
}

function Write-Diagnosis {
    $installation = Get-DdpmInstallation
    if (-not $installation) { throw 'Dell Display and Peripheral Manager is not installed.' }
    $exe = Join-Path $installation.InstallLocation 'DDPM.exe'
    $monitors = @(Get-ConnectedDellMonitors)
    $backend = Get-BackendStatus
    $process = Get-Process -Name DDPM -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending | Select-Object -First 1

    Write-Output ('Installed version : {0}' -f $installation.DisplayVersion)
    Write-Output ('Executable        : {0}' -f $exe)
    Write-Output ('Dell PnP monitors : {0}' -f $monitors.Count)
    foreach ($monitor in $monitors) { Write-Output ('  - {0}' -f $monitor) }
    Write-Output ('Backend monitors  : {0}' -f $backend.Count)
    foreach ($name in $backend.Names) { Write-Output ('  - {0}' -f $name) }
    foreach ($serviceName in @('DellTechHub', 'DPMService')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        Write-Output ('Service {0,-12}: {1}' -f $serviceName, $(if ($service) { $service.Status } else { 'Missing' }))
    }

    if (-not $process) {
        Write-Output 'GUI               : Not running'
        Write-Output 'Diagnosis         : NOT_RUNNING'
        return
    }
    $gui = Get-GuiStatus $process.Id
    Write-Output ('GUI PID           : {0}' -f $process.Id)
    Write-Output ('GUI monitor count : {0}' -f $gui.MonitorCount)
    Write-Output ('Connecting waits  : {0}' -f $gui.WaitCount)
    Write-Output ('Access denied     : {0}' -f $gui.AccessDenied)
    if ($backend.Count -gt 0 -and $gui.MonitorCount -lt $backend.Count) {
        Write-Output 'Diagnosis         : UI_TO_SUBAGENT_CONNECTION_FAILURE'
    } else {
        Write-Output 'Diagnosis         : HEALTHY'
    }
}

if ($Mode -eq 'Diagnose') {
    Write-Diagnosis
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'DDPM repair requires administrator rights.'
}

$installation = Get-DdpmInstallation
if (-not $installation) { throw 'Dell Display and Peripheral Manager is not installed.' }
$exe = Join-Path $installation.InstallLocation 'DDPM.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw ('DDPM executable not found: {0}' -f $exe) }

Write-Output ('Keeping installed version: {0}' -f $installation.DisplayVersion)
Write-Output 'Stopping stale DDPM user processes...'
Stop-DdpmProcesses
Write-Output 'Restarting DellTechHub and DPMService...'
$restartStarted = Get-Date
Restart-DdpmServices

Write-Output 'Waiting for a fresh DDPM backend registration...'
$backend = Wait-ForBackendStatus $restartStarted 70
if ($backend.Count -le 0) {
    throw 'DDPM backend did not publish a fresh monitor list within 70 seconds.'
}
Write-Output ('Backend monitor count after restart: {0}' -f $backend.Count)
foreach ($name in $backend.Names) { Write-Output ('  - {0}' -f $name) }

Write-Output 'Trying normal user-session launch...'
$normalStarted = Get-Date
Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $exe)
$normal = Wait-ForDdpmProcess $normalStarted 12
if ($normal) {
    $normalStatus = Wait-ForGuiMonitors $normal.Id $backend.Count 25
    if ($normalStatus.MonitorCount -gt 0 -and ($backend.Count -le 0 -or $normalStatus.MonitorCount -ge $backend.Count)) {
        Write-Output ('Recovered with normal launch. GUI monitors: {0}' -f $normalStatus.MonitorCount)
        return
    }
    Write-Output ('Normal launch did not connect. waits={0}, accessDenied={1}, guiMonitors={2}' -f
        $normalStatus.WaitCount, $normalStatus.AccessDenied, $normalStatus.MonitorCount)
}

Write-Output 'Falling back to an elevated launch for this session only...'
Get-Process -Name DDPM -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
$elevated = Start-Process -FilePath $exe -PassThru
$elevatedStatus = Wait-ForGuiMonitors $elevated.Id $backend.Count 45
if ($elevatedStatus.MonitorCount -le 0) {
    throw ('DDPM GUI still did not receive monitors. waits={0}, accessDenied={1}' -f
        $elevatedStatus.WaitCount, $elevatedStatus.AccessDenied)
}
if ($backend.Count -gt 0 -and $elevatedStatus.MonitorCount -lt $backend.Count) {
    throw ('DDPM GUI received only {0} of {1} backend monitors.' -f
        $elevatedStatus.MonitorCount, $backend.Count)
}
Write-Output ('Recovered with elevated launch for this session. GUI monitors: {0}' -f $elevatedStatus.MonitorCount)
Write-Output 'No application update or persistent RUNASADMIN setting was applied.'
