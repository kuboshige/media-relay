# media-relay アプリ

Motorola Edge 50 Pro で撮影・ダウンロードしたメディアを、Google Pixel 5 へ転送する Flutter 製 Android アプリ。送信側（Motorola）・受信側（Pixel）どちらにも同じ APK をインストールして使う。

## 概要

- **送信タブ**（Motorola）: メディアグリッドから選択して Wi-Fi 経由で Pixel へ送信
- **受信タブ**（Pixel）: HTTP サーバーを起動して待機。画面ロック後もバックグラウンド継続
- **設定タブ**: QRで接続先追加、起動時動作、リマインダー、受信設定

## インストール

Obtainium で `https://github.com/kuboshige/media-relay` を登録するか、GitHub Releases から APK を直接インストール。

## セットアップ手順

### Pixel（受信側）
1. アプリを開いて「受信」タブへ
2. 「開始」でサーバーを起動
3. 電池最適化の除外ダイアログが出たら「設定を開く」→「最適化しない」を選択（バックグラウンド継続に必須）
4. QR コードが表示される

### Motorola（送信側）
1. アプリを開いて「設定」タブへ
2. 右上の QR アイコン → Pixel に表示された QR を読み取る
3. 「送信」タブで送信対象を選択して送信

## 主な機能

| 機能 | 説明 |
|---|---|
| 一括送信 | 未送信ファイルを選択 or 全件一括送信 |
| 重複排除 | SHA256 受領台帳で送り直し防止（Google フォトの「空き容量を増やす」後も正確） |
| バックグラウンド送信 | フォアグラウンドサービスで最小化・画面オフでも継続 |
| バックグラウンド受信 | 電源ボタンでロック画面にしてもサーバーは継続動作（実機確認済み） |
| 送信して削除 | 送信成功分のみ端末から削除（Google フォト警告を送信**前**に表示） |
| タップでプレビュー | 選択なし状態でサムネイルをタップ → システムビューアで写真・動画を確認 |
| 受信ファイル一覧 | 受信タブの「N件」をタップ → サムネイルグリッドで確認・開く |
| QR接続 | 受信側 QR → 送信側でスキャンするだけで接続情報を登録 |
| ETA 表示 | 送信中に「あと○秒」「あと○分」で残り時間を表示 |
| 起動時自動送信 | 設定で「未送信を自動送信」「送信して削除」を選択可能 |
| 未送信リマインダー | 設定日数以上送信がなければ通知 |
| 空き容量表示 | Pixel の空き容量をサーバーバーに表示、不足時はバッチ中断 |

## ビルド

GitHub Actions が `app/**` 変更時に自動ビルドして GitHub Releases に APK を公開する。
ローカルビルドする場合（Flutter SDK 必須）:

```bash
cd app
flutter pub get
flutter pub run flutter_launcher_icons
flutter build apk --release
```

署名キーは `android/key.properties` + `android/app/release.keystore` で設定（CI では Secret から復元）。

## ファイル構成

```
app/
├── lib/
│   ├── main.dart                # MainShell（3タブ）+ HomePage（送信タブ）
│   ├── relay_server.dart        # アプリ内受信サーバー（Dart, shelf）
│   ├── receiver_page.dart       # 受信タブ
│   ├── received_files_page.dart # 受信ファイル一覧グリッド
│   ├── receiver_service.dart    # ReceiverForegroundService ラッパー
│   ├── uploader.dart            # 送信クライアント（/upload-raw ほか）
│   ├── app_settings.dart        # SharedPreferences ラッパー
│   ├── settings_page.dart       # 設定タブ
│   ├── result_detail_page.dart  # 送信結果詳細・強制削除
│   ├── qr_scan_page.dart        # QR 読み取り（mobile_scanner v7）
│   ├── server_config.dart       # サーバー登録・QR URI
│   ├── media_store.dart         # MediaStore MethodChannel ラッパー
│   ├── media_source.dart        # photo_manager ラッパー
│   ├── sent_store.dart          # 転送履歴 SQLite
│   ├── notif_service.dart       # 未送信リマインダー通知
│   ├── folder_select_page.dart  # 送信対象フォルダ選択
│   ├── folder_config.dart       # フォルダ設定保存
│   └── history_page.dart        # 送信履歴画面
├── android/app/src/main/kotlin/com/kuboshige/media_relay/
│   ├── MainActivity.kt              # MethodChannel ハンドラ（insertFile / openAsset / サービス制御）
│   ├── MediaStoreHelper.kt          # ContentResolver で MediaStore 登録
│   ├── UploadForegroundService.kt   # 送信フォアグラウンドサービス
│   └── ReceiverForegroundService.kt # 受信フォアグラウンドサービス
├── android/app/proguard-rules.pro  # ML Kit / CameraX keep rules（QR NPE 修正）
└── assets/icon/app_icon.png        # アプリアイコン（1024×1024, ティール色）
```
