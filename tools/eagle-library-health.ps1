param(
    [string]$Library,
    [string]$Cache,
    [switch]$Quarantine,
    [switch]$StopEagle,
    [switch]$RepairSettings
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonFile($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Get-Settings {
    $settingsPath = Join-Path $env:APPDATA "Eagle\Settings"
    $settings = Read-JsonFile $settingsPath
    return [PSCustomObject]@{
        Path = $settingsPath
        Data = $settings
    }
}

function Get-InfoFolderIds($LibraryPath) {
    $imagesPath = Join-Path $LibraryPath "images"
    if (-not (Test-Path -LiteralPath $imagesPath)) {
        throw "images folder not found: $imagesPath"
    }

    $ids = New-Object "System.Collections.Generic.List[string]"
    Get-ChildItem -LiteralPath $imagesPath -Force -Directory | ForEach-Object {
        $ids.Add(($_.Name -replace '\.info$', ''))
    }
    return $ids
}

function Get-CacheIds($CachePath) {
    if (-not (Test-Path -LiteralPath $CachePath)) {
        throw "cache file not found: $CachePath"
    }

    $ids = New-Object "System.Collections.Generic.List[string]"
    $badLines = 0
    $lineCount = 0
    foreach ($line in [System.IO.File]::ReadLines($CachePath, [System.Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) {
            continue
        }
        $lineCount++
        $match = [regex]::Match($line, '"id"\s*:\s*"([^"]+)"')
        if ($match.Success) {
            $ids.Add($match.Groups[1].Value)
        } else {
            $badLines++
        }
    }

    return [PSCustomObject]@{
        Ids = $ids
        LineCount = $lineCount
        BadLines = $badLines
    }
}

function Find-BestCache($LibraryPath, $FolderIds) {
    $cacheDir = Join-Path $env:APPDATA "Eagle\library-caches"
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        throw "cache directory not found: $cacheDir"
    }

    $folderSet = New-Object "System.Collections.Generic.HashSet[string]"
    foreach ($id in $FolderIds) {
        [void]$folderSet.Add([string]$id)
    }

    $candidates = New-Object "System.Collections.Generic.List[object]"
    Get-ChildItem -LiteralPath $cacheDir -Force -File -Filter "*.txt" | ForEach-Object {
        $cacheInfo = Get-CacheIds $_.FullName
        $overlap = 0
        foreach ($id in $cacheInfo.Ids) {
            if ($folderSet.Contains([string]$id)) {
                $overlap++
            }
        }
        $candidates.Add([PSCustomObject]@{
            Path = $_.FullName
            Name = $_.Name
            Bytes = $_.Length
            LastWriteTime = $_.LastWriteTime
            LineCount = $cacheInfo.LineCount
            BadLines = $cacheInfo.BadLines
            Overlap = $overlap
            Score = ($overlap * 1000000) - [Math]::Abs($cacheInfo.LineCount - $FolderIds.Count)
        })
    }

    if ($candidates.Count -eq 0) {
        throw "no *.txt cache files found in: $cacheDir"
    }

    return $candidates | Sort-Object Score -Descending | Select-Object -First 1
}

function Get-MtimeIds($LibraryPath) {
    $mtimePath = Join-Path $LibraryPath "mtime.json"
    $set = New-Object "System.Collections.Generic.HashSet[string]"
    if (-not (Test-Path -LiteralPath $mtimePath)) {
        return $set
    }

    $mtime = Read-JsonFile $mtimePath
    foreach ($prop in $mtime.PSObject.Properties.Name) {
        [void]$set.Add([string]$prop)
    }
    return $set
}

function Stop-EagleProcesses {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq "Eagle" })
    if ($procs.Count -eq 0) {
        return
    }
    $procs | Stop-Process -Force
    Start-Sleep -Seconds 2
}

function Repair-EagleSettings($SettingsInfo, $LibraryPath) {
    $settingsPath = $SettingsInfo.Path
    $backup = "$settingsPath.health-backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item -LiteralPath $settingsPath -Destination $backup

    $settings = $SettingsInfo.Data
    $settings.rootDir = $LibraryPath
    $settings.libraryDirs = @($LibraryPath)
    $settings.libraryHistory = @($LibraryPath)

    $json = $settings | ConvertTo-Json -Depth 100 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsPath, $json, $utf8NoBom)

    Write-Host "Settings repaired. Backup: $backup"
}

$settingsInfo = Get-Settings
if (-not $Library) {
    $Library = [string]$settingsInfo.Data.rootDir
}
if (-not $Library) {
    throw "Library was not specified and Eagle Settings.rootDir is empty."
}
if (-not (Test-Path -LiteralPath $Library)) {
    throw "Library not found: $Library"
}

if ($RepairSettings) {
    Repair-EagleSettings $settingsInfo $Library
    $settingsInfo = Get-Settings
}

$folderIds = Get-InfoFolderIds $Library
if (-not $Cache) {
    $best = Find-BestCache $Library $folderIds
    $Cache = $best.Path
} else {
    $best = $null
}

$cacheInfo = Get-CacheIds $Cache

$folderSet = New-Object "System.Collections.Generic.HashSet[string]"
foreach ($id in $folderIds) {
    [void]$folderSet.Add([string]$id)
}

$cacheSet = New-Object "System.Collections.Generic.HashSet[string]"
foreach ($id in $cacheInfo.Ids) {
    [void]$cacheSet.Add([string]$id)
}

$missingInCache = @($folderIds | Where-Object { -not $cacheSet.Contains([string]$_) } | Sort-Object)
$extraInCache = @($cacheInfo.Ids | Where-Object { -not $folderSet.Contains([string]$_) } | Sort-Object -Unique)

$mtimeSet = Get-MtimeIds $Library
$missingInMtime = @($missingInCache | Where-Object { -not $mtimeSet.Contains([string]$_) } | Sort-Object)

$settingsProblems = New-Object "System.Collections.Generic.List[string]"
if (-not $settingsInfo.Data.libraryDirs -or $settingsInfo.Data.libraryDirs.Count -eq 0) {
    $settingsProblems.Add("libraryDirs is empty")
}
if ($settingsInfo.Data.libraryHistory -contains "undefined") {
    $settingsProblems.Add("libraryHistory contains undefined")
}
if ([string]$settingsInfo.Data.rootDir -ne [string]$Library) {
    $settingsProblems.Add("Settings.rootDir differs from checked library")
}

Write-Host ""
Write-Host "Eagle library health"
Write-Host "===================="
Write-Host "Library : $Library"
Write-Host "Cache   : $Cache"
if ($best) {
    Write-Host "Cache auto-detected: $($best.Name) (overlap $($best.Overlap), lines $($best.LineCount))"
}
Write-Host ""

[PSCustomObject]@{
    ImageFolders = $folderIds.Count
    CacheLines = $cacheInfo.LineCount
    CacheBadLines = $cacheInfo.BadLines
    MissingInCache = $missingInCache.Count
    ExtraInCache = $extraInCache.Count
    MissingInMtime = $missingInMtime.Count
    SettingsProblems = $settingsProblems.Count
} | Format-List

if ($settingsProblems.Count -gt 0) {
    Write-Warning "Settings problems:"
    $settingsProblems | ForEach-Object { Write-Warning "  $_" }
}

if ($missingInCache.Count -gt 0) {
    Write-Warning "IDs present in images but missing in cache:"
    $missingInCache | ForEach-Object { Write-Host "  $_" }
}

if ($extraInCache.Count -gt 0) {
    Write-Warning "IDs present in cache but missing in images:"
    $extraInCache | ForEach-Object { Write-Host "  $_" }
}

if ($missingInMtime.Count -gt 0) {
    Write-Warning "Quarantine candidates: missing from both cache and mtime.json:"
    $missingInMtime | ForEach-Object { Write-Host "  $_" }
}

if ($Quarantine) {
    if ($missingInMtime.Count -eq 0) {
        Write-Host "No quarantine candidates."
        return
    }

    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq "Eagle" })
    if ($running.Count -gt 0) {
        if ($StopEagle) {
            Write-Host "Stopping Eagle..."
            Stop-EagleProcesses
        } else {
            throw "Eagle is running. Close Eagle first, or rerun with -StopEagle."
        }
    }

    $quarantine = Join-Path $Library ("_eagle_quarantine_" + (Get-Date -Format yyyyMMdd_HHmmss))
    New-Item -ItemType Directory -Path $quarantine -Force | Out-Null

    foreach ($id in $missingInMtime) {
        $src = Join-Path $Library ("images\" + $id + ".info")
        if (Test-Path -LiteralPath $src) {
            Move-Item -LiteralPath $src -Destination $quarantine
            Write-Host "Moved: $id.info"
        }
    }

    Write-Host "Quarantine: $quarantine"
}
