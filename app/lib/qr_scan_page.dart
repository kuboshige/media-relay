import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'server_config.dart';

/// 送信側：受信機のQRを読み取り、ServerEntry を返す画面。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  late final MobileScannerController _controller;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    // autoStart: false にして、ウィジェット描画後に手動で開始する。
    // MobileScanner のプラットフォームビュー（カメラテクスチャ）が確立される前に
    // start() を呼ぶと Java 層で NPE が発生するため。
    _controller = MobileScannerController(autoStart: false);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _controller.start();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final entry = ServerEntry.fromConnectUri(raw);
      if (entry != null) {
        _handled = true;
        Navigator.pop(context, entry);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QRで追加')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          color: Colors.red, size: 48),
                      const SizedBox(height: 12),
                      Text('カメラを起動できません',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'code: ${error.errorCode}\n'
                        '${error.errorDetails?.message ?? ''}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          await _controller.stop();
                          await _controller.start();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('戻る（設定の「＋」でIPを手入力できます）'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '受信側アプリのQRコードを枠に映してください',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  backgroundColor: Colors.black54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
