# media-relay サーバー（Pixel 5 / Termux用）

## セットアップ手順

### 1. Termuxのインストール
F-Droid から **Termux** をインストールする（Google Play版は古いので不可）。

### 2. Node.jsのインストール
Termux内で以下を実行：
```bash
pkg update && pkg install nodejs
```

### 3. このフォルダをPixelに転送
PCからADB、またはUSBファイル転送でPixelの適当な場所に置く。
例: `/data/data/com.termux/files/home/media-relay/server/`

### 4. 依存パッケージのインストール
```bash
cd server
npm install
```

### 5. サーバー起動
```bash
bash start.sh
```

起動後、ブラウザや他端末から `http://<PixelのIPアドレス>:8765/ping` にアクセスして `{"ok":true}` が返れば成功。

---

## Termux:Boot 自動起動設定

**Termux:Boot** をF-Droidからインストールし、以下のファイルを作成する：

```bash
mkdir -p ~/.termux/boot
```

`~/.termux/boot/start-media-relay.sh` を作成：
```bash
#!/data/data/com.termux/files/usr/bin/bash
cd ~/media-relay/server
node index.js &
```

```bash
chmod +x ~/.termux/boot/start-media-relay.sh
```

これでPixel再起動後にサーバーが自動起動する。

---

## APIエンドポイント

| メソッド | パス | 説明 |
|---|---|---|
| GET | `/ping` | サーバー死活確認 |
| POST | `/upload` | ファイルアップロード |
| GET | `/exists?hash=<sha256>` | ファイル存在確認 |

### POST /upload
```
Content-Type: multipart/form-data
  file:         バイナリデータ
  relativePath: 保存先の相対パス（例: DCIM/Camera/photo.jpg）
```

レスポンス例：
```json
{ "ok": true, "relativePath": "DCIM/Camera/photo.jpg", "sha256": "abc...", "size": 1234 }
```

### GET /exists?hash=\<sha256\>
レスポンス例：
```json
{ "exists": true }
```

---

## ファイルの保存先

Termux環境では `/sdcard/MediaRelay/` 以下に保存される。

```
/sdcard/MediaRelay/DCIM/Camera/
/sdcard/MediaRelay/Pictures/Screenshots/
/sdcard/MediaRelay/Download/Twitter/
```

Google フォトでこのフォルダをバックアップ対象に設定すること。

## ポート番号の変更

デフォルトは `8765`。変更する場合は環境変数で指定：
```bash
PORT=9000 node index.js
```
