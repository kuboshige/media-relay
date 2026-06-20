# media-relay 仕様書

## 概要

Motorola Edge 50 Pro で撮影・ダウンロードしたメディアファイルを、Google Pixel 5 に転送するAndroidアプリ。
Pixel 5 の「Google フォト無制限バックアップ特典」を活用し、ストレージ課金なしに全メディアをGoogle フォトに集約することが目的。

## 背景・課題

- Pixel 5 はGoogle フォトへの無制限アップロード特典あり
- モトローラで撮影・ダウンロードしたファイルをPixelに転送 → PixelからGoogle フォトへ自動バックアップ
- 現状のクイックシェア運用の問題点：
  - 大量転送時にエラーが発生し、80枚ずつ小分けが必要
  - 転送済みデータとモトローラ内データが重複扱いされる
  - 完全に手動で非常に手間

## システム構成

> 注：以下は当初（Node受信）の構成。現在は**受信側もFlutterアプリへ統合中（Termux/Node廃止予定）**。
> 最新の実装状況は下の「【最重要】実装状況・引き継ぎメモ」を参照。

```
Google Photos（クラウド）
        ↑ Pixel 5が自動バックアップ（アプリからのAPI操作なし）
Pixel 5（常時充電・家/職場に設置）
  - Termux + Node.js サーバー
  - ファイルを /MediaRelay/ 以下に保存
  - Termux:Boot で電源復帰時に自動起動
        ↑ ローカルWiFi通信（HTTP）
Motorola Edge 50 Pro（メイン端末・持ち歩き）
  - Flutter製Androidアプリ
  - SQLite DB（転送履歴・ステータス管理）
  - ファイル一覧・ステータス表示・送信操作
```

---

## 【最重要】実装状況・引き継ぎメモ（2026-06-20時点）

新しいセッションはまずここを読むこと。`git log` と各ファイルで詳細を追える。

### これまでの経緯（ざっくり）
1. 当初は **Termux+Node.js を受信側**、**Flutter アプリを送信側（Motorola）** として MVP〜運用機能まで実装。
2. 「地獄のダブり」問題（Motorola のローカル原本と Pixel 経由クラウド版が Google フォトで二重表示）を、**送信→Pixel受領確認→Motorola側のローカル原本のみ削除** で解消する**削除機能**を実装。安全ゲートは `/exists`（受領台帳）＋ Android 標準削除ダイアログ。
3. Google フォトの「**空き容量を増やす**」でPixelディスクからファイルが消えると `/exists` が壊れる問題を、**永続受領台帳**（`received-hashes.txt`）で解決（ディスク存在に依存しない）。
4. **方針転換**：受信側も Flutter アプリに統合し、**1つのアプリで送受信**、**Termux/Node を廃止**する方向で開発中（ユーザー要望）。あわせて **初回接続を QR＋mDNS で簡単に**する。

### 現在のアプリ構成（`app/lib/`）
- `main.dart` … 送信モードのメイン画面（メディア一覧・選択・送信・削除・履歴・⋮メニューから受信モード）。
- `relay_server.dart` … **アプリ内受信サーバー（Dart, shelf）**。`/ping /exists /upload /upload-raw /reindex /setdate /scan` を実装。永続台帳・LAN IP列挙（`localIps`）。
- `receiver_page.dart` … **受信モード画面**。IP一覧（Wi-Fi優先・VPN等は既定非表示）、**QR表示**、デバイス名編集、受信進捗、開始/停止、wakelock。
- `qr_scan_page.dart` … 送信側の **QR読み取り**（mobile_scanner）。※下記の既知不具合あり。
- `uploader.dart` … 送信クライアント。`upload`(multipart, 旧node用) と **`uploadRaw`**(生バイト, dart:io HttpClient, アプリ内受信用)、`ping/info/exists/reindex/scan/setdate`。`ServerInfo` に `app`（アプリ内受信か）/`mediaScan` フラグ。
- `app_settings.dart` … reminderDays / lastSync / receiverPort / **deviceName**。
- `notif_service.dart` … 未送信リマインダー（ローカル通知、デッドマンスイッチ式、日数は設定可）。
- `server_config.dart` … サーバー登録（複数）＋ **QR用 `buildConnectUri`/`fromConnectUri`**（`mediarelay://connect?host&port&name`）。
- `folder_select_page.dart` … 送信対象フォルダ選択（タップで中身プレビュー、トグルで対象ON/OFF）。
- `settings_page.dart` … サーバー設定＋リマインダー設定＋**「QRで追加」**。
- `media_source.dart` / `sent_store.dart` / `history_page.dart` / `folder_config.dart` … 既存。
- `server/`（Node.js）… 旧受信側。**まだ残っているが、in-app receiver へ移行中**。永続台帳の実装は `server/index.js` 参照。

### アプリ内受信（移行）の到達点
- 送信側は `/ping` の `app:true` を見て、アプリ内受信には **`/upload-raw`（生バイト・dart:io HttpClient）** を使う（multipart はレスポンス待ちが返らず固まったため）。
- 受信は**ストリームで一時ファイルに書きつつ逐次SHA256**（大動画でメモリ枯渇しない）→ rename。
- `/scan`（MediaStore登録）はアプリ内受信では No-op。送信側は `mediaScan:false` を見て **scan呼び出しをスキップ**。
- IP列挙は wlan 優先、`tun/ppp/rmnet` 等は `virtual=true` で既定非表示（AdGuard VPN の `172.18.x` 等を除外）。受信画面に「VPN等も表示」トグル。
- システムメッセージとQRは **送信先の表示名（`server.name`/`deviceName`）** を使う（「Pixel」固定をやめた）。

### 既知の不具合・WIP（次セッションの最優先）
1. **送信完了後にUIが「送信中」のまま固まる（最優先）**
   - 症状：大きいファイル送信で、**ファイルは実際に転送・記録される**（再起動すると送信済みになっている＝`markSent`実行済み）が、**送信完了後のUI更新が止まる**。進捗表示が末尾付近（例 70.0/70.4MB）で固まる。
   - 切り分け：`upload()` は成功して返っている（台帳・sent_store に載る）。`_send` の **ループ後（post-loop）の処理がハング**して最後の `setState(_status=null)` に到達していない疑い。`markSynced()`（通知再予約）が有力候補。
   - 今セッションの暫定対応（このコミット、**要ビルド検証**）：`markSynced()` を `timeout(5s)` で囲い、`info()` も try で握りつぶして**必ず完了表示に進む**ように。進捗 `setState` を**1MB毎→約1秒間引き**に変更（全画面再描画のチラつき対策）。
   - 根本原因（なぜ post-loop がハングするか）は未特定。次セッションで要調査。
2. **QRカメラが起動しない**：`MobileScannerErrorCode.genericError` ＋ ネイティブ `getClass() on null`。mobile_scanner 5.2.3 でも 6.0.10 でも同一 → **その端末のカメラ/ML Kit層の問題**でDartからは直せない可能性大。**フォールバックは手動IP入力**（受信画面のIPテキストを見て設定の「＋」）。
3. **受信ファイルがGoogleフォトに出ない**：アプリ内受信は今 `Android/data/<pkg>/files/MediaRelay`（アプリ専用領域）に保存。**MediaStore登録（=Step③）未実装**のためフォト非表示。**これが実用化の最大の穴**。

### 今後の課題（優先順）
1. **③ MediaStore登録**（受信ファイルをGoogleフォトに出す）＝最優先。ネイティブKotlin＋platform channel、または公開ストレージ＋MediaScanner。scoped storage対応が肝。`/scan` 相当を実装し、`/ping` の `mediaScan:true` を返すように。
2. **② フォアグラウンドサービス常駐**（画面OFF/バックグラウンドでも受信継続）。`flutter_foreground_task` 等。今は受信画面を開いて画面ON中のみ稼働（wakelockで点きっぱ）。
3. **送信完了ハングの根治**（暫定timeout対応の根本原因特定）。
4. **QR読み取りの代替**（別パッケージ検討 or 標準カメラのディープリンク `mediarelay://`）。
5. **mDNS自動発見**（QRと併用、`multicast_dns`/`nsd`）。
6. Termux/Node の完全廃止（上記が揃ったら）。

### ビルド・配布・運用
- **GitHub Actions**：`.github/workflows/build-apk.yml` が release APK をビルド。バージョン名は `run_number` → `v1.0.<n>`。署名キーは Secret（更新インストール可）。
- **配布**：両端末に **Obtainium** で配布（GitHub Releases）。
- **開発ブランチ**：`claude/busy-franklin-phpf16`。`main` に勝手にpushしない。
- ローカルに Flutter SDK は無い → **CIビルドで検証**（push して Actions の成否を見る）。Node依存もCIに無いのでサーバ動作はユーザー実機で確認。
- 旧Node受信を使う場合：Termux で `cd ~/media-relay/server && node index.js`（`pkill node` で停止）。アプリ内受信とポート8765が衝突するので**同時起動不可**。

### 接続情報フォーマット（QR/mDNS）
- 接続URI：`mediarelay://connect?host=<ip>&port=<port>&name=<表示名>`（`ServerEntry.buildConnectUri/fromConnectUri`）。

---

## 開発順序

### なぜこの順序か
「まず実用品として使える状態を作る」を優先する。各ステップで動作確認できる状態にする。

---

### Step 1：Pixelサーバー最小版
**目標：** ファイルを受け取ってディスクに保存できる

- [ ] Node.js + Express でファイル受信エンドポイント（`POST /upload`）
- [ ] 受け取ったファイルを `/MediaRelay/` 以下にフォルダ構造を維持して保存
- [ ] ファイル存在確認エンドポイント（`GET /exists?hash=xxxx`）
- [ ] Termux上で手動起動できる状態にする
- [ ] **確認方法：** curlコマンドで画像を送って届くか確認

---

### Step 2：モトローラアプリ最小版（1枚送れる状態）
**目標：** アプリからPixelに1ファイル転送できる

- [ ] Flutter プロジェクト作成
- [ ] ストレージ読み取り権限の取得
- [ ] DCIMフォルダのファイル一覧を画面に表示
- [ ] Pixelのサーバーアドレスを手入力で設定・保存（複数登録可）
- [ ] ファイルを1つ選んで「送信」ボタンで転送
- [ ] 送信時に `relativePath` をメタデータとして付与（フォルダ構造維持）
- [ ] **確認方法：** Pixelに画像が届き、正しいフォルダに保存されることを確認

---

### Step 3：SQLiteによる転送管理（重複送信防止）
**目標：** 送ったファイルを記録し、次回は未送信だけ送る

- [x] モトローラアプリにSQLite導入（sqflite）
- [x] 転送済みファイルを記録（SHA256 / file_size / modified_time / relative_path / sent_at / status）
- [x] 重複判定はSHA256を使用（MD5は不採用）。送信時に `GET /exists?hash=` で照合し既存ならスキップ
- [x] 日常運用の「未送信のみ表示」は端末内で安定した asset_id で高速判定（SHA256はサーバー照合・機種変更用に保存）
- [x] アプリ起動時に未送信ファイルのみリストアップ（送信済みはメニューから表示切替可）
- [x] 「未送信をすべて送信」ボタンで一括送信
- [ ] **確認方法：** 2回目起動で同じファイルがスキップされることを確認

---

### Step 4：チャンクアップロード（大容量動画対応）
**目標：** 転送中断しても途中から再開できる

- [ ] ファイルを分割して順番に送信（チャンク方式）
- [ ] Pixelサーバー：途中まで受信済みなら続きから受け付ける
- [ ] モトローラアプリ：`GET /exists?hash=xxxx` で再送時に続きを確認
- [ ] **確認方法：** 転送中にWiFiを切って再接続し、途中から再開されることを確認

---

### Step 5：Termux:Boot対応（Pixel自動起動）
**目標：** Pixel再起動後にサーバーが自動で立ち上がる

- [x] Termux:Boot 用の起動スクリプト作成（`server/boot/start-media-relay.sh`、wake-lock付き）
- [ ] **確認方法：** Pixelを再起動してサーバーが自動起動するか確認

---

**ここまでで MVP 完成。日常使いできる状態。**

---

### Step 6：mDNS導入（IP設定不要にする）
**目標：** IPアドレスを意識せず繋がる

- [ ] Pixelサーバー：mDNSで `media-relay.local` としてアナウンス
- [ ] モトローラアプリ：mDNSで自動検出、失敗時は手動設定にフォールバック
- [ ] **確認方法：** IP設定なしで自動接続されることを確認

---

### Step 7：フォルダ選択UI（初回セットアップ）
**目標：** どのフォルダを転送対象にするか選べる

- [x] フォルダ一覧 + サムネ表示（アルバム単位、件数表示）
- [x] フォルダごとにON/OFFトグル（全選択／全解除ショートカット付き）
- [x] 設定を保存（次回起動時に引き継ぎ。未設定時は全フォルダON）
- [x] 設定画面（フォルダアイコン）からいつでも変更可能
- メディア一覧は撮影日時の降順（新しい順）で表示するよう修正

---

### Step 8：設定エクスポート（機種変更対応）
**目標：** 新しいAndroidに移行しても設定・記録を引き継げる

- [ ] 転送済み記録（SQLite）をJSONでエクスポート/インポート
- [ ] サーバーアドレス・対象フォルダ設定をJSONでエクスポート/インポート

---

### Phase 2：Google Photos連携（将来）
- [x] ファイル削除機能（削除直前にPixelへSHA256で存在確認し、確認できたものだけ端末の削除ダイアログ経由で削除）
- [ ] Google Photos Library API でバックアップ確認（ファイル名 + 撮影日時で照合）
- [ ] ステータス拡張（フォトアップ済み / 重複 / クラウドオンリー）

### Phase 3（将来）
- [ ] 自動化（同じWiFiに接続したら自動転送）
- [x] Pixel容量不足の検知・通知（`/ping` で空き容量表示、不足時は `/upload` が 507 を返しバッチ中断）
- [ ] Google Photosのデータ削除機能

### 実用化の追加機能（MVP後の改善）
- [x] 送信中の画面スリープ防止（wakelock）— スリープで転送が止まるのを防ぐ
- [x] 送信履歴/ログ画面（送信 / スキップ / 失敗を記録・表示、消去可）
- [x] Pixel空き容量の表示と不足時のバッチ中断
- [ ] 完全バックグラウンド送信（最小化・画面オフでも継続：フォアグラウンドサービス）
- [ ] 自動送信（指定WiFi接続で未送信を自動転送）

---

## 対象ファイル

- DCIM（カメラ撮影写真・動画）
- Screenshots（スクリーンショット）
- Download（SNS等からダウンロードした画像・動画）
- 対象フォルダはStep 7で選択UI実装。それ以前はDCIM・Screenshots・Downloadを固定で対象とする。

## Pixel側のファイル保存先

専用フォルダ `/MediaRelay/` 以下にフォルダ構造を再現して保存する。

```
/MediaRelay/DCIM/Camera/
/MediaRelay/Pictures/Screenshots/
/MediaRelay/Download/Twitter/
```

- 誤削除時の影響を他フォルダに及ぼさない
- 他アプリのファイルと混在しない
- Google フォトでフォルダ単位のバックアップ設定が可能

## ファイルステータス定義

### MVP（Step 3完了時点）

| ステータス | 意味 |
|---|---|
| 未送信 | モトローラにのみ存在、未転送 |
| 転送中 | 現在送信中 |
| 転送済み | Pixelへの送信完了 |
| 失敗 | 転送エラー（再送可能） |

### Phase 2以降（Google Photos API連携後）

| ステータス | 意味 |
|---|---|
| フォトアップ済み | Google フォトへのバックアップ確認済み |
| 重複 | モトローラとGoogle フォト両方に存在 |
| クラウドオンリー | Google フォトのみに存在（モトローラから削除済み） |

## 重複判定・転送履歴のデータ設計

モトローラ側SQLiteに以下を保存：

| カラム | 内容 |
|---|---|
| sha256 | ファイル内容のハッシュ（重複判定に使用） |
| file_size | ファイルサイズ（バイト） |
| modified_time | ファイルの更新日時 |
| relative_path | 元フォルダからの相対パス |
| sent_at | 送信完了日時 |
| status | 未送信 / 転送中 / 転送済み / 失敗 |

Pixel側に本格的なDBは持たない（MVP時点）。受領確認は `GET /exists?hash=xxxx` で行う。

### サーバー側 受領台帳（永続）

`/exists` は「**Pixelが一度でも受け取った／見た内容（SHA256）か**」で判定する。
ディスクに今あるかは問わない。理由は Googleフォトの「**空き容量を増やす**」が
クラウドへバックアップ済みのローカルファイルをPixelから削除するため。ディスク存在
だけで判定すると、① 再送でクラウド重複が発生、② バックアップ済みなのにMotorola側
の元ファイルを削除できない、が起きる（＝「Pixelに無い＝消して危険」と誤判定）。

- 受領ハッシュを `<STORAGE_ROOT>/.state/received-hashes.txt` に追記して永続化
  （実体が消えても判定不変。`STATE_DIR` で場所変更可。隠しファイル/フォルダは走査対象外）
- 過去にクイックシェアで送ったファイルも取り込むため、起動時とreindex時にディスクを走査
  - 照合対象（既定）：`/sdcard/MediaRelay`、`/sdcard/Download/Quick Share`、`/sdcard/Download`
  - 環境変数 `SCAN_DIRS`（`:` 区切り）で変更可能
- 保持する集合は「台帳 ∪ ディスク走査結果」で**決して縮まない**
- `POST /upload` 時は受領ハッシュを台帳へ追記
- `POST /reindex` でディスクを再走査して新規受信を台帳へ取り込む（台帳は消さない）
- アプリは一括送信の前に `/reindex` を呼び、既にPixelが受領済みの内容は**アップロードせずスキップ＋送信済み登録**する
- 削除機能も同じ `/exists`（受領済み判定）を安全ゲートに使う

## 技術スタック

| 役割 | 技術 |
|---|---|
| モトローラアプリ | Flutter（Android APK、サイドロード） |
| Pixelサーバー | Node.js + Express（Termux上） |
| DB | SQLite（モトローラ側のみ） |
| 通信 | HTTP（ローカルWiFi、チャンクアップロード対応） |
| デバイス検出 | 手入力（複数登録可）→ Step 6でmDNSに移行 |
| 自動起動 | Termux:Boot |
| Google Photos連携 | Phase 2以降（Google Photos Library API） |

## 機種変更時の移行

- 転送済み記録（SQLite）はJSONエクスポート/インポート対応
- サーバーアドレス・対象フォルダ設定もエクスポート可能
- 新端末にAPKをインストールして設定ファイルを読み込むだけで再開可能

## 制約・前提条件

- iOS対応なし
- 外部クラウドサーバーなし（コスト不要）
- 転送は同一WiFiネットワーク内のみ
- インストールはサイドロード（APKファイル直接インストール）
- ファイル削除機能はPhase 2まで実装しない

## Google Photos API について（Phase 2以降）

- Google Cloud Projectを作成（無料）
- Photos Library APIを有効化
- OAuth 2.0認証情報を作成
- テストユーザーに自分のGmailを登録するだけで利用可能
- アプリ審査・公開・課金は不要（個人利用の範囲）
- 重複チェックは「ファイル名 + 撮影日時」で判定（APIの仕様上、内容ハッシュは取得不可）
