# MediaRelay

> Transfer photos and videos from Motorola Edge 50 Pro → Google Pixel 5 over Wi-Fi.  
> One APK — install it on both devices. No cloud required.

[![Build APK](https://github.com/kuboshige/media-relay/actions/workflows/build-apk.yml/badge.svg)](https://github.com/kuboshige/media-relay/actions/workflows/build-apk.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-teal.svg)](LICENSE)

---

## English

### What it does

| Feature | Description |
|---|---|
| Batch transfer | Select unsent files or send all at once |
| Deduplication | SHA-256 ledger prevents re-sending (survives Google Photos "free up space") |
| Background send | Foreground service keeps sending with the screen off |
| Background receive | Screen lock does not stop the server (verified on real device) |
| Send & delete | Deletes only successfully transferred files; warns before deleting |
| Tap to preview | Tap a thumbnail with no selection → opens the system viewer |
| Received files list | Tap the session count → thumbnail grid of received files |
| QR connection | Scan the receiver's QR from the sender — done |
| ETA display | Shows "Xm Ys remaining" during transfer |
| Auto-send on launch | Configurable: send unsent / send and delete / do nothing |
| Unsent reminder | Notification after N days without sending |
| Free space display | Shows receiver's free space; pauses batch if low |
| Session token auth | 16-char random token in QR prevents unauthorized uploads |

### Install

**Recommended:** Use [Obtainium](https://github.com/ImranR98/Obtainium) and add this repository URL to get automatic updates.

Or download the APK directly from [GitHub Releases](https://github.com/kuboshige/media-relay/releases/latest).

> **Pixel (recommended receiver)** works out of the box.  
> Other Android devices may have aggressive battery optimization — see [dontkillmyapp.com](https://dontkillmyapp.com/) if the server keeps stopping.

### Requirements

- Android 10 (API 29) or later
- Both devices on the same Wi-Fi network

### Quick start

**Pixel (receiver):**
1. Open the app → **Receive** tab → tap **Start**
2. If prompted, exclude the app from battery optimization → "Don't optimize"
3. A QR code appears

**Motorola (sender):**
1. Open the app → **Settings** tab → tap the QR icon → scan the Pixel's QR
2. Switch to the **Send** tab → select files → tap **Send**

### Build

```bash
cd app
flutter pub get
flutter pub run flutter_launcher_icons
flutter build apk --release
```

CI builds automatically on every push to `app/**` and publishes to GitHub Releases.

---

## 日本語

### 概要

Motorola Edge 50 Pro で撮影・ダウンロードしたメディアを Google Pixel 5 へ Wi-Fi 転送する Flutter 製 Android アプリ。同じ APK を両端末にインストールして使います。

### 機能一覧

| 機能 | 説明 |
|---|---|
| 一括送信 | 未送信ファイルを選択 or 全件一括送信 |
| 重複排除 | SHA-256 受領台帳で送り直し防止（Google フォト「空き容量を増やす」後も正確） |
| バックグラウンド送信 | フォアグラウンドサービスで最小化・画面オフでも継続 |
| バックグラウンド受信 | ロック画面でもサーバーは継続動作（実機確認済み） |
| 送信して削除 | 送信成功分のみ端末から削除（Google フォト警告を送信前に表示） |
| タップでプレビュー | 選択なし状態でサムネイルをタップ → システムビューアで確認 |
| 受信ファイル一覧 | 受信タブの「N件」をタップ → サムネイルグリッド |
| QR 接続 | 受信側 QR → 送信側でスキャンするだけで接続情報を登録 |
| ETA 表示 | 送信中に「あと○分○秒」で残り時間を表示 |
| 起動時自動送信 | 設定で「未送信を自動送信」「送信して削除」を選択可能 |
| 未送信リマインダー | 設定日数以上送信がなければ通知 |
| 空き容量表示 | 受信側の空き容量をバーに表示、不足時はバッチ中断 |
| セッショントークン認証 | QR にランダムトークンを埋め込み、第三者からのアップロードを防止 |

### インストール

**推奨:** [Obtainium](https://github.com/ImranR98/Obtainium) にこのリポジトリ URL を登録すると自動更新が可能です。

または [GitHub Releases](https://github.com/kuboshige/media-relay/releases/latest) から APK を直接インストール。

> **Pixel（推奨受信端末）** はそのまま動作します。  
> Pixel 以外でサーバーが止まる場合は [dontkillmyapp.com](https://dontkillmyapp.com/) を参照し、該当機種の設定を行ってください。

### 動作要件

- Android 10（API 29）以上
- 送受信端末が同じ Wi-Fi ネットワークに接続されていること

### セットアップ

**Pixel（受信側）:**
1. アプリを開いて「受信」タブへ
2. 「開始」でサーバーを起動
3. 電池最適化の除外ダイアログが出たら「設定を開く」→「最適化しない」
4. QR コードが表示される

**Motorola（送信側）:**
1. アプリを開いて「設定」タブへ
2. QR アイコン → Pixel に表示された QR を読み取る
3. 「送信」タブで対象を選択して送信

### ビルド

```bash
cd app
flutter pub get
flutter pub run flutter_launcher_icons
flutter build apk --release
```

`app/**` への push 時に GitHub Actions が自動ビルドし、GitHub Releases に APK を公開します。

---

## License

[MIT](LICENSE) © 2025 kuboshige

## Privacy

[Privacy Policy](PRIVACY.md) — local network only, no external data collection.
