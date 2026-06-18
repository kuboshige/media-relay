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
          final res = await uploader.upload(file, item.relativePath);
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
              child: Icon(Icons.cloud_done, color: Colors.lightGreenAccent,
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
