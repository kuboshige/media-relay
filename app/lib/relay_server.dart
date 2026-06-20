import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

/// 受信ファイルを Android MediaStore に登録するコールバック型。
///
/// [sourcePath]     書き込み済みの一時ファイルパス（成功時に呼び出し元が削除する）
/// [relativePath]   元のパス（例: DCIM/Camera/photo.jpg）
/// [originalDateMs] 撮影日時ミリ秒。0 なら設定しない
/// [mimeType]       null なら Kotlin 側が拡張子から推定
///
/// 成功時は content:// URI 文字列、失敗時は null。
typedef MediaScanCallback = Future<String?> Function(
    String sourcePath, String relativePath, int originalDateMs, String? mimeType);

/// アプリ内の受信サーバー（受信モード）。
///
/// Termux+node の受信側を Dart で置き換える。
/// 既存の送信アプリと同じHTTP API（/ping /exists /upload /reindex /setdate /scan）を
/// 実装し、受領ハッシュを永続台帳（received-hashes.txt）に記録する。
///
/// [mediaScan] を渡すと受信ファイルを MediaStore（Googleフォト対応）に登録する。
/// 未指定またはMediaStore失敗時はアプリ専用領域（storageRoot）に保存する。
class RelayServer {
  final String storageRoot;
  final int port;
  final MediaScanCallback? _mediaScan;
  HttpServer? _server;
  final Set<String> _seen = {};
  int _received = 0;
  String? _recvName; // 受信中ファイル名（進捗表示用）
  int _recvBytes = 0; // 受信中ファイルのこれまでのバイト数

  RelayServer(
      {required this.storageRoot,
      this.port = 8765,
      MediaScanCallback? mediaScan})
      : _mediaScan = mediaScan;

  bool get running => _server != null;
  int get knownHashes => _seen.length;
  int get receivedThisSession => _received;
  String? get receivingName => _recvName;
  int get receivingBytes => _recvBytes;

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
      ..post('/upload-raw', _uploadRaw)
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
        // mediaScan: true = アップロードごとに MediaStore 登録済み（/scan は即 ok）。
        // mediaScan: false = MediaStore 未対応（送信側は /scan をスキップする）。
        'mediaScan': _mediaScan != null,
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
    File? tmp;
    String? hash;
    int size = 0;

    await for (final part
        in MimeMultipartTransformer(boundary).bind(req.read())) {
      final name =
          _dispoValue(part.headers['content-disposition'] ?? '', 'name');
      if (name == 'file') {
        // 大きな動画をメモリに溜めない：addStream でバックプレッシャーを効かせつつ
        // 一時ファイルへ書き、通過するチャンクでSHA256と進捗を更新する。
        tmp = File(p.join(storageRoot, '.state',
            'upload-${DateTime.now().microsecondsSinceEpoch}.part'));
        final sink = tmp.openWrite();
        final digestSink = _DigestSink();
        final hashSink = sha256.startChunkedConversion(digestSink);
        _recvName = _dispoValue(
                part.headers['content-disposition'] ?? '', 'filename') ??
            'file';
        _recvBytes = 0;
        try {
          await sink.addStream(part.map((chunk) {
            hashSink.add(chunk);
            _recvBytes += chunk.length;
            size += chunk.length;
            return chunk;
          }));
        } finally {
          await sink.flush();
          await sink.close();
          hashSink.close();
          _recvName = null;
        }
        hash = digestSink.value?.toString();
      } else {
        final bytes = await _collect(part);
        if (name == 'relativePath') {
          relativePath = utf8.decode(bytes);
        } else if (name == 'originalDate') {
          originalDate = utf8.decode(bytes);
        }
      }
    }

    if (tmp == null || relativePath == null || hash == null) {
      try {
        tmp?.deleteSync();
      } catch (_) {}
      return _json({'error': 'missing file/relativePath'}, status: 400);
    }

    final normalized = relativePath.replaceAll(RegExp(r'^(\.\.(/|\\|$))+'), '');
    final originalDateMs = int.tryParse(originalDate ?? '') ?? 0;

    if (_mediaScan != null) {
      final uri =
          await _mediaScan!(tmp.path, normalized, originalDateMs, null);
      if (uri != null) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        _remember(hash);
        _received++;
        return _json(
            {'ok': true, 'relativePath': normalized, 'sha256': hash, 'size': size});
      }
      // MediaStore失敗：tmp は残っているのでプライベートストレージにフォールバック
    }

    final dest = File(p.join(storageRoot, normalized));
    dest.parent.createSync(recursive: true);
    try {
      tmp.renameSync(dest.path);
    } catch (_) {
      tmp.copySync(dest.path); // 別ボリューム等でrename不可ならコピー
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
    _applyDate(dest, originalDate);

    _remember(hash);
    _received++;
    return _json({
      'ok': true,
      'relativePath': normalized,
      'sha256': hash,
      'size': size,
    });
  }

  // アップロードごとに MediaStore 登録済みなので、/scan は状態確認のみ。
  Response _scan(Request req) => _json({'ok': _mediaScan != null});

  /// 生バイト直接アップロード（multipart不使用）。アプリ内受信の本命経路。
  /// メタデータはヘッダで渡す。ボディ長＝ファイル長なので確実にEOFまで消費でき、
  /// multipartの終端未消費による「応答が返らず送信側が固まる」問題を避ける。
  Future<Response> _uploadRaw(Request req) async {
    final relB64 = req.headers['x-relative-path'];
    if (relB64 == null) {
      return _json({'error': 'x-relative-path header required'}, status: 400);
    }
    String relativePath;
    try {
      relativePath = utf8.decode(base64.decode(relB64));
    } catch (_) {
      return _json({'error': 'bad x-relative-path'}, status: 400);
    }
    final originalDate = req.headers['x-original-date'];
    final normalized =
        relativePath.replaceAll(RegExp(r'^(\.\.(/|\\|$))+'), '');

    final tmp = File(p.join(storageRoot, '.state',
        'upload-${DateTime.now().microsecondsSinceEpoch}.part'));
    final sink = tmp.openWrite();
    final digestSink = _DigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    _recvName = p.basename(normalized);
    _recvBytes = 0;
    var size = 0;
    try {
      await sink.addStream(req.read().map((chunk) {
        hashSink.add(chunk);
        size += chunk.length;
        _recvBytes = size;
        return chunk;
      }));
    } finally {
      await sink.flush();
      await sink.close();
      hashSink.close();
      _recvName = null;
    }

    final hash = digestSink.value?.toString();
    if (hash == null || size == 0) {
      try {
        tmp.deleteSync();
      } catch (_) {}
      return _json({'error': 'empty body'}, status: 400);
    }

    final originalDateMs = int.tryParse(originalDate ?? '') ?? 0;

    if (_mediaScan != null) {
      final uri =
          await _mediaScan!(tmp.path, normalized, originalDateMs, null);
      if (uri != null) {
        try {
          tmp.deleteSync();
        } catch (_) {}
        _remember(hash);
        _received++;
        return _json(
            {'ok': true, 'relativePath': normalized, 'sha256': hash, 'size': size});
      }
      // MediaStore失敗：tmp は残っているのでプライベートストレージにフォールバック
    }

    final dest = File(p.join(storageRoot, normalized));
    dest.parent.createSync(recursive: true);
    try {
      tmp.renameSync(dest.path);
    } catch (_) {
      tmp.copySync(dest.path);
      try {
        tmp.deleteSync();
      } catch (_) {}
    }
    _applyDate(dest, originalDate);

    _remember(hash);
    _received++;
    return _json(
        {'ok': true, 'relativePath': normalized, 'sha256': hash, 'size': size});
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

/// SHA256の逐次計算（startChunkedConversion）の結果を受け取る小さなSink。
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
