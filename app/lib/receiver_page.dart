import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'app_settings.dart';
import 'media_store.dart';
import 'relay_server.dart';
import 'server_config.dart';

/// 受信モード画面（この端末＝Pixelをサーバーにする）。
///
/// Step ①：Dart製の受信サーバーを起動し、IP:PORT を表示する。
/// 送信側アプリの「接続テスト」やバッチ送信がここへ届くことを確認する。
class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  RelayServer? _server;
  List<({String ip, String iface, bool wifi, bool virtual})> _ips = [];
  bool _showAllIps = false; // VPN/仮想アドレスも表示するか
  int _port = AppSettings.defaultReceiverPort;
  String? _storageRoot;
  String? _error;
  bool _busy = false;
  bool _migrating = false;
  int _migrateTotal = 0;
  int _migrateDone = 0;
  int _migrateFailed = 0;
  String? _lastMigrateError;
  Timer? _refresh; // 受信カウンタを定期的に再描画する
  String _deviceName = '';

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _server?.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<String> _resolveStorageRoot() async {
    // MediaStore 登録に失敗した場合のフォールバック保存先（アプリ専用外部領域）。
    // 通常は MediaStore API 経由で /sdcard/MediaRelay/ に保存される。
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    return p.join(base.path, 'MediaRelay');
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _port = await AppSettings.receiverPort();
      _deviceName = await AppSettings.deviceName();
      _storageRoot = await _resolveStorageRoot();
      Directory(_storageRoot!).createSync(recursive: true);
      final server = RelayServer(
        storageRoot: _storageRoot!,
        port: _port,
        mediaScan: (sourcePath, relativePath, originalDateMs, mimeType) =>
            MediaStore.insertFile(
              sourcePath: sourcePath,
              relativePath: relativePath,
              originalDateMs: originalDateMs,
              mimeType: mimeType,
            ),
      );
      await server.start();
      _ips = await RelayServer.localIps();
      await WakelockPlus.enable();
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      setState(() {
        _server = server;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// プライベートストレージの既存受信ファイルを MediaStore（Googleフォト）に一括登録する。
  /// 登録成功したファイルはプライベート領域から削除し、重複を防ぐ。
  Future<void> _migrateToMediaStore() async {
    if (_storageRoot == null || _migrating) return;

    final dir = Directory(_storageRoot!);
    if (!dir.existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存フォルダが見つかりません')));
      return;
    }

    final files = dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => !p.split(f.path).contains('.state'))
        .toList();

    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登録するファイルがありません')));
      return;
    }

    setState(() {
      _migrating = true;
      _migrateTotal = files.length;
      _migrateDone = 0;
      _migrateFailed = 0;
      _lastMigrateError = null;
    });

    for (final file in files) {
      final relPath = p.relative(file.path, from: _storageRoot!);
      final dateMs = file.lastModifiedSync().millisecondsSinceEpoch;
      final r = await MediaStore.insertFileResult(
        sourcePath: file.path,
        relativePath: relPath,
        originalDateMs: dateMs,
      );
      if (r.uri != null) {
        try {
          file.deleteSync();
        } catch (_) {}
        setState(() => _migrateDone++);
      } else {
        _lastMigrateError ??= r.error;
        setState(() => _migrateFailed++);
      }
    }

    final ok = _migrateDone;
    final fail = _migrateFailed;
    setState(() => _migrating = false);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Googleフォト登録完了'),
        content: Text([
          if (ok > 0) '$ok 件をGoogleフォトに登録しました',
          if (fail > 0) '$fail 件失敗',
          if (_lastMigrateError != null) '最初のエラー: $_lastMigrateError',
        ].join('\n')),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _stop() async {
    _refresh?.cancel();
    await _server?.stop();
    await WakelockPlus.disable();
    setState(() => _server = null);
  }

  // 既定では到達可能なLAN(非仮想)だけ表示。LANが無ければ全部出す（取りこぼし防止）。
  List<({String ip, String iface, bool wifi, bool virtual})> get _visibleIps {
    if (_showAllIps) return _ips;
    final real = _ips.where((e) => !e.virtual).toList();
    return real.isEmpty ? _ips : real;
  }

  int get _hiddenVirtualCount {
    if (_showAllIps) return 0;
    final real = _ips.where((e) => !e.virtual).length;
    if (real == 0) return 0; // 仮想しか無い時は全部表示中なので隠れていない
    return _ips.length - real;
  }

  // QRに載せる代表IP（表示中の先頭＝Wi-Fi優先）。
  String? get _qrIp => _visibleIps.isEmpty ? null : _visibleIps.first.ip;

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('この端末の名前'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例: 家のPixel'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await AppSettings.setDeviceName(name);
      setState(() => _deviceName = name);
    }
  }

  Widget _qrCard(String ip) {
    final data = ServerEntry.buildConnectUri(
        host: ip, port: _port, name: _deviceName);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text('名前: $_deviceName',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: '名前を変更',
                  onPressed: _editName,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '送信側のメディアリレーで「QRで追加」して読み取ってください',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ipRow(({String ip, String iface, bool wifi, bool virtual}) e) {
    final addr = '${e.ip}:$_port';
    final label = e.wifi ? 'Wi-Fi' : (e.virtual ? '${e.iface}(VPN等)' : e.iface);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Chip(
            label: Text(label, style: const TextStyle(fontSize: 11)),
            backgroundColor:
                e.wifi ? Colors.green.shade100 : Colors.orange.shade100,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(addr,
                style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'コピー',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: addr));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('コピーしました')));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _server?.running ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('受信モード（この端末をサーバーに）')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(running ? Icons.wifi_tethering : Icons.wifi_off,
                            color: running ? Colors.green : Colors.grey),
                        const SizedBox(width: 8),
                        Text(running ? '受信中' : '停止中',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('送信側アプリにこのアドレスを登録:'),
                    const SizedBox(height: 4),
                    if (_ips.isEmpty)
                      const Text('(IP取得中)',
                          style: TextStyle(fontStyle: FontStyle.italic))
                    else ...[
                      for (final ip in _visibleIps) _ipRow(ip),
                      if (_hiddenVirtualCount > 0)
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _showAllIps = !_showAllIps),
                          icon: Icon(_showAllIps
                              ? Icons.visibility_off
                              : Icons.visibility),
                          label: Text(_showAllIps
                              ? 'VPN等のアドレスを隠す'
                              : 'VPN等のアドレスも表示 ($_hiddenVirtualCount)'),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_qrIp != null) _qrCard(_qrIp!),
            const SizedBox(height: 12),
            if (_storageRoot != null)
              Text('保存先: $_storageRoot',
                  style: Theme.of(context).textTheme.bodySmall),
            if (_server != null) ...[
              const SizedBox(height: 8),
              Text('このセッションの受信: ${_server!.receivedThisSession} 件 / '
                  '台帳: ${_server!.knownHashes} ハッシュ'),
              if (_server!.receivingName != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '受信中: ${_server!.receivingName} '
                          '(${(_server!.receivingBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text('エラー: $_error', style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            const Card(
              color: Color(0xFFFFF3E0),
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '⚠️ 現在の制限：\n'
                  '・画面を消す/アプリを閉じると受信が止まります（常駐は次ステップ）\n'
                  '・受信ファイルは /sdcard/MediaRelay/ に保存され、Googleフォトに表示されます',
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : (running ? _stop : _start),
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? '受信を停止' : '受信を開始'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: (_busy || _migrating) ? null : _migrateToMediaStore,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('既存ファイルをGoogleフォトに登録'),
            ),
            if (_migrating) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('登録中… $_migrateDone / $_migrateTotal 件'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
