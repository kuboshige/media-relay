import 'dart:convert';
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

  /// サーバー側に同一内容（SHA256）のファイルが既に存在するか確認する。
  /// サーバーは初回呼び出し時に対象フォルダのハッシュ索引を構築するため、
  /// 最初の1回は時間がかかる可能性がある（タイムアウトを長めに取る）。
  Future<bool> exists(String sha256) async {
    try {
      final res = await http
          .get(Uri.parse('${server.baseUrl}/exists?hash=$sha256'))
          .timeout(const Duration(seconds: 180));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['exists'] == true;
    } catch (_) {
      return false;
    }
  }

  /// サーバーのハッシュ索引を再構築させる（クイックシェアの新規受信分を取り込む）。
  /// 構築できた件数を返す。失敗時は null。
  Future<int?> reindex() async {
    try {
      final res = await http
          .post(Uri.parse('${server.baseUrl}/reindex'))
          .timeout(const Duration(minutes: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return (body['count'] as num?)?.toInt();
    } catch (_) {
      return null;
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
