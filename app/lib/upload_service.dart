import 'package:flutter/services.dart';

/// Androidフォアグラウンドサービスの起動・停止。
/// アプリがバックグラウンドに移動しても送信が中断されないようにする。
class UploadService {
  static const _ch =
      MethodChannel('com.kuboshige.media_relay/upload_service');

  static Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
