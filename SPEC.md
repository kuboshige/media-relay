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

```
Google Photos API（クラウド）
        ↑ OAuth認証・API連携
Pixel 5（常時充電・家/職場に設置）
  - Termux + Node.js サーバー
  - SQLite DB（ファイルステータス管理）
  - Termux:Boot で電源復帰時に自動起動
  - mDNSで自分のアドレスをWiFiネットワークにアナウンス
        ↑ ローカルWiFi通信（mDNSで自動検出）
Motorola Edge 50 Pro（メイン端末・持ち歩き）
  - Flutter製Androidアプリ
  - mDNSでPixelを自動検出（IP設定不要）
  - ファイル一覧・ステータス表示
  - 送信操作
```

## フェーズ計画

### Phase 1（MVP）
- [ ] モトローラアプリ：初回起動時にフォルダ選択（サムネ付き一覧でON/OFF）
- [ ] モトローラアプリ：mDNSでPixelを自動検出
- [ ] モトローラアプリ：手動で「送信」ボタンを押して転送
- [ ] モトローラアプリ：転送中断時のチャンクアップロード再開対応
- [ ] Pixel側：Node.jsで受信サーバー（Termux上）
- [ ] Pixel側：mDNSでサービスをアナウンス
- [ ] Pixel側：転送元のフォルダ構成を維持して保存
- [ ] 転送済みファイルの記録（SQLite）
- [ ] 未転送ファイルのみ送信（重複送信防止）
- [ ] ファイル削除機能は実装しない

### Phase 2
- [ ] ファイル削除機能（転送確認後にモトローラから削除）
- [ ] ステータス一覧表示（未送信 / 転送済み / フォトアップ済み / 重複 / クラウドオンリー）
- [ ] Google Photos API連携（アップロード確認・重複チェック）

### Phase 3
- [ ] 自動化（同じWiFiに接続したら自動転送）
- [ ] Pixel容量不足の検知・通知
- [ ] Google Photosのデータ削除機能

## 対象ファイル

- DCIM（カメラ撮影写真・動画）
- Screenshots（スクリーンショット）
- Download（SNS等からダウンロードした画像・動画）
- 対象フォルダは初回起動時に選択、後から変更可能

## Pixel側のファイル保存先

転送元のフォルダ構成をPixel側でも再現する。

```
モトローラ: /DCIM/Camera/        → Pixel: /DCIM/Camera/
モトローラ: /Pictures/Screenshots/ → Pixel: /Pictures/Screenshots/
モトローラ: /Download/Twitter/   → Pixel: /Download/Twitter/
```

Google フォトはDCIM・Picturesフォルダを自動検知してバックアップする。

## ファイルステータス定義（Phase 2以降）

| ステータス | 意味 |
|---|---|
| 未送信 | モトローラにのみ存在 |
| 転送済み | Pixelに送信完了、フォトバックアップ未確認 |
| フォトアップ済み | Google フォトへのバックアップ確認済み |
| 重複 | モトローラとGoogle フォト両方に存在 |
| クラウドオンリー | Google フォトのみに存在（モトローラから削除済み） |

重複チェックはGoogle Photos Library APIで「ファイル名 + 撮影日時」の一致で判定。
（APIの仕様上、ファイルの内容ハッシュは取得不可）

## 技術スタック

| 役割 | 技術 |
|---|---|
| モトローラアプリ | Flutter（Android APK、サイドロード） |
| Pixelサーバー | Node.js + Express（Termux上） |
| DB | SQLite |
| 通信 | HTTP（ローカルWiFi、チャンクアップロード対応） |
| デバイス自動検出 | mDNS（設定不要、ルーター設定不要） |
| 自動起動 | Termux:Boot |
| Google Photos連携 | Google Photos Library API（OAuth 2.0） |

## 機種変更時の移行

モトローラを機種変更しても簡単に移行できるよう設計する。

- 転送済み記録（SQLite）はエクスポート/インポート機能を提供
- アプリ設定（対象フォルダ等）はファイルにエクスポート可能
- 新端末にAPKをインストールして設定ファイルを読み込むだけで再開可能

## 制約・前提条件

- iOS対応なし
- 外部クラウドサーバーなし（コスト不要）
- 転送は同一WiFiネットワーク内のみ
- インストールはサイドロード（APKファイル直接インストール）
- Phase 1はファイル削除機能なし

## Google Photos API について

- Google Cloud Projectを作成（無料）
- Photos Library APIを有効化
- OAuth 2.0認証情報を作成
- テストユーザーに自分のGmailを登録するだけで利用可能
- アプリ審査・公開・課金は不要（個人利用の範囲）
