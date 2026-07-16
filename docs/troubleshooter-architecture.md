# TroubleRepair architecture

## 目的

アプリごとの障害知識を独立したモジュールにし、共通GUIから同じ操作で診断・修復できるようにする。
新しいアプリを追加しても、既存モジュールやGUIのコードを変更しない構造を基本とする。

## ディレクトリ構造

```text
TroubleRepair.bat
TroubleRepair.ps1
resources/
  ja.json
tools/
  invoke-troubleshooter-module.ps1
modules/
  eagle/
    module.psd1
    handler.ps1
  ddpm/
    module.psd1
    handler.ps1
  _template/
    module.psd1
    handler.ps1
```

`TroubleRepair.ps1`は`modules/*/module.psd1`を列挙し、`Enabled = $true`のモジュールを表示する。

## モジュール契約

`module.psd1`:

```powershell
@{
    SchemaVersion = 1
    Id = 'sample'
    DisplayNameKey = 'modules.sample.name'
    DescriptionKey = 'modules.sample.description'
    Handler = 'handler.ps1'
    SupportsDiagnose = $true
    SupportsRepair = $true
    RepairRequiresAdmin = $false
    Order = 100
    Enabled = $true
}
```

`handler.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Diagnose', 'Repair')]
    [string]$Mode
)
```

- 成功時は通常の出力を行って終了する
- 失敗時は`throw`する
- 診断モードでは外部状態を変更しない
- 修復モードは対象アプリとその直接依存サービスだけを変更する

共通ランナーが全ストリームをUTF-8ログへ保存し、結果をJSONで記録する。

## 新しいアプリの追加

1. `modules/_template`を新しいID名でコピー
2. `module.psd1`のID、表示キー、権限、順序を変更
3. `handler.ps1`へ読み取り専用診断を実装
4. 診断で原因を一意に絞れる場合だけ修復を実装
5. `resources/ja.json`へ名称と説明を追加
6. 診断成功、既知障害の修復成功、未知状態での安全停止をテスト
7. `Enabled = $true`にする

## 安全規約

- 削除よりバックアップ、隔離、再生成を優先する
- アプリ更新・アンインストール・再インストールは通常の修復モジュールに含めない
- 永続的な管理者起動設定を自動適用しない
- サービス再起動はモジュールの対象製品に限定する
- 修復後は症状ではなく、ログ・件数・ポート・APIなど客観条件で検証する
- 検証条件を満たさない場合は成功扱いにしない
- 推測したレジストリ値や不明なキャッシュを変更しない

## 権限モデル

GUIは通常権限で起動する。
`RepairRequiresAdmin = $true`の修復を押したときだけ、共通ランナーをUAC経由で管理者起動する。
診断や他のモジュールまで常時昇格させない。

## ログ

標準保存先:

```text
%LOCALAPPDATA%\CoffeeWeb\TroubleRepair\logs
```

ログには開始時刻、管理者権限の有無、モジュール出力、エラーとスタックを保存する。
同名実行を上書きせず、日時・モジュール・モードごとに別ファイルを作成する。
