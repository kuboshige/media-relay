#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot 用の起動スクリプト。
# Pixel の電源を入れた／再起動したときに media-relay サーバーを自動起動する。
#
# 配置方法（Termux内で1回だけ）:
#   mkdir -p ~/.termux/boot
#   cp ~/media-relay/server/boot/start-media-relay.sh ~/.termux/boot/start-media-relay.sh
#   chmod +x ~/.termux/boot/start-media-relay.sh
#
# 前提:
#   - F-Droid から「Termux:Boot」アプリを入れ、一度起動しておく
#   - termux-api（pkg install termux-api）が入っていると wake-lock が効く
#   - Termux / Termux:Boot のバッテリー最適化を「制限なし」にしておく

# Android のスリープ（Doze）でサーバーが止まらないよう wake-lock を取得。
# termux-api 未導入でも以降の起動は続行する。
termux-wake-lock 2>/dev/null

# サーバー起動。ログは ~/media-relay-boot.log に残す。
cd "$HOME/media-relay/server" || exit 1
exec node index.js >> "$HOME/media-relay-boot.log" 2>&1
