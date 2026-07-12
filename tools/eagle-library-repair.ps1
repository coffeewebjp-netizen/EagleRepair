param(
    [string]$Library,
    [string]$Cache,
    [switch]$Repair,
    [switch]$RestartDriveFS,
    [int]$ProbeTimeoutSeconds = 20,
    [int]$LoadTimeoutSeconds = 180,
    [int]$MaxQuarantineCandidates = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-Set($Values) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($value in $Values) { [void]$set.Add([string]$value) }
    $set
}

function Get-IdsFromCache([string]$Path) {
    $ids = New-Object 'System.Collections.Generic.List[string]'
    $bad = 0
    $deleted = 0
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::UTF8)) {
            if (-not $line.Trim()) { continue }
            $match = [regex]::Match($line, '\x22id\x22\s*:\s*\x22([^\x22]+)\x22')
            if ($match.Success) { $ids.Add($match.Groups[1].Value) } else { $bad++ }
            if ($line -match '\x22isDeleted\x22\s*:\s*true') { $deleted++ }
        }
    }
    [PSCustomObject]@{ Ids = $ids; Bad = $bad; Deleted = $deleted }
}

function Get-State([string]$LibraryPath, [string]$CachePath) {
    $folders = @(Get-ChildItem -LiteralPath (Join-Path $LibraryPath 'images') -Force -Directory |
        ForEach-Object { $_.Name -replace '\.info$', '' })
    $cacheInfo = Get-IdsFromCache $CachePath
    $folderSet = New-Set $folders
    $cacheSet = New-Set $cacheInfo.Ids
    $mtimeSet = New-Set @()
    $mtimePath = Join-Path $LibraryPath 'mtime.json'
    if (Test-Path -LiteralPath $mtimePath) {
        $mtime = [IO.File]::ReadAllText($mtimePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $mtimeSet = New-Set @($mtime.PSObject.Properties.Name)
    }
    $missing = @($folders | Where-Object { -not $cacheSet.Contains($_) } | Sort-Object)
    [PSCustomObject]@{
        Folders = $folders
        CacheIds = @($cacheInfo.Ids)
        Bad = $cacheInfo.Bad
        Deleted = $cacheInfo.Deleted
        Missing = $missing
        Extra = @($cacheInfo.Ids | Where-Object { -not $folderSet.Contains($_) } | Sort-Object -Unique)
        Orphans = @($missing | Where-Object { -not $mtimeSet.Contains($_) } | Sort-Object)
    }
}

function Test-Readable([string]$LibraryPath, [int]$Seconds) {
    $sample = Get-ChildItem -LiteralPath (Join-Path $LibraryPath 'images') -Force -Directory |
        Sort-Object Name | Select-Object -First 1
    if (-not $sample) { return [PSCustomObject]@{ Ok = $true; Detail = 'empty library' } }
    $path64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sample.FullName))
    $code = '$p=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(''' + $path64 +
        ''')); $f=@(Get-ChildItem -LiteralPath $p -Force -File -ErrorAction Stop); ' +
        'if($f.Count -ge 2 -and $f.Name -contains ''metadata.json''){exit 0}else{exit 3}'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded
    ) -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($Seconds * 1000)) {
        try { $process.Kill() } catch {}
        return [PSCustomObject]@{ Ok = $false; Detail = ('timeout after {0}s: {1}' -f $Seconds, $sample.FullName) }
    }
    [PSCustomObject]@{
        Ok = [bool]($process.ExitCode -eq 0)
        Detail = ('probe exit={0}: {1}' -f $process.ExitCode, $sample.FullName)
    }
}

function Stop-Eagle {
    @(Get-Process Eagle -ErrorAction SilentlyContinue) | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Test-Api {
    [bool](netstat -ano | Select-String -Pattern ':41595\s+.*LISTENING' | Select-Object -First 1)
}

$settingsPath = Join-Path $env:APPDATA 'Eagle\Settings'
$settings = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if (-not $Library) { $Library = [string]$settings.rootDir }
if (-not $Library -or -not (Test-Path -LiteralPath (Join-Path $Library 'images'))) {
    throw ('Library not found or invalid: {0}' -f $Library)
}

if (-not $Cache) {
    $logPath = Join-Path $env:APPDATA 'Eagle\log.log'
    $lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 6000)
    $needle = '*Start to load library: {0}*' -f $Library
    for ($i = $lines.Count - 1; $i -ge 0 -and -not $Cache; $i--) {
        if ($lines[$i] -notlike $needle) { continue }
        for ($j = $i + 1; $j -le [Math]::Min($lines.Count - 1, $i + 20); $j++) {
            $match = [regex]::Match($lines[$j], 'Load library\(cache\):\s*(.+)$')
            if ($match.Success) { $Cache = $match.Groups[1].Value.Trim(); break }
        }
    }
}

$state = Get-State $Library $Cache
$probe = Test-Readable $Library $ProbeTimeoutSeconds
$mismatch = $state.Bad -gt 0 -or $state.Missing.Count -gt 0 -or $state.Extra.Count -gt 0

Write-Host ''
Write-Host 'Eagle library repair'
Write-Host '===================='
Write-Host ('Library : {0}' -f $Library)
Write-Host ('Cache   : {0}' -f $(if ($Cache) { $Cache } else { '<unknown>' }))
Write-Host ('Readable: {0} ({1})' -f $probe.Ok, $probe.Detail)
Write-Host ''
[PSCustomObject]@{
    ImageFolders = $state.Folders.Count
    CacheLines = $state.CacheIds.Count
    CacheBadLines = $state.Bad
    CacheDeleted = $state.Deleted
    MissingInCache = $state.Missing.Count
    ExtraInCache = $state.Extra.Count
    QuarantineCandidates = $state.Orphans.Count
    Api41595 = Test-Api
} | Format-List

if (-not $Repair) {
    Write-Host 'Diagnostic only. Add -Repair to make changes.'
    if (-not $probe.Ok) { Write-Warning 'Use -Repair -RestartDriveFS to opt in to restarting Google Drive.' }
    return
}

if (-not $probe.Ok) {
    if (-not $RestartDriveFS) {
        throw 'Item data is unreadable. No changes made; use -RestartDriveFS explicitly.'
    }
    Stop-Eagle
    @(Get-Process GoogleDriveFS -ErrorAction SilentlyContinue) | Stop-Process -Force
    Start-Sleep -Seconds 3
    $launcher = 'C:\Program Files\Google\Drive File Stream\launch.bat'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw ('Google Drive launcher not found: {0}' -f $launcher)
    }
    Start-Process -FilePath $launcher -WindowStyle Hidden
    Start-Sleep -Seconds 15
    $probe = Test-Readable $Library $ProbeTimeoutSeconds
    if (-not $probe.Ok) {
        throw 'DriveFS restarted, but item data is still unreadable. Cache was not changed.'
    }
    Write-Host 'Google Drive item access recovered.'
}

$changed = $false
if ($state.Orphans.Count) {
    if ($state.Orphans.Count -gt $MaxQuarantineCandidates) {
        throw ('Refusing to quarantine {0} candidates (limit: {1}).' -f $state.Orphans.Count, $MaxQuarantineCandidates)
    }
    Stop-Eagle
    $quarantine = Join-Path $Library ('_eagle_quarantine_' + (Get-Date -Format yyyyMMdd_HHmmss))
    New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
    foreach ($id in $state.Orphans) {
        $source = Join-Path $Library ('images\' + $id + '.info')
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $quarantine
            Write-Host ('Quarantined: {0}.info' -f $id)
        }
    }
    Write-Host ('Quarantine: {0}' -f $quarantine)
    $mismatch = $true
    $changed = $true
}

if ($mismatch) {
    if (-not $Cache) { throw 'Cache mismatch detected, but cache path is unknown. Specify -Cache.' }
    Stop-Eagle
    if (Test-Path -LiteralPath $Cache) {
        $backup = '{0}.health-backup-{1}' -f $Cache, (Get-Date -Format yyyyMMdd-HHmmss)
        Move-Item -LiteralPath $Cache -Destination $backup
        Write-Host ('Cache backup: {0}' -f $backup)
    }
    $changed = $true
}

if (-not $changed -and (Test-Api)) {
    Write-Host 'Already healthy. No changes needed.'
    return
}

Stop-Eagle
$started = Get-Date
$eagle = 'C:\Program Files\Eagle\Eagle.exe'
if (-not (Test-Path -LiteralPath $eagle)) { throw ('Eagle not found: {0}' -f $eagle) }
Start-Process explorer.exe -ArgumentList ([char]34 + $eagle + [char]34)
Write-Host 'Waiting for Eagle to load...'
$deadline = (Get-Date).AddSeconds($LoadTimeoutSeconds)
$loaded = $false
while ((Get-Date) -lt $deadline -and -not $loaded) {
    Start-Sleep -Seconds 2
    $tail = @(Get-Content -LiteralPath (Join-Path $env:APPDATA 'Eagle\log.log') -Encoding UTF8 -Tail 120)
    foreach ($line in $tail) {
        $match = [regex]::Match($line, '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if ($match.Success -and $line -like '*Library loaded*') {
            $time = [datetime]::ParseExact($match.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)
            if ($time -ge $started -and (Test-Api)) { $loaded = $true; break }
        }
    }
}
if (-not $loaded) { throw ('Eagle did not load within {0} seconds.' -f $LoadTimeoutSeconds) }

$final = Get-State $Library $Cache
if ($final.Bad -or $final.Missing.Count -or $final.Extra.Count -or $final.Orphans.Count) {
    throw 'Eagle loaded, but final cache validation failed. Run in diagnostic mode for counts.'
}

Write-Host 'Repair completed successfully.'
[PSCustomObject]@{
    ImageFolders = $final.Folders.Count
    CacheLines = $final.CacheIds.Count
    MissingInCache = $final.Missing.Count
    ExtraInCache = $final.Extra.Count
    QuarantineCandidates = $final.Orphans.Count
    Api41595 = Test-Api
} | Format-List
