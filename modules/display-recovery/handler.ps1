param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'module.psd1')
$settings = $manifest.Settings
$targetMonitorPattern = [string]$settings.TargetMonitorPattern
$expectedActiveDisplays = [int]$settings.ExpectedActiveDisplays

if (-not ('CoffeeWeb.DisplayTopology' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CoffeeWeb
{
    public sealed class ActiveDisplay
    {
        public string DeviceName { get; set; }
        public bool Primary { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
        public int X { get; set; }
        public int Y { get; set; }
    }

    public static class DisplayTopology
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct MonitorInfoEx
        {
            public int Size;
            public Rect Monitor;
            public Rect Work;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string DeviceName;
        }

        private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll")]
        private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);

        public static ActiveDisplay[] GetActiveDisplays()
        {
            var displays = new List<ActiveDisplay>();
            MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data)
            {
                var info = new MonitorInfoEx();
                info.Size = Marshal.SizeOf(typeof(MonitorInfoEx));
                if (GetMonitorInfo(monitor, ref info))
                {
                    displays.Add(new ActiveDisplay
                    {
                        DeviceName = info.DeviceName,
                        Primary = (info.Flags & 1) != 0,
                        Width = info.Monitor.Right - info.Monitor.Left,
                        Height = info.Monitor.Bottom - info.Monitor.Top,
                        X = info.Monitor.Left,
                        Y = info.Monitor.Top
                    });
                }
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return displays.ToArray();
        }
    }
}
'@
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ProcessWithTimeout(
    [string]$FilePath,
    [string]$Arguments,
    [int]$TimeoutSeconds = 20
) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
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
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            return [PSCustomObject]@{
                ExitCode = 124
                Output = ''
                Error = ('Timed out after {0} seconds.' -f $TimeoutSeconds)
                TimedOut = $true
            }
        }
        $process.WaitForExit()
        [PSCustomObject]@{
            ExitCode = $process.ExitCode
            Output = $outputTask.Result
            Error = $errorTask.Result
            TimedOut = $false
        }
    } finally {
        $process.Dispose()
    }
}

function Get-ActiveDisplays {
    @([CoffeeWeb.DisplayTopology]::GetActiveDisplays() | ForEach-Object {
        [PSCustomObject]@{
            DeviceName = $_.DeviceName
            Primary = $_.Primary
            Width = $_.Width
            Height = $_.Height
            X = $_.X
            Y = $_.Y
        }
    })
}

function Get-ConnectedMonitorState {
    $result = Invoke-ProcessWithTimeout 'pnputil.exe' '/enum-devices /class Monitor /connected' 15
    if ($result.TimedOut) {
        return [PSCustomObject]@{
            Available = $false
            TargetConnected = $false
            Detail = $result.Error
        }
    }
    $text = ($result.Output + [Environment]::NewLine + $result.Error)
    [PSCustomObject]@{
        Available = $result.ExitCode -eq 0
        TargetConnected = $text -match [regex]::Escape($targetMonitorPattern)
        Detail = if ($result.ExitCode -eq 0) { 'PnP query completed.' } else { $text.Trim() }
    }
}

function Write-DisplayState([string]$Label, [object[]]$Screens) {
    Write-Output ('{0}: active displays = {1} / expected = {2}' -f $Label, $Screens.Count, $expectedActiveDisplays)
    foreach ($screen in $Screens) {
        Write-Output ('  {0}: {1}x{2} at {3},{4}{5}' -f
            $screen.DeviceName, $screen.Width, $screen.Height, $screen.X, $screen.Y,
            $(if ($screen.Primary) { ' (primary)' } else { '' }))
    }
}

function Wait-ForExpectedDisplays([int]$Seconds = 8) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $screens = @(Get-ActiveDisplays)
        if ($screens.Count -ge $expectedActiveDisplays) { return $screens }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    @(Get-ActiveDisplays)
}

function Request-DisplayTopology([ValidateSet('extend', 'clone', 'external')][string]$Topology) {
    Write-Host ('Requesting Windows display topology: {0}' -f $Topology)
    $displaySwitch = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
    $result = Invoke-ProcessWithTimeout $displaySwitch ('/{0}' -f $Topology) 15
    if ($result.TimedOut) {
        Write-Warning ('DisplaySwitch /{0} timed out; continuing with bounded recovery.' -f $Topology)
        return
    }
    if ($result.ExitCode -ne 0) {
        Write-Warning ('DisplaySwitch /{0} returned exit code {1}: {2}' -f $Topology, $result.ExitCode, $result.Error.Trim())
    }
}

function Invoke-PnpRescan {
    Write-Host 'Requesting a Windows Plug and Play device rescan...'
    $result = Invoke-ProcessWithTimeout 'pnputil.exe' '/scan-devices' 30
    if ($result.TimedOut) {
        Write-Warning 'PnP rescan timed out after 30 seconds; continuing with display-topology recovery.'
        return $false
    }
    if ($result.ExitCode -ne 0) {
        Write-Warning ('PnP rescan returned exit code {0}: {1}' -f $result.ExitCode, ($result.Output + $result.Error).Trim())
        return $false
    }
    Write-Host 'PnP rescan completed.'
    $true
}

function Invoke-ExtendAttempts([int]$Count, [string]$Stage) {
    for ($attempt = 1; $attempt -le $Count; $attempt++) {
        Write-Host ('{0}: extend attempt {1}/{2}' -f $Stage, $attempt, $Count)
        Request-DisplayTopology extend
        $screens = @(Wait-ForExpectedDisplays 5)
        if ($screens.Count -ge $expectedActiveDisplays) { return $screens }
    }
    @(Get-ActiveDisplays)
}

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

function Restart-DdpmUserSession {
    $installation = Get-DdpmInstallation
    if (-not $installation) {
        Write-Output 'DDPM is not installed; skipping DDPM refresh.'
        return
    }
    $exe = Join-Path $installation.InstallLocation 'DDPM.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Warning ('DDPM executable was not found: {0}' -f $exe)
        return
    }
    Write-Output 'Refreshing the DDPM user session after Windows recovered the display...'
    foreach ($name in @('DDPM', 'DDPM.Subagent.User')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -ne 0 } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    Start-Process -FilePath 'explorer.exe' -ArgumentList ([char]34 + $exe + [char]34)
}

$initialScreens = @(Get-ActiveDisplays)
Write-DisplayState 'Initial state' $initialScreens
$pnpState = Get-ConnectedMonitorState
Write-Output ('Target monitor       : {0}' -f $targetMonitorPattern)
Write-Output ('Target in PnP        : {0}' -f $(if (-not $pnpState.Available) { 'Unknown (' + $pnpState.Detail + ')' } elseif ($pnpState.TargetConnected) { 'Connected' } else { 'Missing' }))

if ($Mode -eq 'Diagnose') {
    if ($initialScreens.Count -ge $expectedActiveDisplays -and $pnpState.TargetConnected) {
        Write-Output 'Diagnosis            : HEALTHY'
    } elseif ($initialScreens.Count -lt $expectedActiveDisplays -and -not $pnpState.TargetConnected) {
        Write-Output 'Diagnosis            : TARGET_MONITOR_MISSING_AFTER_WAKE'
    } else {
        Write-Output 'Diagnosis            : DISPLAY_TOPOLOGY_INCONSISTENT'
    }
    return
}

if ($initialScreens.Count -ge $expectedActiveDisplays -and $pnpState.TargetConnected) {
    Write-Output 'The expected display topology is already active. No recovery action was needed.'
    return
}

Write-Output ''
Write-Output 'Stage 1: request Extend once and verify the live Windows topology.'
$screens = @(Invoke-ExtendAttempts ([int]$settings.ExtendAttemptsBeforeOutputRefresh) 'Initial request')

if ($screens.Count -lt $expectedActiveDisplays) {
    Write-Output ''
    Write-Output 'Stage 2: rebuild NVIDIA external outputs by switching External -> Extend.'
    for ($attempt = 1; $attempt -le [int]$settings.OutputRefreshAttempts; $attempt++) {
        Write-Output ('External-output refresh attempt {0}/{1}. Displays may blink briefly.' -f $attempt, $settings.OutputRefreshAttempts)
        Request-DisplayTopology external
        Start-Sleep -Seconds 3
        Request-DisplayTopology extend
        $screens = @(Wait-ForExpectedDisplays 20)
        if ($screens.Count -ge $expectedActiveDisplays) { break }
    }
}

if ($screens.Count -lt $expectedActiveDisplays) {
    Write-Output ''
    Write-Output 'Stage 3: rescan Plug and Play devices, then request Extend again.'
    if (Test-IsAdministrator) {
        [void](Invoke-PnpRescan)
    } else {
        Write-Output 'PnP rescan requires elevation and was skipped; continuing with user-session display recovery.'
    }
    $screens = @(Invoke-ExtendAttempts ([int]$settings.ExtendAttemptsAfterScan) 'After PnP scan')
}

if ($screens.Count -lt $expectedActiveDisplays) {
    Write-Output ''
    Write-Output 'Stage 4: rebuild the Windows topology by briefly switching Clone -> Extend.'
    for ($attempt = 1; $attempt -le [int]$settings.TopologyRefreshAttempts; $attempt++) {
        Write-Output ('Topology refresh attempt {0}/{1}. Displays may blink briefly.' -f $attempt, $settings.TopologyRefreshAttempts)
        Request-DisplayTopology clone
        Start-Sleep -Seconds 2
        Request-DisplayTopology extend
        $screens = @(Wait-ForExpectedDisplays 7)
        if ($screens.Count -ge $expectedActiveDisplays) { break }
    }
}

Write-Output ''
$finalScreens = @(Get-ActiveDisplays)
Write-DisplayState 'Final state' $finalScreens
$finalPnpState = Get-ConnectedMonitorState
Write-Output ('Target in PnP after recovery: {0}' -f $(if (-not $finalPnpState.Available) { 'Unknown' } elseif ($finalPnpState.TargetConnected) { 'Connected' } else { 'Missing' }))

if ($finalScreens.Count -lt $expectedActiveDisplays) {
    throw ('Recovery stopped safely: only {0} of {1} expected displays are active. The GPU device was not reset or disabled.' -f
        $finalScreens.Count, $expectedActiveDisplays)
}
if ($finalPnpState.Available -and -not $finalPnpState.TargetConnected) {
    throw ('Recovery stopped safely: {0} is not present in the final PnP monitor list.' -f $targetMonitorPattern)
}

Restart-DdpmUserSession
Write-Output ('Recovery verified: {0} active displays and {1} is connected.' -f $finalScreens.Count, $targetMonitorPattern)
