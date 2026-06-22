import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'app_settings.dart';
import 'media_source.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'upload_service.dart';
import 'result_detail_page.dart';
import 'settings_page.dart';
import 'folder_config.dart';
import 'folder_select_page.dart';
import 'sent_store.dart';
import 'history_page.dart';
import 'notif_service.dart';
import 'receiver_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MediaRelayApp());
}

class MediaRelayApp extends StatelessWidget {
  const MediaRelayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MediaRelay',
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja'),
        Locale('en'),
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final _homeKey = GlobalKey<_HomePageState>();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomePage(key: _homeKey),
          const ReceiverPage(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) {
          if (i == 0 && _currentIndex != 0) {
            _homeKey.currentState?._refreshServers();
          }
          setState(() => _currentIndex = i);
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.upload_outlined),
            selectedIcon: const Icon(Icons.upload),
            label: l10n.tabSend,
          ),
          NavigationDestination(
            icon: const Icon(Icons.download_outlined),
            selectedIcon: const Icon(Icons.download),
            label: l10n.tabReceive,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.tabSettings,
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = true;
  bool _permissionDenied = false;
  List<MediaItem> _all = [];
  Set<String> _sentIds = {};
  final Set<String> _selected = {};
  bool _showSent = false;
  List<ServerEntry> _servers = [];
  int _selectedServer = 0;
  String? _status;
  int _lastProgressTs = 0;
  String? _lastResult;
  List<FileOp> _lastOps = [];
  int? _freeBytes;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    _servers = await ServerConfig.load();
    _selectedServer = await ServerConfig.selectedIndex();

    final granted = await MediaSource.requestPermission();
    if (!granted) {
      setState(() {
        _loading = false;
        _permissionDenied = true;
      });
      return;
    }
    await _reloadMedia();
    setState(() => _loading = false);

    try {
      await NotifService.requestPermission();
      await NotifService.reschedule();
    } catch (_) {}
    _refreshFreeSpace();

    final startupAction = await AppSettings.startupAction();
    if (startupAction != AppSettings.startupActionNone && mounted) {
      await _runStartupAction(startupAction);
    }
  }

  Future<void> _refreshFreeSpace() async {
    final server = _currentServer;
    if (server == null) return;
    final si = await Uploader(server).info();
    if (!mounted) return;
    setState(() => _freeBytes = si?.freeBytes);
  }

  Future<void> _reloadMedia() async {
    final albumIds = await FolderConfig.loadSelected();
    final items = await MediaSource.listFromAlbums(albumIds);
    final sent = await SentStore.sentAssetIds();
    setState(() {
      _all = items;
      _sentIds = sent;
      _selected.clear();
    });
  }

  List<MediaItem> get _visible => _showSent
      ? _all
      : _all.where((m) => !_sentIds.contains(m.id)).toList();

  int get _unsentCount =>
      _all.where((m) => !_sentIds.contains(m.id)).length;

  String _destName(AppLocalizations l10n) =>
      _currentServer?.name ?? l10n.destNameFallback;

  ServerEntry? get _currentServer {
    if (_servers.isEmpty) return null;
    final i = _selectedServer.clamp(0, _servers.length - 1);
    return _servers[i];
  }

  Future<void> _refreshServers() async {
    _servers = await ServerConfig.load();
    _selectedServer = await ServerConfig.selectedIndex();
    if (mounted) setState(() {});
  }

  bool get _hasOpDetail => _lastOps.any((o) => o.needsAttention);

  Future<void> _showOpDetail() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await Navigator.push<DetailPageResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ResultDetailPage(
            ops: _lastOps, serverName: _destName(l10n)),
      ),
    );
    if (result == null || !mounted) return;
    if (result.toSend.isNotEmpty) await _send(result.toSend);
    if (result.toDelete.isNotEmpty) {
      if (result.forcedDelete) {
        await _forceDeleteFromDevice(result.toDelete);
      } else {
        await _deleteFromDevice(result.toDelete);
      }
    }
  }

  Future<void> _forceDeleteFromDevice(List<MediaItem> candidates) async {
    if (candidates.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _status = l10n.deletingPrompt);
    final ids = candidates.map((m) => m.id).toList();
    List<String> deleted = const [];
    try {
      deleted = await PhotoManager.editor.deleteWithIds(ids);
    } catch (e) {
      setState(() => _status = null);
      _showSnack(l10n.deleteFailed(e.toString()));
      return;
    }
    final ops = candidates.map((m) {
      return deleted.contains(m.id)
          ? FileOp(m, FileOpStatus.deleted)
          : FileOp(m, FileOpStatus.failed, l10n.deleteLocalFailed);
    }).toList();
    await _reloadMedia();
    final summary = l10n.deleteResultFailed(
        deleted.length, candidates.length - deleted.length);
    setState(() {
      _status = null;
      _lastResult = summary;
      _lastOps = ops;
    });
    _showSnack(summary);
  }

  Future<void> _openFolderSelect() async {
    final changed = await Navigator.push<bool>(context,
        MaterialPageRoute(builder: (_) => const FolderSelectPage()));
    if (changed == true) {
      setState(() => _loading = true);
      await _reloadMedia();
      setState(() => _loading = false);
    }
  }

  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _sendSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final targets = _visible.where((m) => _selected.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack(l10n.noFilesToSend);
      return;
    }
    await _send(targets);
  }

  Future<void> _sendAndDelete(List<MediaItem> targets) async {
    final l10n = AppLocalizations.of(context)!;
    final dest = _destName(l10n);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.sendAndDeleteTitle),
        content: Text(l10n.sendAndDeleteContent(targets.length, dest)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.btnCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.sendAndDeleteTitle),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    await _send(targets);
    if (!mounted) return;

    final sentItems = _lastOps
        .where((o) => o.status == FileOpStatus.sent)
        .map((o) => o.item)
        .toList();
    if (sentItems.isNotEmpty) {
      await _deleteFromDevice(sentItems, skipConfirmation: true);
    }
  }

  Future<void> _sendAllUnsent() async {
    final l10n = AppLocalizations.of(context)!;
    final targets = _all.where((m) => !_sentIds.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack(l10n.noUnsentFiles);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.menuSendAllUnsent),
        content: Text(l10n.sendAllUnsentContent(targets.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.btnCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.btnSend)),
        ],
      ),
    );
    if (ok == true) await _send(targets);
  }

  Future<void> _send(List<MediaItem> targets) async {
    final l10n = AppLocalizations.of(context)!;
    final server = _currentServer;
    if (server == null) {
      _showSnack(l10n.noServerSet);
      return;
    }

    final uploader = Uploader(server);
    setState(() => _status = l10n.checkingServer);
    final caps = await uploader.info();
    if (caps == null) {
      setState(() => _status = null);
      _showConnectionDialog(server);
      return;
    }
    final supportsScan = caps.supportsMediaScan;

    int done = 0;
    int skipped = 0;
    int failed = 0;
    var stoppedForStorage = false;
    final ops = <FileOp>[];

    await WakelockPlus.enable();
    await UploadService.start();
    try {
      for (var i = 0; i < targets.length; i++) {
        final item = targets[i];
        setState(() => _status = l10n.sendingFile(i + 1, targets.length, item.title));

        final file = await item.originFile();
        if (file == null) {
          failed++;
          ops.add(FileOp(item, FileOpStatus.failed, l10n.fileGetFailed));
          await SentStore.log(
            assetId: item.id,
            title: item.title,
            relativePath: item.relativePath,
            status: 'failed',
            detail: l10n.fileGetFailed,
          );
          continue;
        }

        String? hash;
        try {
          hash = await _sha256OfFile(file);
        } catch (_) {
          hash = null;
        }

        int? size;
        try {
          size = await file.length();
        } catch (_) {
          size = null;
        }

        var success = false;
        var status = 'failed';
        String? detail;

        if (hash != null && await uploader.exists(hash)) {
          skipped++;
          success = true;
          status = 'skipped';
          detail = l10n.alreadyExistsOn(server.name);
          ops.add(FileOp(item, FileOpStatus.skipped, l10n.alreadyExistsOn(server.name)));
        } else {
          DateTime? fileStart;
          final res = caps.app
              ? await uploader.uploadRaw(file, item.relativePath,
                  originalDateMs: item.createdAt.millisecondsSinceEpoch,
                  onProgress: (sent, total) {
                  fileStart ??= DateTime.now();
                  final now = DateTime.now().millisecondsSinceEpoch;
                  if (sent < total && now - _lastProgressTs < 1000) return;
                  _lastProgressTs = now;
                  final s = (sent / 1048576).toStringAsFixed(1);
                  final t = (total / 1048576).toStringAsFixed(1);
                  String eta = '';
                  final elapsedMs =
                      DateTime.now().difference(fileStart!).inMilliseconds;
                  if (elapsedMs > 800 && sent > 0 && total > sent) {
                    final speed = sent * 1000.0 / elapsedMs;
                    final etaSec = ((total - sent) / speed).round();
                    if (etaSec > 0) eta = l10n.etaSuffix(_fmtEta(etaSec, l10n));
                  }
                  setState(() => _status =
                      l10n.sendingFileMb(i + 1, targets.length, item.title, s, t, eta));
                })
              : await uploader.upload(file, item.relativePath,
                  originalDateMs: item.createdAt.millisecondsSinceEpoch);
          _lastProgressTs = 0;
          if (res.ok) {
            done++;
            success = true;
            status = 'sent';
            ops.add(FileOp(item, FileOpStatus.sent));
          } else if (res.insufficientStorage) {
            stoppedForStorage = true;
            ops.add(FileOp(item, FileOpStatus.failed, l10n.storageFullStop(server.name)));
            await SentStore.log(
              assetId: item.id,
              title: item.title,
              relativePath: item.relativePath,
              status: 'failed',
              detail: res.error,
              size: size,
            );
            break;
          } else {
            failed++;
            detail = res.error;
            ops.add(FileOp(item, FileOpStatus.failed, res.error));
          }
        }

        await SentStore.log(
          assetId: item.id,
          title: item.title,
          relativePath: item.relativePath,
          status: status,
          detail: detail,
          size: size,
        );

        if (success) {
          await SentStore.markSent(
            assetId: item.id,
            sha256: hash,
            fileSize: size,
            modifiedTime: item.modifiedAt.millisecondsSinceEpoch,
            relativePath: item.relativePath,
          );
          _sentIds.add(item.id);
        }
      }
    } finally {
      await WakelockPlus.disable();
      await UploadService.stop();
    }

    String? scanWarning;
    if (done > 0 && supportsScan) {
      setState(() => _status = l10n.scanningPhotos(server.name));
      final scanError = await uploader.scan();
      if (scanError != null) {
        scanWarning = l10n.scanFailed;
      }
    } else if (done > 0 && caps.needsScanSetup) {
      scanWarning = l10n.scanSetupNeeded;
    }

    if (done > 0 || skipped > 0) {
      try {
        await NotifService.markSynced().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    ServerInfo? si;
    try {
      si = await uploader.info();
    } catch (_) {
      si = null;
    }

    var summary = l10n.sendResult(done, skipped, failed);
    if (stoppedForStorage) summary += '\n${l10n.storageWarning(server.name)}';
    if (scanWarning != null) summary += '\n⚠️ $scanWarning';

    setState(() {
      _status = null;
      _selected.clear();
      _lastResult = summary;
      _lastOps = ops;
      _freeBytes = si?.freeBytes;
    });
    _showSnack(summary);
    if (scanWarning != null) _showScanSetupDialog();
  }

  Future<void> _fixSentDates() async {
    final l10n = AppLocalizations.of(context)!;
    final server = _currentServer;
    if (server == null) {
      _showSnack(l10n.noServerSet);
      return;
    }
    final targets = _all.where((m) => _sentIds.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack(l10n.noSentFiles);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.menuFixDates),
        content: Text(l10n.fixDatesContent(targets.length, server.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.btnCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.menuFixDates)),
        ],
      ),
    );
    if (ok != true) return;

    final uploader = Uploader(server);
    setState(() => _status = l10n.checkingServer);
    final caps = await uploader.info();
    if (caps == null) {
      setState(() => _status = null);
      _showConnectionDialog(server);
      return;
    }

    int fixed = 0;
    int miss = 0;
    await WakelockPlus.enable();
    await UploadService.start();
    try {
      for (var i = 0; i < targets.length; i++) {
        final m = targets[i];
        setState(() => _status = l10n.fixingDates(i + 1, targets.length));
        final r = await uploader.setDate(
            m.relativePath, m.createdAt.millisecondsSinceEpoch);
        if (r) {
          fixed++;
        } else {
          miss++;
        }
      }
      if (caps.supportsMediaScan) {
        setState(() => _status = l10n.rescanningPhotos(server.name));
        await uploader.scan();
      }
    } finally {
      await WakelockPlus.disable();
      await UploadService.stop();
    }

    final summary = l10n.fixDateResult(fixed, miss);
    setState(() {
      _status = null;
      _lastResult = summary;
    });
    _showSnack(summary);
  }

  Future<void> _deleteFromDevice(List<MediaItem> candidates,
      {bool skipConfirmation = false}) async {
    final l10n = AppLocalizations.of(context)!;
    final server = _currentServer;
    if (server == null) {
      _showSnack(l10n.noServerSet);
      return;
    }
    if (candidates.isEmpty) {
      _showSnack(l10n.noDeleteTargets);
      return;
    }

    if (!skipConfirmation) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(l10n.deleteFromDeviceTitle),
          content: Text(l10n.deleteFromDeviceContent(candidates.length, server.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.btnCancel)),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.btnConfirmDelete)),
          ],
        ),
      );
      if (ok != true) return;
    }

    final uploader = Uploader(server);
    setState(() => _status = l10n.checkingServer);
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showConnectionDialog(server);
      return;
    }

    final verified = <String>[];
    var unconfirmed = 0;
    final delOps = <String, FileOp>{};
    await WakelockPlus.enable();
    await UploadService.start();
    try {
      for (var i = 0; i < candidates.length; i++) {
        final m = candidates[i];
        setState(() => _status =
            l10n.verifyingReceipt(server.name, i + 1, candidates.length, m.title));
        final file = await m.originFile();
        if (file == null) {
          unconfirmed++;
          delOps[m.id] = FileOp(m, FileOpStatus.unconfirmed, l10n.fileGetFailed);
          continue;
        }
        String? hash;
        try {
          hash = await _sha256OfFile(file);
        } catch (_) {
          hash = null;
        }
        if (hash != null && await uploader.exists(hash)) {
          verified.add(m.id);
          delOps[m.id] = FileOp(m, FileOpStatus.deleted);
        } else {
          unconfirmed++;
          delOps[m.id] = FileOp(
              m,
              FileOpStatus.unconfirmed,
              hash == null
                  ? l10n.hashFailed
                  : l10n.notInLedger(server.name));
        }
      }
    } finally {
      await WakelockPlus.disable();
      await UploadService.stop();
    }

    if (verified.isEmpty) {
      setState(() {
        _status = null;
        _lastResult = l10n.deleteResultUnconfirmed(0, unconfirmed);
        _lastOps = delOps.values.toList();
      });
      _showSnack(l10n.nothingVerified(server.name));
      return;
    }

    setState(() => _status = l10n.deletingPrompt);
    List<String> deleted = const [];
    try {
      deleted = await PhotoManager.editor.deleteWithIds(verified);
    } catch (e) {
      setState(() => _status = null);
      _showSnack(l10n.deleteFailed(e.toString()));
      return;
    }

    for (final id in verified) {
      if (!deleted.contains(id)) {
        final existing = delOps[id]!;
        delOps[id] = FileOp(existing.item, FileOpStatus.failed, l10n.deleteLocalFailed);
      }
    }

    await _reloadMedia();
    final summary = l10n.deleteResultUnconfirmed(deleted.length, unconfirmed);
    setState(() {
      _status = null;
      _lastResult = summary;
      _lastOps = delOps.values.toList();
    });
    _showSnack(summary);
  }

  void _showScanSetupDialog() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.scanSetupTitle),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pixelのターミナル（Termux）で以下を実行してください：\n'),
              SelectableText(
                '1. pkg install termux-api\n'
                '2. F-DroidでTermux:APIアプリをインストール\n'
                '   （Play版のTermux:APIは動作しません）',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
              SizedBox(height: 12),
              Text('その後、Googleフォト側でも：\n'),
              SelectableText(
                '3. Googleフォト → ライブラリ\n'
                '   → デバイスのフォルダ → MediaRelay\n'
                '   → バックアップ ON',
                style: TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _reindexQuickShare() async {
    final l10n = AppLocalizations.of(context)!;
    final server = _currentServer;
    if (server == null) {
      _showSnack(l10n.noServerSet);
      return;
    }
    setState(() => _status = l10n.reindexing);
    final count = await Uploader(server).reindex();
    setState(() => _status = null);
    if (count != null) {
      _showSnack(l10n.reindexDone(count));
    } else {
      _showSnack(l10n.cannotConnectServer(server.name));
    }
  }

  Future<void> _runStartupAction(String action) async {
    if (_unsentCount == 0) return;
    final l10n = AppLocalizations.of(context)!;
    final server = _currentServer;
    if (server == null) return;
    final isDelete = action == AppSettings.startupActionSendAndDelete;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isDelete ? l10n.startupSendDeleteTitle : l10n.startupSendTitle),
        content: Text(isDelete
            ? l10n.startupSendDeleteContent(_unsentCount, server.name)
            : l10n.startupSendContent(_unsentCount, server.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.btnSkip)),
          FilledButton(
            style: isDelete
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(isDelete ? l10n.sendAndDeleteTitle : l10n.btnStartSend),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final targets = _all.where((m) => !_sentIds.contains(m.id)).toList();
    await _send(targets);
    if (!mounted || !isDelete) return;
    final sentItems = _lastOps
        .where((o) => o.status == FileOpStatus.sent)
        .map((o) => o.item)
        .toList();
    if (sentItems.isNotEmpty) {
      await _deleteFromDevice(sentItems, skipConfirmation: true);
    }
  }

  Future<void> _openPreview(MediaItem item) async {
    try {
      await const MethodChannel('com.kuboshige.media_relay/media_store')
          .invokeMethod('openAsset', {
        'id': item.id,
        'type': item.isVideo ? 2 : 1,
      });
    } catch (_) {}
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showConnectionDialog(ServerEntry server) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.connectionFailedTitle),
        content: Text(l10n.connectionFailedContent(
            server.name, server.host, server.port)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  String _fmtEta(int secs, AppLocalizations l10n) {
    if (secs >= 3600) {
      return l10n.etaHoursMinutes(secs ~/ 3600, (secs % 3600) ~/ 60);
    } else if (secs >= 60) {
      return l10n.etaMinutesSeconds(secs ~/ 60, secs % 60);
    }
    return l10n.etaSeconds(secs);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tabSend),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: l10n.pageHistory,
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HistoryPage())),
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: l10n.folderTooltip,
            onPressed: _openFolderSelect,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'toggle_sent') {
                setState(() => _showSent = !_showSent);
              } else if (v == 'send_all') {
                _sendAllUnsent();
              } else if (v == 'fix_dates') {
                _fixSentDates();
              } else if (v == 'delete_sent') {
                _deleteFromDevice(
                    _all.where((m) => _sentIds.contains(m.id)).toList());
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'toggle_sent',
                child: Text(_showSent ? l10n.menuHideSent : l10n.menuShowSent),
              ),
              PopupMenuItem(
                value: 'send_all',
                child: Text(l10n.menuSendAllUnsent),
              ),
              PopupMenuItem(
                value: 'fix_dates',
                child: Text(l10n.menuFixDates),
              ),
              PopupMenuItem(
                value: 'delete_sent',
                child: Text(l10n.menuDeleteAllSent),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(l10n),
      floatingActionButton: _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _status == null ? _sendSelected : null,
              icon: const Icon(Icons.send),
              label: Text(l10n.fabSend(_selected.length)),
            )
          : _unsentCount > 0
              ? FloatingActionButton.extended(
                  onPressed: _status == null ? _sendAllUnsent : null,
                  icon: const Icon(Icons.send),
                  label: Text(l10n.fabSendUnsent(_unsentCount)),
                )
              : null,
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.permissionDeniedBody),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _init,
                child: Text(l10n.btnRetry),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _serverBar(l10n),
        _statusBar(l10n),
        if (_status != null) const LinearProgressIndicator(minHeight: 3),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_status!),
          ),
        if (_status == null && _lastResult != null)
          InkWell(
            onTap: _hasOpDetail ? _showOpDetail : null,
            child: Container(
              width: double.infinity,
              color: Colors.green.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.task_alt, size: 18, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_lastResult!)),
                  if (_hasOpDetail) ...[
                    Text(l10n.labelDetail,
                        style: const TextStyle(color: Colors.teal, fontSize: 13)),
                    const Icon(Icons.chevron_right,
                        size: 18, color: Colors.teal),
                  ],
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      _lastResult = null;
                      _lastOps = [];
                    }),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: _visible.isEmpty
              ? Center(
                  child: Text(_showSent
                      ? l10n.noMediaInFolder
                      : l10n.allMediaSent),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: _visible.length,
                  itemBuilder: (context, i) => _thumb(_visible[i]),
                ),
        ),
      ],
    );
  }

  Widget _serverBar(AppLocalizations l10n) {
    final server = _currentServer;
    return Container(
      width: double.infinity,
      color: Colors.teal.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.dns, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              server == null
                  ? l10n.serverBarNoServer
                  : l10n.serverBarWithServer(server.name, server.host, server.port) +
                      (_freeBytes != null
                          ? l10n.freeSpaceSuffix(_fmtBytes(_freeBytes!))
                          : ''),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtBytes(int b) {
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
    }
    return '${(b / (1024 * 1024)).toStringAsFixed(0)}MB';
  }

  Widget _statusBar(AppLocalizations l10n) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.photo_library_outlined,
              size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          Text(
            _showSent
                ? l10n.statusBarAllMedia(_all.length, _unsentCount)
                : l10n.statusBarUnsent(_unsentCount),
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _showSelectionActions() async {
    final l10n = AppLocalizations.of(context)!;
    final n = _selected.length;
    final dest = _destName(l10n);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l10n.selectedCount(n),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.upload),
              title: Text(l10n.actionSendSelected(n, dest)),
              onTap: () => Navigator.pop(context, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text(l10n.actionSendAndDeleteSelected(n)),
              subtitle: Text(l10n.actionSendAndDeleteSubtitle(dest)),
              onTap: () => Navigator.pop(context, 'send_and_delete'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: Text(l10n.actionDeleteSelected(n),
                  style: const TextStyle(color: Colors.red)),
              subtitle: Text(l10n.actionDeleteOnlyConfirmed(dest)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.clear),
              title: Text(l10n.actionClearSelection),
              onTap: () => Navigator.pop(context, 'clear'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await _deleteFromDevice(
          _all.where((m) => _selected.contains(m.id)).toList());
    } else if (action == 'send') {
      await _sendSelected();
    } else if (action == 'send_and_delete') {
      await _sendAndDelete(
          _all.where((m) => _selected.contains(m.id)).toList());
    } else if (action == 'clear') {
      setState(() => _selected.clear());
    }
  }

  Widget _thumb(MediaItem item) {
    final selected = _selected.contains(item.id);
    final isSent = _sentIds.contains(item.id);
    return GestureDetector(
      onTap: () {
        if (_selected.isEmpty) {
          _openPreview(item);
        } else {
          setState(() {
            if (selected) {
              _selected.remove(item.id);
            } else {
              _selected.add(item.id);
            }
          });
        }
      },
      onLongPress: () {
        setState(() => _selected.add(item.id));
        _showSelectionActions();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder(
            future: item.asset
                .thumbnailDataWithSize(const ThumbnailSize(200, 200)),
            builder: (context, snap) {
              if (snap.hasData && snap.data != null) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              return Container(color: Colors.grey.shade300);
            },
          ),
          if (item.isVideo)
            const Positioned(
              right: 4,
              bottom: 4,
              child: Icon(Icons.videocam, color: Colors.white, size: 18),
            ),
          if (isSent)
            const Positioned(
              left: 4,
              top: 4,
              child: Icon(Icons.send_to_mobile, color: Colors.lightGreenAccent,
                  size: 18),
            ),
          if (selected)
            Container(
              color: Colors.teal.withValues(alpha: 0.4),
              child: const Icon(Icons.check_circle,
                  color: Colors.white, size: 32),
            ),
        ],
      ),
    );
  }
}
