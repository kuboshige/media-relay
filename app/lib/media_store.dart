import 'package:flutter/services.dart';

/// Android MediaStore への登録（platform channel 経由）。
/// Android 10+ (API 29+) 専用。それ未満では常に null を返す。
class MediaStore {
  static const _channel =
      MethodChannel('com.kuboshige.media_relay/media_store');

  /// 一時ファイルを MediaStore（公開ストレージ /sdcard/MediaRelay/...）に登録する。
  ///
  /// [sourcePath]     書き込み済みの一時ファイルのフルパス（呼び出し元が後で削除する）
  /// [relativePath]   元のパス（例: DCIM/Camera/photo.jpg）
  /// [originalDateMs] 撮影日時ミリ秒。0 なら設定しない
  /// [mimeType]       null なら拡張子から推定
  ///
  /// 成功時は content:// URI 文字列、失敗時は null。
  static Future<String?> insertFile({
    required String sourcePath,
    required String relativePath,
    int originalDateMs = 0,
    String? mimeType,
  }) async {
    try {
      final uri = await _channel.invokeMethod<String>('insertFile', {
        'sourcePath': sourcePath,
        'relativePath': relativePath,
        'originalDateMs': originalDateMs,
        'mimeType': mimeType,
      });
      return uri;
    } catch (_) {
      return null;
    }
  }
}
