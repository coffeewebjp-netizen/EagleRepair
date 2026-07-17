# TroubleRepair / EagleRepair

## モダンWPF画面

TroubleRepair.batをダブルクリックすると、.NET 10 / WPFで作成したCoffeeDiagnoseが開きます。

- アプリごとのカードから「診断する」「ワンクリック修復」を実行
- 実行状態を待機中・診断中・修復中・正常・要確認で表示
- 実行ログを画面内で追跡し、コピーやログフォルダー表示が可能
- 「すべて診断」は変更を加えない診断を順番に実行
- 管理者権限はRepairRequiresAdminの修復を押したときだけ要求

初回だけWPF版をReleaseビルドします。既にビルド済みなら即時起動し、.NET SDKがないPCやビルドに失敗した環境では既存のWinForms版へ自動的にフォールバックします。コマンドライン引数を付けた場合も従来のPowerShell CLIを使用します。

手動ビルド:

    dotnet build .\wpf\CoffeeDiagnose.csproj -c Release

WPF版の操作、別PCへの展開、権限、安全設計、ログ確認は[CoffeeDiagnose WPF版 利用・運用ガイド](docs/wpf-troubleshooter-guide.md)を参照してください。

Eagleのライブラリ読み込み停止、スリープ復帰後の外部ディスプレイ欠落、Dell Display and Peripheral Manager（DDPM）の内部接続不良を診断・修復するWindows向けトラブルシューティングツールです。
アプリごとの処理をモジュールとして追加できるため、今後発生する別アプリの障害も同じ画面へ統合できます。

各製品の公式ツールではありません。実際に確認できた症状と、復旧後の検証条件が明確な処理だけを自動化しています。

## ワンクリック実行

`TroubleRepair.bat` をダブルクリックするとGUIが開きます。

1. 対象アプリを選ぶ
2. まず「診断」、または直接「ワンクリック修復」を押す
3. DDPMなど管理者権限が必要な修復では、WindowsのUAC確認で「はい」を選ぶ
4. 下部ログで診断・修復・最終検証の結果を確認する

現在のモジュール:

- **Eagle**: Google Drive読取確認、ライブラリキャッシュ退避・再生成、孤立データの安全制限、再起動後のAPI検証
- **外部ディスプレイ復旧**: 消えたDell SE2425HGを検出し、Windowsの表示切り替え、必要に応じたPnP再スキャン、3画面復帰の検証を実施
- **Dell Display and Peripheral Manager**: 接続中Dellモニター数、DDPMバックエンド数、GUI受信数を比較し、サービス再起動と起動方法の切替を実施

コマンドラインからも実行できます。

```powershell
.\TroubleRepair.bat eagle Diagnose
.\TroubleRepair.bat eagle Repair
.\TroubleRepair.bat display-recovery Diagnose
.\TroubleRepair.bat display-recovery Repair
.\TroubleRepair.bat ddpm Diagnose
.\TroubleRepair.bat ddpm Repair
```

DDPM修復はインストール済みバージョンを維持します。アプリ更新、再インストール、永続的な`RUNASADMIN`設定は行いません。
通常起動で内部接続に失敗した場合だけ、その実行セッションに限って管理者権限でDDPMを起動します。

外部ディスプレイ復旧は通常権限で動作します。画面が一時的に点滅することはありますが、GPUデバイスの無効化、ドライバー再起動、ドライバー・BIOS・ファームウェア更新は行いません。3画面と対象モニターの接続を確認できない場合は成功扱いにしません。

## 収録内容

- `TroubleRepair.bat` / `TroubleRepair.ps1`: モジュールを自動列挙する共通GUIとCLI
- `modules/`: アプリ別の診断・修復モジュール
- `modules/_template/`: 新しいアプリを追加する際のテンプレート
- `tools/invoke-troubleshooter-module.ps1`: ログ、結果JSON、権限分離を担当する共通ランナー
- `tools/eagle-library-health.ps1`: ライブラリ、キャッシュ、`mtime.json`、Eagle設定の整合性診断と、孤立 `.info` の隔離
- `tools/eagle-library-repair.ps1`: DriveFS読取テスト、キャッシュ退避・再生成、Eagle再起動、最終検証をまとめた安全側の修復フロー
- `docs/eagle-troubleshooting.md`: 初回障害を含む詳細な調査・復旧手順
- `docs/eagle-incident-20260711.md`: スリープ復帰後のDriveFSタイムアウトと古いキャッシュが重なった事例
- `docs/ddpm-incident-20260716.md`: DDPMのUI・サブエージェント接続不良と2台認識の検証記録
- `docs/display-wake-incident-20260717.md`: Modern Standby復帰後にHDMIモニターが消える事例とワンクリック復旧の検証記録
- `docs/troubleshooter-architecture.md`: モジュール追加方法と安全規約

## 使い方

PowerShellでリポジトリのルートから実行します。

### かんたん実行

`EagleRepair.bat` をダブルクリックすると、診断から必要な修復、Eagleの再起動、最終検証まで一連で実行します。DriveFSの再起動は、読取テストがタイムアウトした場合だけ行われます。

診断だけ行う場合:

```powershell
.\EagleRepair.bat diagnose
```

### PowerShellから個別に実行

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
