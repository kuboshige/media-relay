import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'app_settings.dart';
import 'media_store.dart';
import 'received_files_page.dart';
import 'receiver_service.dart';
import 'relay_server.dart';
import 'server_config.dart';

class ReceiverPage extends StatefulWidget {
  const ReceiverPage({super.key});

  @override
  State<ReceiverPage> createState() => _ReceiverPageState();
}

class _ReceiverPageState extends State<ReceiverPage> {
  RelayServer? _server;
  String? _token;
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
    _loadSettings();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _server?.stop();
    WakelockPlus.disable();
    ReceiverService.stop();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    _port = await AppSettings.receiverPort();
    _deviceName = await AppSettings.deviceName();
    _autoStopMinutes = await AppSettings.receiverAutoStopMinutes();
    _storageRoot = (await _resolveStorageRoot());
    if (mounted) setState(() {});
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
      var token = await AppSettings.receiverToken();
      if (token == null) {
        token = _generateToken();
        await AppSettings.setReceiverToken(token);
      }
      final server = RelayServer(
        storageRoot: _storageRoot!,
        port: _port,
        token: token,
        mediaScan: (sourcePath, relativePath, originalDateMs, mimeType) =>
            MediaStore.insertFile(
              sourcePath: sourcePath,
              relativePath: relativePath,
              originalDateMs: originalDateMs,
              mimeType: mimeType,
            ),
      );
      await server.start();
      _token = token;
      _ips = await RelayServer.localIps();
      await WakelockPlus.enable();
      _serverStartedAt = DateTime.now();
      _refresh?.cancel();
      _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
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
      await ReceiverService.start();
      setState(() {
        _server = server;
        _busy = false;
      });
      final isIgnored = await ReceiverService.isBatteryOptimizationIgnored();
      if (!isIgnored && mounted) _showBatteryOptimizationDialog();
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  void _showBatteryOptimizationDialog() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.batteryDialogTitle),
        content: Text(l10n.batteryDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.batteryDialogLater),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await ReceiverService.requestIgnoreBatteryOptimization();
            },
            child: Text(l10n.batteryDialogOpen),
          ),
        ],
      ),
    );
  }

  Future<void> _editDeviceName(AppLocalizations l10n) async {
    final ctrl = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.deviceNameLabel),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.deviceNameHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.btnCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: Text(l10n.btnSave)),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await AppSettings.setDeviceName(name);
      if (mounted) setState(() => _deviceName = name);
    }
  }

  Future<void> _stop() async {
    _refresh?.cancel();
    _refresh = null;
    await _server?.stop();
    await WakelockPlus.disable();
    await ReceiverService.stop();
    _serverStartedAt = null;
    setState(() {
      _server = null;
      _token = null;
    });
  }

  String _generateToken() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
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

  String? _autoStopCountdown(AppLocalizations l10n) {
    if (_autoStopMinutes <= 0 || _server == null) return null;
    final last = _server!.lastReceivedAt ?? _serverStartedAt;
    if (last == null) return null;
    final elapsed = DateTime.now().difference(last);
    final remaining = Duration(minutes: _autoStopMinutes) - elapsed;
    if (remaining.isNegative) return null;
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return m > 0
        ? l10n.autoStopCountdownMinutes(m, s)
        : l10n.autoStopCountdownSeconds(s);
  }

  Widget _screenLockInfoCard(AppLocalizations l10n) {
    return Card(
      color: Colors.teal.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lock_open, color: Colors.teal, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.screenLockInfoText,
                style: const TextStyle(fontSize: 12, color: Colors.teal),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qrCard(String ip, AppLocalizations l10n) {
    final data = ServerEntry.buildConnectUri(
        host: ip, port: _port, name: _deviceName, token: _token);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${l10n.deviceNameLabel}: $_deviceName',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: l10n.deviceNameLabel,
                  onPressed: () => _editDeviceName(l10n),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                data: data,
                version: QrVersions.auto,
                size: 220,
              ),
            ),
            if (_token != null) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock, size: 14, color: Colors.teal),
                  const SizedBox(width: 4),
                  SelectableText(
                    'token: $_token',
                    style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.teal),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              l10n.receiverQrHint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ipRow(
      ({String ip, String iface, bool wifi, bool virtual}) e,
      AppLocalizations l10n) {
    final addr = '${e.ip}:$_port';
    final label = e.wifi
        ? l10n.wifiLabel
        : (e.virtual ? l10n.vpnIfaceLabel(e.iface) : e.iface);
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
            tooltip: l10n.copy,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: addr));
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.copyDone)));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final running = _server?.running ?? false;
    final countdown = _autoStopCountdown(l10n);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabReceive)),
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
                        Text(
                            running
                                ? l10n.statusReceiving
                                : l10n.statusStopped,
                            style: Theme.of(context).textTheme.titleMedium),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _busy ? null : (running ? _stop : _start),
                          icon: Icon(running ? Icons.stop : Icons.play_arrow,
                              size: 18),
                          label: Text(running ? l10n.btnStop : l10n.btnStart),
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                running ? Colors.red.shade400 : null,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    if (running) ...[
                      const SizedBox(height: 12),
                      Text(l10n.receiverAddressHint),
                      const SizedBox(height: 4),
                      if (_ips.isEmpty)
                        Text(l10n.receiverIpPending,
                            style: const TextStyle(fontStyle: FontStyle.italic))
                      else ...[
                        for (final ip in _visibleIps) _ipRow(ip, l10n),
                        if (_hiddenVirtualCount > 0)
                          TextButton.icon(
                            onPressed: () =>
                                setState(() => _showAllIps = !_showAllIps),
                            icon: Icon(_showAllIps
                                ? Icons.visibility_off
                                : Icons.visibility),
                            label: Text(_showAllIps
                                ? l10n.vpnAddressHide
                                : l10n.vpnAddressShow(_hiddenVirtualCount)),
                          ),
                      ],
                    ] else ...[
                      const SizedBox(height: 8),
                      Text(l10n.receiverStartHint(_port),
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
            ),
            if (_server != null) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _server!.receivedThisSession > 0
                    ? () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReceivedFilesPage(
                                count: _server!.receivedThisSession),
                          ),
                        )
                    : null,
                child: Row(
                  children: [
                    Text(
                      l10n.receiverSessionCount(
                          _server!.receivedThisSession,
                          _server!.knownHashes),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_server!.receivedThisSession > 0) ...[
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary),
                    ],
                  ],
                ),
              ),
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
                          l10n.receiverInProgress(
                              _server!.receivingName!,
                              (_server!.receivingBytes / 1024 / 1024)
                                  .toStringAsFixed(1)),
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
            const SizedBox(height: 12),
            if (running) _screenLockInfoCard(l10n),
            if (_qrIp != null) _qrCard(_qrIp!, l10n),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(l10n.errorPrefix(_error!),
                  style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
