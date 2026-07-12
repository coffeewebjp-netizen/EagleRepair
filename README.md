# EagleRepair

Eagleのライブラリ読み込み停止を診断・修復するためのPowerShellツールと、実際の復旧事例から得たナレッジです。

Eagle公式ツールではありません。Google Drive for desktop上のEagleライブラリで確認した症状を中心に扱います。

## 収録内容

- `tools/eagle-library-health.ps1`: ライブラリ、キャッシュ、`mtime.json`、Eagle設定の整合性診断と、孤立 `.info` の隔離
- `tools/eagle-library-repair.ps1`: DriveFS読取テスト、キャッシュ退避・再生成、Eagle再起動、最終検証をまとめた安全側の修復フロー
- `docs/eagle-troubleshooting.md`: 初回障害を含む詳細な調査・復旧手順
- `docs/eagle-incident-20260711.md`: スリープ復帰後のDriveFSタイムアウトと古いキャッシュが重なった事例

## 使い方

PowerShellでリポジトリのルートから実行します。

診断のみ:

```powershell
.\tools\eagle-library-repair.ps1
```

安全な修復を実行:

```powershell
.\tools\eagle-library-repair.ps1 -Repair
```

対象データの読取がタイムアウトした場合に限り、Google DriveFSの再起動も明示的に許可:

```powershell
.\tools\eagle-library-repair.ps1 -Repair -RestartDriveFS
```

対象を明示する場合:

```powershell
.\tools\eagle-library-repair.ps1 `
  -Library 'I:\マイドライブ\example.library' `
  -Cache $env:APPDATA\Eagle\library-caches\example.txt
```

## 安全設計

- 既定は診断のみで、`-Repair` がなければ変更しません。
- キャッシュは削除せず、日時付きのバックアップへ退避します。
- Google DriveFSの再起動は `-RestartDriveFS` の明示指定が必要です。
- `.info` の中身が読めることを確認するまでキャッシュを変更しません。
- 孤立候補が既定で21件以上ある場合、自動隔離を拒否します。
- 修復後にID差分、`Library loaded`、APIポート41595を検証します。

## 確認済みの障害パターン

1. `images` に存在するがキャッシュと `mtime.json` の両方に存在しない孤立 `.info`。
2. Windowsのスリープ復帰後にGoogle DriveFSが `TIMEOUT_EXCEEDED` となり、Eagleがフォルダ列挙後に停止する状態。
3. 実体データが別世代へ入れ替わった一方、Eagleが削除済みエントリだけの古いキャッシュを再利用する状態。

詳細と判断条件は `docs` を参照してください。
