# DDPM incident memo — 2026-07-16

## 症状

Dell Display and Peripheral Manager（DDPM）2.1.2.12を起動すると、画面が「DDPM Subagentに接続しています」のまま進まなかった。
表示上はDellデバイスを探し続けているように見えた。

## デバイス検出は正常だった

WindowsとDDPMバックエンドは、次の2台を一貫して認識していた。

- Dell S2725QC（USB Type-C）
- Dell SE2425HG（HDMI1）

バックエンドログでは以下を確認した。

```text
AllInfoMonitors count is 2
Initialize2TypesMonitorInfo finish : count => 2
```

両方ともDDC/CIの監視対象になっていた。したがって、原因はモニター、ケーブル、入力端子の未検出ではない。

## 失敗していた箇所

GUIログでは約200ms間隔で次の待機が繰り返された。

```text
DoWork_PleaseWait Wait_DevMgr DDPM Subagentに接続しています...
```

同時に次のエラーを確認した。

```text
PeerClientStreamProvider : Access is denied
SubAgentControlClientBase : agent is running unelevated
Plugin of type IDeviceManagerSA was not resolved
PluginManager_PluginsStarted IDeviceManagerSA Plugin is null
```

DDPMバックエンドが保持する2台の情報を、GUIがRPCプラグイン経由で受け取れない状態だった。

## 復旧時の重要なタイミング

DellTechHubとDPMServiceを再起動した直後は、古いログにも`count is 2`が残っているため、それだけで準備完了と判断してはいけない。

今回の実測では、新しい`DDPM.Subagent.User`が起動してから、次のプラグイン登録とGUI接続が完了するまで約45秒かかった。

```text
Plugin registration succeeded for 9829a9c5-e129-488a-a522-b8ff705051ee
DDPM Subagent User has accepted a peer registration for Console
IDeviceManagerSA published by DDPM Subagent User
```

成功後のGUIログ:

```text
PrepareMonitorInfos(count = 2)
PrepareMonitorInfos AliasDeviceName = Dell S2725QC(USB TypeC)
PrepareMonitorInfos AliasDeviceName = Dell SE2425HG (HDMI1)
Monitor count is 2
current HomeDevice Count = 2
```

画面上で一度に1台しか見えない場合でも、上記が出ていれば内部的には2台ともGUIへ渡っている。UIの選択表示と未認識を区別する必要がある。

## 自動修復シーケンス

`modules/ddpm/handler.ps1`は次の順序で処理する。

1. インストール済みバージョンと実行ファイルを確認
2. DDPMのユーザープロセスを終了
3. `DPMService`、`DellTechHub`を停止
4. `DellTechHub`、`DPMService`の順に開始
5. 再起動後の新しいログだけを対象に、バックエンドがモニター一覧を発行するまで待機
6. 通常ユーザーセッションでDDPMを起動し、GUI受信数を検証
7. 通常起動がアクセス拒否になる場合だけ、そのセッションに限って管理者権限で起動
8. GUI受信数がバックエンド数以上になった場合だけ成功

## 自動化しない処理

- DDPMの更新
- DDPMのアンインストール／再インストール
- レジストリへの永続的な`RUNASADMIN`設定
- DDPM設定・ログの削除
- Dell TechHubのRPC登録キーの推測修正

調査時点でDell公式には2.3.0.9が存在したが、今回のRPC接続不良が解消されたという明確なリリースノート上の根拠がなかったため、ユーザー判断により更新しなかった。

## InstallShieldに関する注意

インストール先に残る`Installer/setup.iss`の保守コードを修復と解釈してはいけない。
今回、その応答ファイルを同版修復に使用したところアンインストール動作になった。
署名済みの元インストーラーから同じ2.1.2.12を復元できたが、自動修復ツールではインストーラーを一切呼び出さない。

## 製品品質上の所見

バックエンドが2台のDellモニターを正常に列挙している一方、GUIがRPC接続失敗から自己回復せず、無期限に「接続しています」を表示する。
また、サービス再起動後のプラグイン登録に時間がかかる間も、ユーザーへ原因や待機期限が示されない。
これは単なるデバイス未検出ではなく、DDPM 2.1.2.12の内部通信と回復性に関する製品不具合として扱うのが妥当である。
