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
  // Pixelの空き容量不足で拒否された（バッチを止める判断に使う）
  final bool insufficientStorage;
  UploadResult({
    required this.ok,
    this.error,
    this.sha256,
    this.insufficientStorage = false,
  });
}

/// サーバーの状態（/ping のレスポンス）
class ServerInfo {
  final String? storageRoot;
  final int? freeBytes;
  // 受信側が MediaStore登録(/scan) に対応しているか。
  // 旧node実装はこのフィールドを返さない → null（=対応扱い・従来通りscanする）。
  // アプリ内受信は false を返す → 送信側は /scan をスキップする。
  final bool? mediaScan;
  ServerInfo({this.storageRoot, this.freeBytes, this.mediaScan});

  /// /scan を呼ぶべきか（未指定の旧実装は従来通り呼ぶ）。
  bool get supportsMediaScan => mediaScan ?? true;
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

  /// サーバーの状態（空き容量など）を取得する。失敗時は null。
  Future<ServerInfo?> info() async {
    try {
      final res = await http
          .get(Uri.parse('${server.baseUrl}/ping'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return ServerInfo(
        storageRoot: body['storageRoot'] as String?,
        freeBytes: (body['freeBytes'] as num?)?.toInt(),
        mediaScan: body['mediaScan'] as bool?,
      );
    } catch (_) {
      return null;
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

  /// 保存済みファイルをAndroidのMediaStoreに登録させる（Googleフォト用）。
  /// termux-api 未導入なら false。
  Future<bool> scan() async {
    try {
      final res = await http
          .post(Uri.parse('${server.baseUrl}/scan'))
          .timeout(const Duration(minutes: 5));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 既に保存済みファイルの日付だけ後から修正する（再転送なし）。
  Future<bool> setDate(String relativePath, int originalDateMs) async {
    try {
      final res = await http
          .post(
            Uri.parse('${server.baseUrl}/setdate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'relativePath': relativePath,
              'originalDate': originalDateMs,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 指定ファイルをアップロードする。
  /// [relativePath] はPixel側で再現するフォルダ構造（例: DCIM/Camera/x.jpg）
  /// [originalDateMs] は元の撮影日時。Pixel側でファイル更新日時に反映する。
  Future<UploadResult> upload(File file, String relativePath,
      {int? originalDateMs}) async {
    try {
      final uri = Uri.parse('${server.baseUrl}/upload');
      final req = http.MultipartRequest('POST', uri);
      req.fields['relativePath'] = relativePath;
      if (originalDateMs != null) {
        req.fields['originalDate'] = originalDateMs.toString();
      }
      req.files.add(await http.MultipartFile.fromPath('file', file.path,
          filename: p.basename(file.path)));

      final streamed = await req.send().timeout(const Duration(minutes: 30));
      final res = await http.Response.fromStream(streamed);

      if (res.statusCode == 200) {
        return UploadResult(ok: true);
      }
      // 507 Insufficient Storage = Pixelの空き容量不足
      if (res.statusCode == 507) {
        return UploadResult(
            ok: false,
            insufficientStorage: true,
            error: '${server.name}の空き容量が不足しています');
      }
      return UploadResult(ok: false, error: 'HTTP ${res.statusCode}: ${res.body}');
    } catch (e) {
      return UploadResult(ok: false, error: e.toString());
    }
  }
}
