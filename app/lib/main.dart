import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotifService.init();
  runApp(const MediaRelayApp());
}

class MediaRelayApp extends StatelessWidget {
  const MediaRelayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'media-relay',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

/// ボトムナビゲーションのシェル。3つのタブ（送信/受信/設定）を切り替える。
/// IndexedStack で全タブを生かし続けることで、受信サーバーはタブ切替後も動き続ける。
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
            // 設定タブから戻った時にサーバーリストを更新する。
            _homeKey.currentState?._refreshServers();
          }
          setState(() => _currentIndex = i);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.upload_outlined),
            selectedIcon: Icon(Icons.upload),
            label: '送信',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: '受信',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
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
  bool _showSent = false; // 既定は未送信のみ表示
  List<ServerEntry> _servers = [];
  int _selectedServer = 0;
  String? _status;
  int _lastProgressTs = 0; // 送信進捗の表示更新スロットル用（約1秒間隔）
  String? _lastResult; // 直近の送信結果（消えずに残す）
  List<FileOp> _lastOps = []; // 直近の操作結果（ファイルごと）
  int? _freeBytes; // Pixelの空き容量

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

    // 未送信リマインダー：通知許可を確認し、設定にもとづいて予約し直す
    await NotifService.requestPermission();
    await NotifService.reschedule();
    _refreshFreeSpace();
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

  /// 画面に表示する一覧（未送信のみ / すべて）
  List<MediaItem> get _visible => _showSent
      ? _all
      : _all.where((m) => !_sentIds.contains(m.id)).toList();

  int get _unsentCount =>
      _all.where((m) => !_sentIds.contains(m.id)).length;

  /// 送信先の表示名。システムメッセージはこの名前を使う（「Pixel」固定にしない）。
  String get _destName => _currentServer?.name ?? '送信先';

  ServerEntry? get _currentServer {
    if (_servers.isEmpty) return null;
    final i = _selectedServer.clamp(0, _servers.length - 1);
    return _servers[i];
  }

  /// 設定タブから送信タブに戻ったときに呼ばれる（MainShell から呼び出し）。
  Future<void> _refreshServers() async {
    _servers = await ServerConfig.load();
    _selectedServer = await ServerConfig.selectedIndex();
    if (mounted) setState(() {});
  }

  bool get _hasOpDetail => _lastOps.any((o) => o.needsAttention);

  Future<void> _showOpDetail() async {
    final result = await Navigator.push<DetailPageResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ResultDetailPage(ops: _lastOps, serverName: _destName),
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

  /// 受領確認なしでファイルを強制削除する（確認ダイアログは詳細ページで表示済み）。
  Future<void> _forceDeleteFromDevice(List<MediaItem> candidates) async {
    if (candidates.isEmpty) return;
    setState(() => _status = '削除中…（端末の確認ダイアログで許可してください）');
    final ids = candidates.map((m) => m.id).toList();
    List<String> deleted = const [];
    try {
      deleted = await PhotoManager.editor.deleteWithIds(ids);
    } catch (e) {
      setState(() => _status = null);
      _showSnack('削除に失敗しました: $e');
      return;
    }
    final ops = candidates.map((m) {
      return deleted.contains(m.id)
          ? FileOp(m, FileOpStatus.deleted)
          : FileOp(m, FileOpStatus.failed, '端末の削除処理が失敗しました');
    }).toList();
    await _reloadMedia();
    final summary =
        '削除: ${deleted.length} 件 / 失敗 ${candidates.length - deleted.length} 件';
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
    final targets = _visible.where((m) => _selected.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack('送信するファイルを選択してください');
      return;
    }
    await _send(targets);
  }

  /// 指定ファイルを送信し、成功分を Googleフォト警告ダイアログ経由で端末から削除する。
  Future<void> _sendAndDelete(List<MediaItem> targets) async {
    // 操作前に事前警告を表示する。送信後では Google フォトのバックアップが完了しているかを
    // ユーザーが確認できないため、「後で確認する」選択肢を先に提示する。
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('送信して削除'),
        content: Text(
          '${targets.length} 件を$_destNameに送信後、送信できたファイルをこの端末から削除します。\n\n'
          '⚠️ ${_destName}側でGoogleフォト等のクラウドバックアップが完了するまでに'
          '時間がかかる場合があります。削除を急がない場合は「送信のみ」を使い、'
          'バックアップ完了後に別途削除することをお勧めします。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('送信して削除'),
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
    final targets = _all.where((m) => !_sentIds.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack('未送信のファイルはありません');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('未送信をすべて送信'),
        content: Text('${targets.length} 件を送信します。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('送信')),
        ],
      ),
    );
    if (ok == true) await _send(targets);
  }

  Future<void> _send(List<MediaItem> targets) async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定で送信先サーバーを登録してください');
      return;
    }

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
    final caps = await uploader.info();
    if (caps == null) {
      setState(() => _status = null);
      _showConnectionDialog(server);
      return;
    }
    // 受信側がMediaStore登録に非対応（アプリ内受信）なら /scan を呼ばない
    final supportsScan = caps.supportsMediaScan;

    int done = 0;
    int skipped = 0;
    int failed = 0;
    var stoppedForStorage = false;
    final ops = <FileOp>[];

    // 送信中は画面を消さない＋バックグラウンドに移動しても送信継続
    await WakelockPlus.enable();
    await UploadService.start();
    try {
      for (var i = 0; i < targets.length; i++) {
        final item = targets[i];
        setState(() =>
            _status = '送信中 ${i + 1}/${targets.length}: ${item.title}');

        final file = await item.originFile();
        if (file == null) {
          failed++;
          ops.add(FileOp(item, FileOpStatus.failed, 'ファイルを取得できませんでした'));
          await SentStore.log(
            assetId: item.id,
            title: item.title,
            relativePath: item.relativePath,
            status: 'failed',
            detail: 'ファイルを取得できませんでした',
          );
          continue;
        }

        // 内容ハッシュを計算し、サーバーに既にあれば送らずに済ます
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
          detail = '${server.name}に既に存在';
          ops.add(FileOp(item, FileOpStatus.skipped, '${server.name}に既に存在'));
        } else {
          // アプリ内受信(app=true)は生アップロード＋MB進捗、旧nodeはmultipart。
          DateTime? fileStart;
          final res = caps.app
              ? await uploader.uploadRaw(file, item.relativePath,
                  originalDateMs: item.createdAt.millisecondsSinceEpoch,
                  onProgress: (sent, total) {
                  fileStart ??= DateTime.now();
                  // 約1秒間隔に間引く（毎MBの全画面再描画＝チラつき防止）
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
                    if (etaSec > 0) eta = ' · あと${_fmtEta(etaSec)}';
                  }
                  setState(() => _status =
                      '送信中 ${i + 1}/${targets.length}: ${item.title}  $s/$t MB$eta');
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
            // 空き容量不足：このファイルは送れないのでバッチを中断
            stoppedForStorage = true;
            ops.add(FileOp(item, FileOpStatus.failed, '${server.name}の空き容量不足で中断'));
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

    // 送信したファイルをGoogleフォトに出すため、MediaStoreへ登録させる。
    // アプリ内受信（MediaStore非対応）の場合はスキップ（無駄な待ちを防ぐ）。
    String? scanWarning;
    if (done > 0 && supportsScan) {
      setState(() => _status = '${server.name}で写真を登録中…（Googleフォト用）');
      final scanError = await uploader.scan();
      if (scanError != null) {
        scanWarning = 'Googleフォト登録失敗 — Pixel側で termux-api のセットアップが必要です';
      }
    } else if (done > 0 && caps.needsScanSetup) {
      scanWarning = 'Pixel側で termux-api のセットアップが必要です（Googleフォトに表示されません）';
    }

    // 送信が行われたら、未送信リマインダーを次回へ先送りする。
    // ここがハングしても送信完了表示が止まらないよう、必ず時間制限で抜ける。
    if (done > 0 || skipped > 0) {
      try {
        await NotifService.markSynced().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    // 空き容量を更新表示（失敗・タイムアウトしても完了処理は進める）
    ServerInfo? si;
    try {
      si = await uploader.info();
    } catch (_) {
      si = null;
    }

    final summary =
        '完了: 送信 $done 件 / スキップ $skipped 件 / 失敗 $failed 件'
        '${stoppedForStorage ? '\n⚠️ ${server.name}の空き容量不足で中断しました' : ''}'
        '${scanWarning != null ? '\n⚠️ $scanWarning' : ''}';
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

  /// 既に送信済みのファイルの「撮影日付」をPixel側で修正する（再転送なし）。
  /// 書き込み時に今日の日付になってしまった分を、元の撮影日時に直す。
  Future<void> _fixSentDates() async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定で送信先サーバーを登録してください');
      return;
    }
    final targets = _all.where((m) => _sentIds.contains(m.id)).toList();
    if (targets.isEmpty) {
      _showSnack('送信済みのファイルがありません');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('送信済みの日付を修正'),
        content: Text('${targets.length} 件の撮影日付を${server.name}側で修正します'
            '（再転送はしません）。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('修正')),
        ],
      ),
    );
    if (ok != true) return;

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
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
        setState(() => _status = '日付を修正中 ${i + 1}/${targets.length}');
        final r = await uploader.setDate(
            m.relativePath, m.createdAt.millisecondsSinceEpoch);
        if (r) {
          fixed++;
        } else {
          miss++;
        }
      }
      if (caps.supportsMediaScan) {
        setState(() => _status = '${server.name}で再登録中…（Googleフォト用）');
        await uploader.scan(); // 失敗は無視（日付修正の主目的には影響しない）
      }
    } finally {
      await WakelockPlus.disable();
      await UploadService.stop();
    }

    final summary = '日付修正: 成功 $fixed 件 / 対象外 $miss 件';
    setState(() {
      _status = null;
      _lastResult = summary;
    });
    _showSnack(summary);
  }

  /// 指定したファイルをこの端末（Motorola）から削除する。
  /// 安全のため、削除直前に1件ずつPixelへ受領確認し、確認できたものだけ消す。
  /// [skipConfirmation] が true のときは冒頭の確認ダイアログを省略する（送信直後の削除用）。
  Future<void> _deleteFromDevice(List<MediaItem> candidates,
      {bool skipConfirmation = false}) async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定で送信先サーバーを登録してください');
      return;
    }
    if (candidates.isEmpty) {
      _showSnack('削除対象がありません');
      return;
    }

    if (skipConfirmation) {
      // 送信直後の削除。確認ダイアログはすでに表示済みのためスキップ。
    } else {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('この端末から削除'),
        content: Text(
          '${candidates.length} 件をこの端末から削除します。\n\n'
          '・削除直前に${server.name}が受領済みか1件ずつ確認し、確認できたものだけ消します\n'
          '  （${server.name}で「空き容量を増やす」をしてディスクから消えていてもOK）\n'
          '・${server.name}（とGoogleフォトなどのクラウドBK）側のコピーは残ります\n'
          '・実行すると端末の削除確認ダイアログが出ます\n\n'
          '※ ${server.name}側のバックアップ完了を確認してから実行してください',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('確認して削除')),
        ],
      ),
    );
    if (ok != true) return;
    }

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showConnectionDialog(server);
      return;
    }

    // 受領確認は永続台帳ベース（/exists）。台帳に無いハッシュだけサーバ側が
    // 自動でディスク走査するので、ここで重い /reindex を呼ぶ必要はない。
    final verified = <String>[]; // 削除してよい asset id
    var unconfirmed = 0;
    final delOps = <String, FileOp>{}; // assetId → FileOp
    await WakelockPlus.enable();
    await UploadService.start();
    try {
      for (var i = 0; i < candidates.length; i++) {
        final m = candidates[i];
        setState(() =>
            _status =
                '${server.name}受領確認中 ${i + 1}/${candidates.length}: ${m.title}');
        final file = await m.originFile();
        if (file == null) {
          unconfirmed++;
          delOps[m.id] = FileOp(m, FileOpStatus.unconfirmed, 'ファイルを取得できませんでした');
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
          delOps[m.id] = FileOp(m, FileOpStatus.deleted); // 削除予定（後で確定）
        } else {
          unconfirmed++;
          delOps[m.id] = FileOp(
              m,
              FileOpStatus.unconfirmed,
              hash == null
                  ? 'ハッシュ計算に失敗しました'
                  : '${server.name}の受領記録にありません（まず送信してください）');
        }
      }
    } finally {
      await WakelockPlus.disable();
      await UploadService.stop();
    }

    if (verified.isEmpty) {
      setState(() {
        _status = null;
        _lastResult = '削除: 0 件 / 未確認でスキップ $unconfirmed 件';
        _lastOps = delOps.values.toList();
      });
      _showSnack('${server.name}が受領済みのファイルがありませんでした（削除中止）');
      return;
    }

    setState(() => _status = '削除中…（端末の確認ダイアログで許可してください）');
    List<String> deleted = const [];
    try {
      deleted = await PhotoManager.editor.deleteWithIds(verified);
    } catch (e) {
      setState(() => _status = null);
      _showSnack('削除に失敗しました: $e');
      return;
    }

    // 実際に削除されなかったものを「失敗」に更新
    for (final id in verified) {
      if (!deleted.contains(id)) {
        final existing = delOps[id]!;
        delOps[id] = FileOp(existing.item, FileOpStatus.failed, '端末の削除処理が失敗しました');
      }
    }

    await _reloadMedia();
    final summary =
        '削除: ${deleted.length} 件 / 未確認でスキップ $unconfirmed 件';
    setState(() {
      _status = null;
      _lastResult = summary;
      _lastOps = delOps.values.toList();
    });
    _showSnack(summary);
  }

  /// Googleフォトに表示するためのtermux-apiセットアップ手順を表示する。
  void _showScanSetupDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Googleフォトに表示するには'),
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

  /// クイックシェアで届いたファイルをサーバーの重複チェック索引に取り込む。
  /// 通常の送信前には不要（台帳で管理済み）。手動で実行したいときにのみ使う。
  Future<void> _reindexQuickShare() async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定で送信先サーバーを登録してください');
      return;
    }
    setState(() => _status = 'クイックシェアのファイルを索引に追加中…');
    final count = await Uploader(server).reindex();
    setState(() => _status = null);
    if (count != null) {
      _showSnack('索引を更新しました（合計 $count 件）');
    } else {
      _showSnack('${server.name}に接続できませんでした');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 接続失敗時に原因候補を列挙したダイアログを表示する。
  void _showConnectionDialog(ServerEntry server) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('接続できませんでした'),
        content: Text(
          '${server.name}（${server.host}:${server.port}）に接続できません。\n\n'
          '確認してください：\n'
          '・受信側アプリの「受信」タブでサーバーを開始しているか\n'
          '・2台が同じWi-Fiに繋がっているか\n'
          '  ルーターが2.4GHzと5GHzを別々に出している場合は\n'
          '  同じ帯域（どちらか一方）に揃えてください\n'
          '・ルーターの「APアイソレーション（クライアント分離）」\n'
          '  がオンになっていると端末同士が繋がりません',
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

  String _fmtEta(int secs) {
    if (secs >= 3600) {
      return '${secs ~/ 3600}時間${(secs % 3600) ~/ 60}分';
    } else if (secs >= 60) {
      return '${secs ~/ 60}分${secs % 60}秒';
    }
    return '$secs秒';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('送信'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '送信履歴',
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const HistoryPage())),
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: '送信対象フォルダ',
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
                child: Text(_showSent ? '送信済みを隠す' : '送信済みも表示'),
              ),
              const PopupMenuItem(
                value: 'send_all',
                child: Text('未送信をすべて送信'),
              ),
              const PopupMenuItem(
                value: 'fix_dates',
                child: Text('送信済みの日付を修正'),
              ),
              const PopupMenuItem(
                value: 'delete_sent',
                child: Text('送信済みを全件この端末から削除'),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _visible.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _status == null ? _sendSelected : null,
              icon: const Icon(Icons.send),
              label: Text('送信 (${_selected.length})'),
            ),
    );
  }

  Widget _buildBody() {
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
              const Text('メディアへのアクセスが許可されていません。\n'
                  '設定アプリで権限を許可してください。'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _init,
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _serverBar(),
        _statusBar(),
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
                    const Text('詳細',
                        style: TextStyle(color: Colors.teal, fontSize: 13)),
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
                      ? '対象フォルダにメディアがありません'
                      : '未送信のメディアはありません 🎉'),
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

  Widget _serverBar() {
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
                  ? '送信先未設定 — 設定から登録してください'
                  : '送信先: ${server.name} (${server.host}:${server.port})'
                      '${_freeBytes != null ? ' · 空き ${_fmtBytes(_freeBytes!)}' : ''}',
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

  Widget _statusBar() {
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
                ? '全 ${_all.length} 件（未送信 $_unsentCount 件）'
                : '未送信 $_unsentCount 件',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 長押しで開く、選択中ファイルへの操作メニュー。
  Future<void> _showSelectionActions() async {
    final n = _selected.length;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('選択中: $n 件',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.upload),
              title: Text('選んだ $n 件を$_destNameに送信'),
              onTap: () => Navigator.pop(context, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text('選んだ $n 件を送信して削除'),
              subtitle: Text('$_destNameに送信後、Googleフォト警告を確認してから端末から削除'),
              onTap: () => Navigator.pop(context, 'send_and_delete'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: Text('選んだ $n 件をこの端末から削除',
                  style: const TextStyle(color: Colors.red)),
              subtitle: Text('$_destNameが受領済みのものだけ消します'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('選択をクリア'),
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
        setState(() {
          if (selected) {
            _selected.remove(item.id);
          } else {
            _selected.add(item.id);
          }
        });
      },
      onLongPress: () {
        // 長押し：未選択なら選択に加えてから、選択分の操作メニューを出す
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
              // 「Pixelへ転送済み」を表す。クラウド保存済みではないので雲は使わない。
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
