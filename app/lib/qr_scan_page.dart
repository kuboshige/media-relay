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
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

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
            // カメラが起動できない理由を画面に出す（黒画面＋!の原因特定用）
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
                        onPressed: () => _controller.start(),
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
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
