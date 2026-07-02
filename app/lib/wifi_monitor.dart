import 'package:flutter/services.dart';

/// Wi-Fi の接続イベント。
///
/// [connected] が true なら Wi-Fi 接続中、false なら切断。
/// [ssid] は接続中の Wi-Fi 名（取得不可なら null）。
class WifiEvent {
  final bool connected;
  final String? ssid;
  const WifiEvent({required this.connected, this.ssid});
}

/// Wi-Fi 接続状態の監視（Android プラットフォームチャンネル経由）。
///
/// 接続中 SSID を取得する [getCurrentSsid] と、
/// Wi-Fi の接続／切断を知らせる [events] を提供する。
///
/// SSID 取得は Android の API 制限（Android 10+ は位置情報権限が必要）により
/// null が返る場合がある。その場合でも接続／切断イベント自体は受け取れる。
class WifiMonitor {
  static const _eventChannel =
      EventChannel('com.kuboshige.media_relay/wifi_ssid');
  static const _channel =
      MethodChannel('com.kuboshige.media_relay/media_store');

  /// Wi-Fi の接続／切断が変化したとき発火するストリーム。
  static Stream<WifiEvent> get events =>
      _eventChannel.receiveBroadcastStream().map((e) {
        if (e is Map) {
          return WifiEvent(
            connected: e['connected'] == true,
            ssid: e['ssid'] as String?,
          );
        }
        // 後方互換: 旧実装が素の String / null を送ってきた場合。
        if (e is String) return WifiEvent(connected: true, ssid: e);
        return const WifiEvent(connected: false, ssid: null);
      });

  /// 現在接続中の Wi-Fi SSID を取得する（取得不可なら null）。
  static Future<String?> getCurrentSsid() async {
    try {
      return await _channel.invokeMethod<String>('getCurrentSsid');
    } catch (_) {
      return null;
    }
  }
}
