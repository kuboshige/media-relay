import 'package:flutter/services.dart';

/// Android MediaStore への登録（platform channel 経由）。
/// Android 10+ (API 29+) 専用。
class MediaStore {
  static const _channel =
      MethodChannel('com.kuboshige.media_relay/media_store');

  /// 一時ファイルを MediaStore に登録する。
  /// 成功時は content:// URI 文字列、失敗時は null（サーバーコールバック用）。
  static Future<String?> insertFile({
    required String sourcePath,
    required String relativePath,
    int originalDateMs = 0,
    String? mimeType,
  }) async {
    final r = await insertFileResult(
        sourcePath: sourcePath,
        relativePath: relativePath,
        originalDateMs: originalDateMs,
        mimeType: mimeType);
    return r.uri;
  }

  /// [insertFile] と同じだが、失敗時にエラー文字列も返す。
  /// 移行ダイアログなど、原因を表示したい箇所で使う。
  static Future<({String? uri, String? error})> insertFileResult({
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
      return (uri: uri, error: null);
    } on PlatformException catch (e) {
      return (uri: null, error: e.message ?? e.code);
    } catch (e) {
      return (uri: null, error: e.toString());
    }
  }
}
