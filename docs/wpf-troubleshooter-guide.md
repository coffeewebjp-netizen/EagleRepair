# CoffeeDiagnose WPF版 利用・運用ガイド

## 概要

CoffeeDiagnoseは、EagleやDell Display and Peripheral Manager（DDPM）などの障害を、共通画面から診断・修復するWindows向けツールです。

画面は.NET 10 / WPFで実装されています。アプリ固有の診断・修復ロジックはPowerShellモジュールとして分離されているため、今後別のアプリを追加してもWPF画面を作り直す必要はありません。

リポジトリ:

[coffeewebjp-netizen/EagleRepair](https://github.com/coffeewebjp-netizen/EagleRepair)

## 現在対応しているアプリ

- Eagle
  - ライブラリとGoogle Driveの読取確認
  - キャッシュ不整合の診断
  - 安全な退避とキャッシュ再生成
  - Eagle再起動後のAPI検証
- Dell Display and Peripheral Manager
  - Windowsが認識しているDellモニター数の確認
  - DDPMバックエンドとGUIのモニター数比較
  - 関連サービスの状態確認と再起動
  - 通常起動と、その実行セッションだけに限定した昇格起動

DDPMの更新、アンインストール、再インストール、永続的なRUNASADMIN設定は自動修復に含みません。

## 必要環境

- Windows 10またはWindows 11
- Windows PowerShell 5.1
- WPF版をソースから初回ビルドする場合は.NET 10 SDK
- 対象アプリと、そのアプリが通常利用する関連サービス

このPCでは.NET 10 SDK 10.0.302を確認しています。

## 起動方法

リポジトリのルートにあるTroubleRepair.batをダブルクリックします。

1. WPF版がビルド済みならCoffeeDiagnoseをすぐに起動します。
2. 未ビルドで.NET SDKがある場合は、Releaseビルド後に起動します。
3. .NET SDKがない、またはビルドに失敗した場合は、既存のWinForms版へ自動的に切り替わります。
4. コマンドライン引数を付けた場合は、従来のPowerShell CLIとして動作します。

WPF版の手動ビルド:

    dotnet build .\wpf\CoffeeDiagnose.csproj -c Release

## 基本操作

### 診断する

対象アプリのカードにある「診断する」を押します。

診断は外部状態を変更しません。最初に診断を行い、ログとカードの状態を確認する使い方を推奨します。

### ワンクリック修復

対象アプリの「ワンクリック修復」を押し、確認画面で続行します。

修復中は、対象アプリや関連サービスが一時的に終了・再起動する場合があります。管理者権限が必要なモジュールでは、この時点だけWindowsのUAC確認が表示されます。

### すべて診断

右上の「すべて診断」を押すと、有効な全モジュールの診断を順番に実行します。修復は実行しません。

### 実行ログ

画面下部に処理内容が随時表示されます。

- 「コピー」: 表示中のログをクリップボードへコピー
- 「ログフォルダー」: 保存先をExplorerで表示

標準のログ保存先:

    %LOCALAPPDATA%\CoffeeWeb\TroubleRepair\logs

ログと同じ名前のJSONには、成功可否、終了コード、開始・終了時刻が記録されます。

## 状態表示

- 待機中: まだ処理していません
- 診断中: 変更を伴わない確認を実行中です
- 修復中: 確認済みの復旧手順を実行中です
- 正常に完了: モジュールの完了条件を満たしました
- 要確認: 処理または最終検証を完了できませんでした

「正常に完了」は、単にプロセスが終了したことではなく、各モジュールが定義した検証条件を満たしたことを表します。

## 権限と安全設計

- CoffeeDiagnose本体は通常権限で起動します。
- 診断は通常権限のまま実行します。
- 管理者権限は、RepairRequiresAdminがtrueの修復を選んだ時だけ要求します。
- UACをキャンセルした場合は修復を開始せず、キャンセルとして画面へ表示します。
- アプリの自動更新、再インストール、永続的な互換性設定は行いません。
- Eagleでは削除より退避を優先し、件数制限と読取検証を通過しない場合は自動変更を止めます。
- DDPMではGUIが認識したモニター数とバックエンドの認識数が一致するまで成功扱いにしません。

## 別PCで利用する場合

### .NET 10 SDKがあるPC

リポジトリ一式を配置し、TroubleRepair.batをダブルクリックします。初回だけ自動ビルドされます。

### .NETランタイムだけがあるPC

リポジトリには生成済みbin/objを保存していないため、そのPCではソースからWPF版をビルドできません。現在のランチャーはWinForms版へフォールバックします。

WPF版を使わせる場合は、次のどちらかが必要です。

- 対象PCへ.NET 10 SDKを導入する
- ビルド用PCでpublishした成果物を、リポジトリ一式と一緒に配布する

フレームワーク依存publishの例:

    dotnet publish .\wpf\CoffeeDiagnose.csproj -c Release -r win-x64 --self-contained false -o .\dist\CoffeeDiagnose

publishした実行ファイルだけでは修復できません。modules、tools、resourcesも同じTroubleRepairルート構造で必要です。

## WPF版が起動しない場合

1. コマンド画面から手動ビルドし、エラーを確認します。

       dotnet build .\wpf\CoffeeDiagnose.csproj -c Release

2. 次の起動エラーログを確認します。

       %LOCALAPPDATA%\CoffeeWeb\TroubleRepair\logs\wpf-startup-error.log

3. TroubleRepair.ps1を直接起動し、WinForms版で診断できるか確認します。
4. 対象アプリの診断ログと結果JSONを保存します。

WPFが起動できなくても、既存のPowerShell修復ロジックは独立して利用できます。

## コマンドライン利用

    .\TroubleRepair.bat eagle Diagnose
    .\TroubleRepair.bat eagle Repair
    .\TroubleRepair.bat ddpm Diagnose
    .\TroubleRepair.bat ddpm Repair

CLIでもWPF版と同じモジュール、共通ランナー、ログ形式を利用します。

## モジュール追加

新しいアプリを追加する基本単位は次の2ファイルです。

    modules\<module-id>\module.psd1
    modules\<module-id>\handler.ps1

名称と説明をresources/ja.jsonへ追加し、モジュールをEnabledにすると、次回起動時にWPF画面へカードが自動表示されます。

詳しい契約、権限指定、安全要件は[troubleshooter-architecture.md](troubleshooter-architecture.md)を参照してください。

## 2026年7月17日時点の検証記録

- .NET 10 SDK 10.0.302でReleaseビルド成功
- コンパイラ警告0件、エラー0件
- WPF本体がElevated=Falseで起動することを確認
- EagleとDDPMの2モジュールが自動表示されることを確認
- WPF画面からEagle診断がSuccess=true、ExitCode=0で完了
- Eagle診断プロセスがAdministrator=Falseであることを確認
- 従来CLIからDDPM診断がExitCode=0で完了
- DDPM診断でDellモニター2台と関連サービス2件の稼働を確認

## 関連ドキュメント

- [WPF・モジュール構成](troubleshooter-architecture.md)
- [Eagleの詳細な診断・修復手順](eagle-troubleshooting.md)
- [Eagle障害記録](eagle-incident-20260711.md)
- [DDPM障害記録](ddpm-incident-20260716.md)
