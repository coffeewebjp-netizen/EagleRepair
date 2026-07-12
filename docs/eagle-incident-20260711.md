# Eagle incident memo — 2026-07-11

## Incident

After resuming Windows from sleep, Eagle stopped while switching to `I:\マイドライブ\pervert.library`.

- The log stopped after `Get /images folders finished, total: 445`; it never reached `Library loaded`.
- Eagle's local API port `41595` was not listening.
- Google Drive for desktop's DriveFS log contained `TIMEOUT_EXCEEDED` and repeated media-download requests.
- A single `.info` folder could be enumerated, but listing its contents blocked for over 30 seconds.

## What was and was not corrupt

- `images` contained 445 folders and `mtime.json` contained all 445 IDs: this was not the prior “orphan .info folder” failure.
- Eagle's old cache had 973 entries, all with `isDeleted: true`.
- The old cache and the 445 on-disk IDs had zero overlap, so the cache belonged to an older, deleted generation of the library.

## Proven-safe recovery sequence

1. Fully exit Eagle.
2. Restart Google Drive for desktop (`GoogleDriveFS`).
3. Do not rebuild Eagle's cache until an arbitrary `.info` folder can list `metadata.json`, the primary image, and its thumbnail.
4. Move the old `library-caches/*.txt` file to a timestamped backup name; do not delete it.
5. Start Eagle in the interactive user session.
6. Verify the log reaches `No library cache` → `Library loaded` → `Local server: enabled`, and port `41595` listens.
7. Run `tools/eagle-library-health.ps1` with the library and cache path explicitly specified.

## Verified result in this incident

```text
ImageFolders     : 445
CacheLines       : 445
CacheBadLines    : 0
MissingInCache   : 0
ExtraInCache     : 0
MissingInMtime   : 0
SettingsProblems : 0
```

## Product-quality note

DriveFS's timeout was the trigger, but Eagle did not recover gracefully from unavailable cloud-backed data and did not protect itself from a completely stale, deleted-only cache. Eagle also logged `Network Drive: NO` for the Google Drive virtual `I:` volume. Treat this as an Eagle/DriveFS interoperability robustness defect, not simply bad library data.

## Automation boundary

A repair tool can safely automate detection, cache backup/rebuild, and post-repair validation once it proves that a sampled `.info` folder is readable. Restarting DriveFS should remain opt-in until the tool can distinguish a temporary cloud fetch from an active upload/download or unresolved sync conflict.

## Repair tool

The v1 implementation is `tools/eagle-library-repair.ps1`.

Diagnostic only:

```powershell
.\tools\eagle-library-repair.ps1
```

Apply safe repairs for the current library:

```powershell
.\tools\eagle-library-repair.ps1 -Repair
```

Explicitly allow DriveFS restart when the item-read probe times out:

```powershell
.\tools\eagle-library-repair.ps1 -Repair -RestartDriveFS
```

The tool defaults to diagnosis, backs up caches instead of deleting them, limits automatic orphan quarantine to 20 candidates, starts Eagle through the interactive Windows session, and requires final ID and API-port validation before reporting success.
