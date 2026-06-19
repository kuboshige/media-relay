import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'media_source.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'settings_page.dart';
import 'folder_config.dart';
import 'folder_select_page.dart';
import 'sent_store.dart';
import 'history_page.dart';

void main() {
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
      home: const HomePage(),
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
  String? _lastResult; // 直近の送信結果（消えずに残す）
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

  ServerEntry? get _currentServer {
    if (_servers.isEmpty) return null;
    final i = _selectedServer.clamp(0, _servers.length - 1);
    return _servers[i];
  }

  Future<void> _openSettings() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const SettingsPage()));
    _servers = await ServerConfig.load();
    _selectedServer = await ServerConfig.selectedIndex();
    setState(() {});
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
      _showSnack('先に設定でPixelのサーバーを登録してください');
      return;
    }

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showSnack('Pixelに接続できません（${server.host}:${server.port}）');
      return;
    }

    int done = 0;
    int skipped = 0;
    int failed = 0;
    var stoppedForStorage = false;

    // 送信中は画面を消さない（スリープで止まるのを防ぐ）
    await WakelockPlus.enable();
    try {
      // クイックシェアで受信済みのファイルも検出できるよう、
      // 送信前にサーバーのハッシュ索引を最新化しておく。
      setState(() => _status = 'Pixel側を照合準備中…（初回は時間がかかります）');
      await uploader.reindex();

      for (var i = 0; i < targets.length; i++) {
        final item = targets[i];
        setState(() =>
            _status = '送信中 ${i + 1}/${targets.length}: ${item.title}');

        final file = await item.originFile();
        if (file == null) {
          failed++;
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
          detail = 'Pixelに既に存在';
        } else {
          final res = await uploader.upload(file, item.relativePath,
              originalDateMs: item.createdAt.millisecondsSinceEpoch);
          if (res.ok) {
            done++;
            success = true;
            status = 'sent';
          } else if (res.insufficientStorage) {
            // 空き容量不足：このファイルは送れないのでバッチを中断
            stoppedForStorage = true;
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
    }

    // 送信したファイルをGoogleフォトに出すため、PixelのMediaStoreへ登録させる
    if (done > 0) {
      setState(() => _status = 'Pixelで写真を登録中…（Googleフォト用）');
      await uploader.scan();
    }

    // 空き容量を更新表示
    final si = await uploader.info();

    final summary =
        '完了: 送信 $done 件 / スキップ $skipped 件 / 失敗 $failed 件'
        '${stoppedForStorage ? '\n⚠️ Pixelの空き容量不足で中断しました' : ''}';
    setState(() {
      _status = null;
      _selected.clear();
      _lastResult = summary;
      _freeBytes = si?.freeBytes;
    });
    _showSnack(summary);
  }

  /// 既に送信済みのファイルの「撮影日付」をPixel側で修正する（再転送なし）。
  /// 書き込み時に今日の日付になってしまった分を、元の撮影日時に直す。
  Future<void> _fixSentDates() async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定でPixelのサーバーを登録してください');
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
        content: Text('${targets.length} 件の撮影日付をPixel側で修正します'
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
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showSnack('Pixelに接続できません（${server.host}:${server.port}）');
      return;
    }

    int fixed = 0;
    int miss = 0;
    await WakelockPlus.enable();
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
      setState(() => _status = 'Pixelで再登録中…（Googleフォト用）');
      await uploader.scan();
    } finally {
      await WakelockPlus.disable();
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
  Future<void> _deleteFromDevice(List<MediaItem> candidates) async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定でPixelのサーバーを登録してください');
      return;
    }
    if (candidates.isEmpty) {
      _showSnack('削除対象がありません');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('この端末から削除'),
        content: Text(
          '${candidates.length} 件をこの端末から削除します。\n\n'
          '・削除直前にPixelが受領済みか1件ずつ確認し、確認できたものだけ消します\n'
          '  （Pixelで「空き容量を増やす」をしてディスクから消えていてもOK）\n'
          '・Pixel（とGoogleフォト）側のコピーは残ります\n'
          '・実行すると端末の削除確認ダイアログが出ます\n\n'
          '※ Pixelのフォトへのバックアップ完了を確認してから実行してください',
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

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showSnack('Pixelに接続できません（${server.host}:${server.port}）');
      return;
    }

    // Pixelの索引を最新化してから生存確認する
    setState(() => _status = 'Pixel側を確認準備中…');
    await uploader.reindex();

    final verified = <String>[]; // 削除してよい asset id
    var unconfirmed = 0;
    await WakelockPlus.enable();
    try {
      for (var i = 0; i < candidates.length; i++) {
        final m = candidates[i];
        setState(() =>
            _status = 'クラウド確認中 ${i + 1}/${candidates.length}: ${m.title}');
        final file = await m.originFile();
        if (file == null) {
          unconfirmed++;
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
        } else {
          unconfirmed++;
        }
      }
    } finally {
      await WakelockPlus.disable();
    }

    if (verified.isEmpty) {
      setState(() => _status = null);
      _showSnack('Pixelで存在を確認できたファイルがありませんでした（削除中止）');
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

    await _reloadMedia();
    final summary =
        '削除: ${deleted.length} 件 / 未確認でスキップ $unconfirmed 件';
    setState(() {
      _status = null;
      _lastResult = summary;
    });
    _showSnack(summary);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('media-relay'),
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
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '送信先サーバー設定',
            onPressed: _openSettings,
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
          Container(
            width: double.infinity,
            color: Colors.green.withValues(alpha: 0.08),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.task_alt, size: 18, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(child: Text(_lastResult!)),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _lastResult = null),
                ),
              ],
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
              title: Text('選んだ $n 件をPixelに送信'),
              onTap: () => Navigator.pop(context, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: Text('選んだ $n 件をこの端末から削除',
                  style: const TextStyle(color: Colors.red)),
              subtitle: const Text('Pixelが受領済みのものだけ消します'),
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
