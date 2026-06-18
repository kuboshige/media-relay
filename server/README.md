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
| GET | `/ping` | サーバー死活確認（空き容量も返す） |
| POST | `/upload` | ファイルアップロード（空き不足時は507） |
| GET | `/exists?hash=<sha256>` | ファイル存在確認（ハッシュ索引で照合） |
| POST | `/reindex` | ハッシュ索引を再構築（クイックシェア新規受信を取り込む） |
| POST | `/scan` | 保存ファイルをMediaStoreに登録（Googleフォト表示用） |

### Googleフォトに出すためのメディアスキャン（重要）

サーバーが直接書き込んだファイルはAndroidのMediaStoreに未登録のため、
そのままではGoogleフォトの「端末内フォルダ」に出てこない。`termux-api` を
入れておくと、アプリが送信後に `POST /scan` を呼んで自動登録する。

```bash
pkg install termux-api
```

さらに **F-Droidから「Termux:API」アプリ** も必要（コマンドと対になる）。
手動で登録したい場合：

```bash
termux-media-scan -r /sdcard/MediaRelay
```

登録後、Googleフォト → ライブラリ → 端末内フォルダ で `MediaRelay` 配下が
表示され、バックアップ対象に指定できる。

### 重複判定とクイックシェア照合（SCAN_DIRS）

`/exists` は対象フォルダ配下のSHA256索引（メモリ）で判定する。クイックシェアで
既にPixelへ送ったファイルも検出できるよう、既定で以下を走査する：

- `/sdcard/MediaRelay`
- `/sdcard/Download/Quick Share`（クイックシェアの現在の受信先）
- `/sdcard/Download`

変更したい場合は環境変数で指定（`:` 区切り）：

```bash
SCAN_DIRS="/sdcard/MediaRelay:/sdcard/Download/Quick Share" node index.js
```

起動直後にバックグラウンドで索引を構築する（ファイル数が多いと数十秒〜かかる）。
新たにクイックシェア受信したら `POST /reindex` で取り込む。

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
