# Privacy Policy / プライバシーポリシー

*Last updated: 2025*

---

## English

### Summary

MediaRelay is a local-network file transfer app. It does **not** collect, store, or transmit any personal data to external servers or third parties.

### Data accessed

| What | Why |
|---|---|
| Photos and videos on your device | To display the media grid on the sender side and transfer selected files |
| Camera | To scan QR codes for connection setup |
| Local network (Wi-Fi) | To transfer files between your two devices over Wi-Fi |
| Notifications | To send unsent-file reminders (optional, enabled in Settings) |

### What we do NOT do

- We do not send any data to the internet or to Anthropic, Google, or any other third party.
- We do not collect analytics, crash reports, or usage statistics.
- We do not store any data outside your own devices.
- All transferred files go directly from one device to the other on your local Wi-Fi network.

### Permissions explained

- `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` / `READ_EXTERNAL_STORAGE`: Read media files for transfer.
- `INTERNET`: Required by Flutter and for local Wi-Fi HTTP transfers (no external connections are made by this app).
- `CAMERA`: QR code scanning only.
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`: Keep the transfer running when the screen is off.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Keep the receiver server alive in the background.
- `POST_NOTIFICATIONS`: Unsent-file reminder notifications.
- `RECEIVE_BOOT_COMPLETED`: Restore scheduled reminders after reboot.

### Contact

Questions? Open an issue at https://github.com/kuboshige/media-relay

---

## 日本語

### 概要

MediaRelay はローカルネットワーク上でファイルを転送するアプリです。個人データを外部サーバーや第三者に送信・収集・保存することは一切ありません。

### アクセスするデータ

| 項目 | 理由 |
|---|---|
| 端末内の写真・動画 | 送信側のメディアグリッド表示と、選択ファイルの転送 |
| カメラ | 接続設定のQRコードスキャン |
| ローカルネットワーク（Wi-Fi） | 2台の端末間でWi-Fi経由のファイル転送 |
| 通知 | 未送信ファイルのリマインダー（任意・設定から変更可能） |

### 行わないこと

- インターネット・Anthropic・Google・その他の第三者へのデータ送信は一切行いません。
- 分析情報・クラッシュレポート・利用統計の収集は行いません。
- お客様の端末の外にデータを保存しません。
- 転送されたファイルはすべてWi-Fi上で2台の端末間で直接やり取りされます。

### 権限の説明

- `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` / `READ_EXTERNAL_STORAGE`: 転送するメディアファイルの読み取り。
- `INTERNET`: Flutter の要件、およびローカルWi-Fi HTTP転送のため（外部への通信はありません）。
- `CAMERA`: QRコードスキャンのみ。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`: 画面オフ中も転送を継続。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: バックグラウンドで受信サーバーを維持。
- `POST_NOTIFICATIONS`: 未送信ファイルのリマインダー通知。
- `RECEIVE_BOOT_COMPLETED`: 再起動後のリマインダー予約復元。

### お問い合わせ

ご不明点は https://github.com/kuboshige/media-relay へ Issue でお寄せください。
