import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'server_config.dart';

/// アップロード結果
class UploadResult {
  final bool ok;
  final String? error;
  final String? sha256;
  UploadResult({required this.ok, this.error, this.sha256});
}

/// Pixelサーバーへファイルを送るクライアント
class Uploader {
  final ServerEntry server;
  Uploader(this.server);

  /// サーバー死活確認
  Future<bool> ping() async {
    try {
      final res = await http
          .get(Uri.parse('${server.baseUrl}/ping'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 指定ファイルをアップロードする。
  /// [relativePath] はPixel側で再現するフォルダ構造（例: DCIM/Camera/x.jpg）
  Future<UploadResult> upload(File file, String relativePath) async {
    try {
      final uri = Uri.parse('${server.baseUrl}/upload');
      final req = http.MultipartRequest('POST', uri);
      req.fields['relativePath'] = relativePath;
      req.files.add(await http.MultipartFile.fromPath('file', file.path,
          filename: p.basename(file.path)));

      final streamed = await req.send().timeout(const Duration(minutes: 30));
      final res = await http.Response.fromStream(streamed);

      if (res.statusCode == 200) {
        return UploadResult(ok: true);
      }
      return UploadResult(ok: false, error: 'HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      return UploadResult(ok: false, error: e.toString());
    }
  }
}
