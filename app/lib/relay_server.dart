import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// アプリ内の受信サーバー（受信モード）。
///
/// Termux+node の受信側を Dart で置き換えるための雛形。
/// 既存の送信アプリと同じHTTP API（/ping /exists /upload /reindex /setdate）を
/// 実装し、受領ハッシュを永続台帳（received-hashes.txt）に記録する。
///
/// 注意（このステップの制限）：
///  - フォアグラウンド常駐はまだ無い（アプリ前面/画面ON中のみ稼働）
///  - 受信ファイルのMediaStore登録（Googleフォト表示）は未実装（次ステップ）
class RelayServer {
  final String storageRoot;
  final int port;
  HttpServer? _server;
  final Set<String> _seen = {};
  int _received = 0;

  RelayServer({required this.storageRoot, this.port = 8765});

  bool get running => _server != null;
  int get knownHashes => _seen.length;
  int get receivedThisSession => _received;

  File get _ledgerFile =>
      File(p.join(storageRoot, '.state', 'received-hashes.txt'));

  Future<void> start() async {
    if (_server != null) return;
    Directory(p.join(storageRoot, '.state')).createSync(recursive: true);
    _loadLedger();
    final router = Router()
      ..get('/ping', _ping)
      ..get('/exists', _exists)
      ..post('/reindex', _reindex)
      ..post('/upload', _upload)
      ..post('/setdate', _setdate);
    _server = await shelf_io.serve(
        const Pipeline().addHandler(router.call), InternetAddress.anyIPv4, port);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _loadLedger() {
    try {
      for (final l in _ledgerFile.readAsLinesSync()) {
        final h = l.trim();
        if (RegExp(r'^[a-f0-9]{64}$').hasMatch(h)) _seen.add(h);
      }
    } catch (_) {
      // 未作成は無視
    }
  }

  void _remember(String hash) {
    if (_seen.add(hash)) {
      try {
        _ledgerFile.writeAsStringSync('$hash\n', mode: FileMode.append);
      } catch (_) {}
    }
  }

  Response _json(Object body, {int status = 200}) => Response(status,
      body: jsonEncode(body), headers: {'content-type': 'application/json'});

  Response _ping(Request req) =>
      _json({'ok': true, 'storageRoot': storageRoot, 'freeBytes': null});

  Response _exists(Request req) {
    final hash = req.url.queryParameters['hash'] ?? '';
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      return _json({'error': 'invalid hash'}, status: 400);
    }
    return _json({'exists': _seen.contains(hash)});
  }

  Future<Response> _reindex(Request req) async {
    final root = Directory(storageRoot);
    if (root.existsSync()) {
      for (final e in root.listSync(recursive: true, followLinks: false)) {
        if (e is File && !p.split(e.path).contains('.state')) {
          try {
            _remember(sha256.convert(e.readAsBytesSync()).toString());
          } catch (_) {}
        }
      }
    }
    return _json({'ok': true, 'count': _seen.length});
  }

  Future<Response> _upload(Request req) async {
    final boundary = _boundary(req.headers['content-type'] ?? '');
    if (boundary == null) return _json({'error': 'not multipart'}, status: 400);

    String? relativePath;
    String? originalDate;
    List<int>? fileBytes;
    await for (final part
        in MimeMultipartTransformer(boundary).bind(req.read())) {
      final name = _dispoValue(part.headers['content-disposition'] ?? '', 'name');
      final bytes = await _collect(part);
      if (name == 'relativePath') {
        relativePath = utf8.decode(bytes);
      } else if (name == 'originalDate') {
        originalDate = utf8.decode(bytes);
      } else if (name == 'file') {
        fileBytes = bytes;
      }
    }
    if (fileBytes == null || relativePath == null) {
      return _json({'error': 'missing file/relativePath'}, status: 400);
    }

    final normalized =
        relativePath.replaceAll(RegExp(r'^(\.\.(/|\\|$))+'), '');
    final dest = File(p.join(storageRoot, normalized));
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(fileBytes);
    _applyDate(dest, originalDate);

    final hash = sha256.convert(fileBytes).toString();
    _remember(hash);
    _received++;
    return _json({
      'ok': true,
      'relativePath': normalized,
      'sha256': hash,
      'size': fileBytes.length,
    });
  }

  Future<Response> _setdate(Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final rel = body['relativePath'] as String?;
    if (rel == null) return _json({'error': 'relativePath required'}, status: 400);
    final normalized = rel.replaceAll(RegExp(r'^(\.\.(/|\\|$))+'), '');
    final f = File(p.join(storageRoot, normalized));
    if (!f.existsSync()) return _json({'ok': false, 'error': 'not found'});
    return _json({'ok': _applyDate(f, body['originalDate']?.toString())});
  }

  bool _applyDate(File f, String? ms) {
    final v = int.tryParse(ms ?? '');
    if (v == null || v <= 0) return false;
    try {
      f.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(v));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> _collect(Stream<List<int>> s) async {
    final b = <int>[];
    await for (final c in s) {
      b.addAll(c);
    }
    return b;
  }

  String? _boundary(String contentType) {
    final m =
        RegExp(r'boundary=(?:"([^"]+)"|([^";]+))').firstMatch(contentType);
    return m == null ? null : (m.group(1) ?? m.group(2))?.trim();
  }

  String? _dispoValue(String cd, String key) =>
      RegExp('$key="([^"]*)"').firstMatch(cd)?.group(1);

  /// 端末のLAN IP（最初の非ループバックIPv4）。表示用。
  static Future<String?> localIp() async {
    try {
      final ifaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
