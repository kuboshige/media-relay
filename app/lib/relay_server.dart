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
      ..post('/setdate', _setdate)
      ..post('/scan', _scan);
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

  Response _ping(Request req) => _json({
        'ok': true,
        'storageRoot': storageRoot,
        'freeBytes': null,
        // このサーバーはアプリ内Dart実装。MediaStore登録(/scan)はまだ非対応。
        // 送信側はこのフラグを見て、無駄な /scan 待ちをスキップする。
        'mediaScan': false,
        'app': true,
      });

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

  // MediaStore登録（Googleフォト表示）は Step③ で実装予定。
  // 今は送信側が応答待ちで固まらないよう、即座に応答だけ返す（No-op）。
  Response _scan(Request req) =>
      _json({'ok': false, 'error': 'not implemented yet (step3)'});

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

  /// 端末のIPv4候補。Wi-Fi(wlan)優先で並べ、各候補に
  /// インターフェイス名・Wi-Fiか・「仮想(VPN等)か」を付ける。
  /// VPNのtunや携帯のrmnet等は他端末から到達できないので virtual=true とし、
  /// 既定の表示やQRからは除外できるようにする。
  static Future<List<({String ip, String iface, bool wifi, bool virtual})>>
      localIps() async {
    final out = <({String ip, String iface, bool wifi, bool virtual})>[];
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false);

      bool isWifi(String name) => name.toLowerCase().contains('wlan');
      // LANとして他端末から到達可能なI/Fか（Wi-Fi/有線/テザリング）。
      bool isLan(String name) {
        final n = name.toLowerCase();
        return n.contains('wlan') ||
            n.contains('eth') ||
            n.contains('usb') ||
            n.contains('rndis') ||
            n.startsWith('ap'); // テザリングAP
      }

      int score(NetworkInterface i) {
        final n = i.name.toLowerCase();
        if (n.contains('wlan')) return 0;
        if (isLan(i.name)) return 1;
        return 3; // tun/ppp/rmnet/vpn など仮想は後回し
      }

      ifaces.sort((a, b) => score(a).compareTo(score(b)));
      for (final i in ifaces) {
        final wifi = isWifi(i.name);
        final virtual = !isLan(i.name);
        for (final a in i.addresses) {
          if (!a.isLoopback &&
              !a.isLinkLocal &&
              !out.any((e) => e.ip == a.address)) {
            out.add((
              ip: a.address,
              iface: i.name,
              wifi: wifi,
              virtual: virtual,
            ));
          }
        }
      }
    } catch (_) {}
    return out;
  }

  /// QR/自動設定に使う「最有力の到達可能なLAN IP」。仮想を除いた先頭。
  static Future<String?> localIp() async {
    final ips = await localIps();
    final real = ips.where((e) => !e.virtual).toList();
    final pick = real.isNotEmpty ? real : ips;
    return pick.isEmpty ? null : pick.first.ip;
  }
}
