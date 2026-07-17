# Modern Standby復帰後のHDMIディスプレイ欠落

## 概要

2026年7月17日、HP Victus 16-r0xxxでModern Standbyから復帰した直後、HDMI接続のDell SE2425HGだけがWindowsから消えた。USB-C接続のDell S2725QCと内蔵パネルは正常だった。

利用者は従来、Dell Display and Peripheral Managerを起動し、Windowsの表示切り替えを何度も操作して3画面に戻していた。この反復操作をCoffeeDiagnoseの外部ディスプレイ復旧モジュールへ統合した。

## 確認した環境

- PC: Victus by HP Gaming Laptop 16-r0xxx
- GPU: NVIDIA GeForce RTX 4070 Laptop GPU
- 電源モデル: S0 Low Power Idle（Modern Standby）
- Windows: Windows 11 25H2、ビルド26200.8737
- 24インチ: Dell SE2425HG、HDMI1、ファームウェアM3T101
- 27インチ: Dell S2725QC、USB Type-C、ファームウェアM3B101
- BIOS: F.29
- NVIDIAドライバー: 32.0.15.9227（592.27）

## 障害時の証拠

- 復帰時刻は20:35:44。
- SE2425HGのPnP `LastRemoval`も20:35:44で一致した。
- SE2425HGは一度`DISPLAY6 / 1920x1080`として現れたあと、解像度0x0となって消えた。
- 最終状態では`CM_PROB_PHANTOM`、Present=Falseだった。
- DDPMログは`GetDisplayConfigPath error`、Screen=3から2への減少、物理モニター1台を記録した。
- `Get-PnpDevice`と`WmiMonitorID`の列挙が停止することがあり、診断側にもタイムアウトが必要だった。
- Displayイベント4101やnvlddmkmのTDRはなく、GPUドライバー全体のクラッシュは確認されなかった。
- 復帰直後にNVIDIA OverlayのAPPCRASHはあったが、表示ドライバー障害の証拠ではない。

以上から、DDPMのUI障害ではなく、Modern Standby復帰時のNVIDIA HDMI hot-plug／EDID再列挙失敗と判断した。HPファームウェア、NVIDIAドライバー、モニターまたはケーブル間のタイミング要因までは一意に確定していない。

## 復旧試験

次の処理だけでは復帰しなかった。

1. `DisplaySwitch.exe /extend`の反復
2. `pnputil.exe /scan-devices`
3. 複製から拡張への切り替え
4. PC画面のみから拡張への切り替え

その後、「外部画面のみ」から「拡張」への切り替えを行うと、遅れてSE2425HGが再列挙された。DDPMログでは21:01:13以降に`DISPLAY6`が再登場し、Screen count=3、Dellモニター数=2となった。21:03の最終確認では次を満たした。

- アクティブ画面: DISPLAY1、DISPLAY5、DISPLAY6の3台
- PnP: SE2425HG、S2725QC、内蔵パネルがすべてStarted
- DDPMバックエンド: Dellモニター2台

## 実装上の注意

Windows Formsの`Screen.AllScreens`を同じPowerShellプロセスで繰り返し読むと、表示切り替え後も古い2画面が返り、実際には復帰しているのに失敗判定した。最終実装ではUser32の`EnumDisplayMonitors`と`GetMonitorInfo`を直接呼び、毎回ライブの表示構成を取得する。

PnP列挙もハングし得るため、`pnputil`は子プロセスで実行し、15秒または30秒の上限を設ける。DDPMモジュールから同期的な`Get-PnpDevice`呼び出しも除去した。

## 外部ディスプレイ復旧モジュール

`modules/display-recovery/module.psd1`で、このPC固有の期待値を設定する。

```powershell
Settings = @{
    TargetMonitorPattern = 'SE2425HG'
    ExpectedActiveDisplays = 3
}
```

修復は次の順で実行する。

1. すでに3画面かつSE2425HG接続なら変更せず終了
2. 拡張を再要求
3. 外部画面のみから拡張へ切り替え、最大20秒待ってライブ構成を検証
4. 必要なら再試行
5. 管理者実行時だけPnP再スキャン
6. 最終手段として複製から拡張へ切り替え
7. 3画面とSE2425HG接続の両方を確認
8. 復帰後にDDPMユーザーセッションを再読込

通常のWPF操作では管理者権限を要求しない。GPUデバイスの無効化・有効化、ドライバー再起動、BIOS・ドライバー・モニターファームウェア更新は行わない。検証条件を満たさない場合は安全に失敗として終了する。

## 未確定事項

公式更新情報には、この組み合わせの復帰障害を明示的に修正すると確認できる記載がなかった。そのためBIOS F.31、Windows更新、NVIDIA更新は自動修復に含めていない。再発時の自動復旧ログを蓄積し、外部画面のみから拡張への切り替えで安定して復帰するかを継続確認する。
