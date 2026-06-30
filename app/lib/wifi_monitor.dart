import 'package:flutter/services.dart';

/// Wi-Fi 接続状態の監視（Android プラットフォームチャンネル経由）。
///
/// 接続中 SSID を取得する [getCurrentSsid] と、
/// Wi-Fi 状態変化を知らせる [ssidStream] を提供する。
///
/// SSID 取得は Android の API 制限（Android 10+ は位置情報権限または
/// NEARBY_WIFI_DEVICES が必要）により null が返る場合がある。
/// その場合でも接続／切断イベントは受け取れる。
class WifiMonitor {
  static const _eventChannel =
      EventChannel('com.kuboshige.media_relay/wifi_ssid');
  static const _channel =
      MethodChannel('com.kuboshige.media_relay/media_store');

  /// Wi-Fi 状態が変化したとき発火するストリーム。
  /// 値は SSID 文字列（接続時）または null（切断時／SSID 取得不可時）。
  static Stream<String?> get ssidStream => _eventChannel
      .receiveBroadcastStream()
      .map((e) => e is String ? e : null);

  /// 現在接続中の Wi-Fi SSID を取得する（取得不可なら null）。
  static Future<String?> getCurrentSsid() async {
    try {
      return await _channel.invokeMethod<String>('getCurrentSsid');
    } catch (_) {
      return null;
    }
  }
}
