# EAGLE 起動停止トラブルシューティング

## 対象症状

Eagle が起動途中で止まる、またはライブラリ切り替え後に画面が進まない事象を対象にする。

代表的な画面表示:

- `間もなく完了します......`
- `最初の初期化には時間がかかる場合があります...`

代表的なログ:

- `Get /images folders finished, total: ...` の後に `Library loaded` が出ない
- `TypeError: Cannot read properties of undefined (reading 'getItems')`
- `backgroundWindow has crashed, unknown reason`
- `API server start fail[1]`
- `cannot download url with net.ClientRequest: http://localhost:41595/api/check ... ERR_CONNECTION_REFUSED`

ログの場所:

```powershell
$env:APPDATA\Eagle\log.log
```

## 今回確認できた原因

### 1. ライブラリキャッシュの不整合

Eagle は `.library/images/*.info` の実体とは別に、ローカルキャッシュを持っている。

キャッシュの場所:

```powershell
$env:APPDATA\Eagle\library-caches
```

今回の初期状態では、対象ライブラリには `3694` 件の `.info` フォルダがあったが、対応するキャッシュには `76` 件しかなく、しかも全件 `isDeleted:true` だった。

この状態では Eagle が「実フォルダはあるが、キャッシュ上のアイテム一覧が存在しない/削除済みだけ」という矛盾を抱え、起動直前で止まることがある。

### 2. 孤立した `.info` フォルダ

再発時には、キャッシュ自体は正常に見えたが、`.library/images` にだけ存在し、キャッシュにも `mtime.json` にも存在しない `.info` フォルダがあった。

今回の例:

```text
MR77R2HRSECIP.info
MR77R2HRR5P2I.info
MR77R2HRZVD4G.info
```

特徴:

- `images` 直下には存在する
- `library-caches/*.txt` には存在しない
- `mtime.json` にも存在しない
- 中身一覧の取得で固まることがある

セカンドPC側で削除したアイテムが、Google Drive 同期の都合でこのPC側に `.info` フォルダだけ残った可能性が高い。

## 基本方針

原則として、ライブラリ本体を直接削除しない。

安全な順序:

1. Eagle を完全終了する
2. キャッシュや孤立フォルダを削除ではなく退避する
3. Eagle を起動してログで `Library loaded` まで進むか確認する

## 状況確認

### Eagle プロセス確認

```powershell
Get-Process |
  Where-Object { $_.ProcessName -match 'Eagle' } |
  Select-Object ProcessName,Id,CPU,PM,Responding,StartTime,Path |
  Format-Table -AutoSize
```

### ローカルポート確認

正常起動後は、少なくとも `41593` と `41595` が LISTENING になることが多い。

```powershell
netstat -ano | Select-String -Pattern ":4159|:4160"
```

目安:

- `41593`: Eagle 本体のローカルサーバー
- `41595`: Eagle の内部/APIサーバー
- `41596`: MCP Server プラグイン
- `41597`: AI モデル系プラグイン

`41595` が立たないまま `API server start fail[1]` が出る場合、読み込み完了後の内部API起動で詰まっている可能性がある。

### 現在のライブラリ確認

```powershell
$settingsPath = Join-Path $env:APPDATA "Eagle\Settings"
$settings = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$settings.rootDir
```

`libraryHistory` が `undefined` だけになっている場合は設定が壊れている可能性がある。

```powershell
$settings.libraryDirs
$settings.libraryHistory
```

## チェック: `.info` 件数とキャッシュ件数

対象ライブラリを `$library` に入れて確認する。

```powershell
$library = "I:\マイドライブ\pervert.library"
$cache = "$env:APPDATA\Eagle\library-caches\994413e5.txt"

[PSCustomObject]@{
  ImageFolders = (Get-ChildItem -Force (Join-Path $library "images") -Directory | Measure-Object).Count
  CacheLines   = (Get-Content -LiteralPath $cache | Measure-Object).Count
} | Format-List
```

件数が大きく違う場合は、キャッシュ不整合か孤立 `.info` を疑う。

## チェック: `images` にだけ存在する `.info`

```powershell
$library = "I:\マイドライブ\pervert.library"
$cache = "$env:APPDATA\Eagle\library-caches\994413e5.txt"

$cacheIds = New-Object 'System.Collections.Generic.HashSet[string]'
Get-Content -LiteralPath $cache | ForEach-Object {
  if ($_.Trim()) {
    try {
      $item = $_ | ConvertFrom-Json
      [void]$cacheIds.Add([string]$item.id)
    } catch {}
  }
}

$folderIds = Get-ChildItem -Force (Join-Path $library "images") -Directory |
  ForEach-Object { $_.Name -replace '\.info$', '' }

$missingInCache = $folderIds | Where-Object { -not $cacheIds.Contains([string]$_) }
$missingInCache
```

ここに出たIDが少数で、さらに `mtime.json` にも無い場合は孤立 `.info` の可能性が高い。

## チェック: `mtime.json` に存在するか

```powershell
$library = "I:\マイドライブ\pervert.library"
$ids = @("MR77R2HRSECIP", "MR77R2HRR5P2I", "MR77R2HRZVD4G")

$mtime = [System.IO.File]::ReadAllText((Join-Path $library "mtime.json"), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$ids | ForEach-Object {
  [PSCustomObject]@{
    Id = $_
    Mtime = $mtime.$_
  }
}
```

`Mtime` が空なら、Eagle の管理対象から外れた残骸の可能性がある。

## 対処A: キャッシュが壊れている場合

症状:

- キャッシュ件数が実フォルダ件数と大きく違う
- キャッシュ内のアイテムが削除済みだけになっている
- `libraryHistory` が `undefined` になっている

手順:

1. Eagle を完全終了する
2. `Settings` と対象キャッシュをバックアップする
3. `libraryDirs` / `libraryHistory` を `rootDir` と一致させる
4. 対象キャッシュを `.bak` などに退避する
5. Eagle を起動し、初期化が終わるまで待つ

キャッシュ退避例:

```powershell
$cache = "$env:APPDATA\Eagle\library-caches\994413e5.txt"
Move-Item -LiteralPath $cache -Destination "$cache.bak"
```

注意:

- 初回再生成は数分かかることがある
- 途中で強制終了すると、また中途半端なキャッシュになる可能性がある

## 対処B: 孤立 `.info` がある場合

症状:

- `images` の件数がキャッシュより少し多い
- `images` にだけ存在する `.info` がある
- そのIDが `mtime.json` に無い
- `Get /images folders finished` の後に `Library loaded` が出ない

手順:

1. Eagle を完全終了する
2. 孤立 `.info` を削除せず隔離フォルダへ移動する
3. `images` 件数とキャッシュ件数が揃ったことを確認する
4. Eagle を起動する
5. ログで `Library loaded` と `Local server: enabled` を確認する

隔離例:

```powershell
$library = "I:\マイドライブ\pervert.library"
$quarantine = Join-Path $library "_quarantine_$(Get-Date -Format yyyyMMdd_HHmmss)"
$ids = @("MR77R2HRSECIP", "MR77R2HRR5P2I", "MR77R2HRZVD4G")

New-Item -ItemType Directory -Path $quarantine -Force | Out-Null

foreach ($id in $ids) {
  $src = Join-Path $library "images\$id.info"
  if (Test-Path -LiteralPath $src) {
    Move-Item -LiteralPath $src -Destination $quarantine
  }
}
```

今回の隔離先:

```text
I:\マイドライブ\pervert.library\_codex_quarantine_20260705_1739
```

## 成功判定

ログに以下が出れば成功。

```text
Get /images folders finished, total: 3691
Cache no changes.
Library loaded
Local server: enabled
```

ポート確認でも `41595` が LISTENING になっていれば良い兆候。

```powershell
netstat -ano | Select-String -Pattern ":41595"
```

## やってはいけないこと

- `.library/images` 全体を削除しない
- `.library` 本体を丸ごと作り直さない
- Google Drive 同期中に Eagle を何度も強制終了しない
- 原因不明のままキャッシュと実体を同時に削除しない
- 孤立 `.info` をいきなり完全削除しない

## チェックツール化するなら

将来的には以下を自動化するとよい。

- Eagle プロセスの有無確認
- `Settings.rootDir` の取得
- 対応する `library-caches/*.txt` の特定
- `images/*.info` 件数とキャッシュ件数の比較
- `images` にだけ存在するIDの抽出
- `mtime.json` に存在しないIDの抽出
- 隔離候補の一覧表示
- ユーザー確認後に `_quarantine_YYYYMMDD_HHmmss` へ移動

自動ツールでも、削除ではなく隔離を基本動作にする。
