import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'app_settings.dart';
import 'relay_server.dart';

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
  String? _ip;
  int _port = AppSettings.defaultReceiverPort;
  String? _storageRoot;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _server?.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<String> _resolveStorageRoot() async {
    // Step①は MediaStore 未対応のため、書き込み可能なアプリ専用外部領域に保存する。
    // （Googleフォトへの表示は次ステップで MediaStore 登録を実装する）
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
      _storageRoot = await _resolveStorageRoot();
      Directory(_storageRoot!).createSync(recursive: true);
      final server = RelayServer(storageRoot: _storageRoot!, port: _port);
      await server.start();
      _ip = await RelayServer.localIp();
      await WakelockPlus.enable();
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
    await _server?.stop();
    await WakelockPlus.disable();
    setState(() => _server = null);
  }

  @override
  Widget build(BuildContext context) {
    final running = _server?.running ?? false;
    final addr = (_ip != null) ? '$_ip:$_port' : '(IP取得中)';
    return Scaffold(
      appBar: AppBar(title: const Text('受信モード（このPixelをサーバーに）')),
      body: Padding(
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
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(addr,
                              style: Theme.of(context).textTheme.headlineSmall),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: 'コピー',
                          onPressed: _ip == null
                              ? null
                              : () {
                                  Clipboard.setData(
                                      ClipboardData(text: addr));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('コピーしました')));
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_storageRoot != null)
              Text('保存先: $_storageRoot',
                  style: Theme.of(context).textTheme.bodySmall),
            if (_server != null) ...[
              const SizedBox(height: 8),
              Text('このセッションの受信: ${_server!.receivedThisSession} 件 / '
                  '台帳: ${_server!.knownHashes} ハッシュ'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text('エラー: $_error', style: const TextStyle(color: Colors.red)),
            ],
            const Spacer(),
            const Card(
              color: Color(0xFFFFF3E0),
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '⚠️ Step①の制限：\n'
                  '・画面を消す/アプリを閉じると受信が止まります（常駐は次ステップ）\n'
                  '・受信ファイルはまだGoogleフォトに出ません（MediaStore登録は次ステップ）\n'
                  'まずは送信側からの接続・転送が通るかの確認用です。',
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
          ],
        ),
      ),
    );
  }
}
