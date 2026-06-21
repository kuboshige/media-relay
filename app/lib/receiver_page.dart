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
class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  RelayServer? _server;
  List<({String ip, String iface, bool wifi, bool virtual})> _ips = [];
  bool _showAllIps = false;
  int _port = AppSettings.defaultReceiverPort;
  String? _storageRoot;
  String? _error;
  bool _busy = false;
  Timer? _refresh;
  String _deviceName = '';
  int _autoStopMinutes = AppSettings.defaultAutoStopMinutes;
  DateTime? _serverStartedAt;

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
      _autoStopMinutes = await AppSettings.receiverAutoStopMinutes();
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
      _serverStartedAt = DateTime.now();
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        // 自動停止チェック（受信が無い状態が設定時間を超えたら停止・画面オフ）
        if (_autoStopMinutes > 0 && _server != null) {
          final last = _server!.lastReceivedAt ?? _serverStartedAt;
          if (last != null &&
              DateTime.now().difference(last).inMinutes >= _autoStopMinutes) {
            _stop();
            return;
          }
        }
        setState(() {});
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

  Future<void> _stop() async {
    _refresh?.cancel();
    _refresh = null;
    await _server?.stop();
    await WakelockPlus.disable();
    _serverStartedAt = null;
    setState(() => _server = null);
  }

  List<({String ip, String iface, bool wifi, bool virtual})> get _visibleIps {
    if (_showAllIps) return _ips;
    final real = _ips.where((e) => !e.virtual).toList();
    return real.isEmpty ? _ips : real;
  }

  int get _hiddenVirtualCount {
    if (_showAllIps) return 0;
    final real = _ips.where((e) => !e.virtual).length;
    if (real == 0) return 0;
    return _ips.length - real;
  }

  String? get _qrIp => _visibleIps.isEmpty ? null : _visibleIps.first.ip;

  /// 自動停止までの残り時間（文字列）。設定オフまたはサーバー停止中は null。
  String? get _autoStopCountdown {
    if (_autoStopMinutes <= 0 || _server == null) return null;
    final last = _server!.lastReceivedAt ?? _serverStartedAt;
    if (last == null) return null;
    final elapsed = DateTime.now().difference(last);
    final remaining = Duration(minutes: _autoStopMinutes) - elapsed;
    if (remaining.isNegative) return null;
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return m > 0 ? 'あと ${m}分 ${s}秒で自動停止・画面オフ' : 'あと ${s}秒で自動停止・画面オフ';
  }

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

  Future<void> _setAutoStop(int minutes) async {
    await AppSettings.setReceiverAutoStopMinutes(minutes);
    setState(() => _autoStopMinutes = minutes);
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

  Widget _autoStopTile() {
    String label(int m) => m == 0 ? '停止しない' : '${m}分';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.timer_off_outlined),
      title: const Text('無通信で自動停止'),
      subtitle: Text(_autoStopMinutes == 0
          ? 'オフ（手動で停止してください）'
          : '最後の受信から $_autoStopMinutes 分後にサーバー停止・画面オフ'),
      trailing: DropdownButton<int>(
        value: _autoStopMinutes,
        onChanged: (v) { if (v != null) _setAutoStop(v); },
        items: [
          for (final m in AppSettings.autoStopChoices)
            DropdownMenuItem(value: m, child: Text(label(m))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _server?.running ?? false;
    final countdown = _autoStopCountdown;
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
              if (countdown != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          size: 16, color: Colors.orange),
                      const SizedBox(width: 6),
                      Text(countdown,
                          style: const TextStyle(color: Colors.orange)),
                    ],
                  ),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text('エラー: $_error', style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _autoStopTile(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : (running ? _stop : _start),
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? '受信を停止' : '受信を開始'),
            ),
          ],
        ),
      ),
    );
  }
}
