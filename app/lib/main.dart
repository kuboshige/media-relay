import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'media_source.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'settings_page.dart';
import 'folder_config.dart';
import 'folder_select_page.dart';
import 'sent_store.dart';

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
    for (var i = 0; i < targets.length; i++) {
      final item = targets[i];
      setState(() =>
          _status = '送信中 ${i + 1}/${targets.length}: ${item.title}');

      final file = await item.originFile();
      if (file == null) {
        failed++;
        continue;
      }

      // 内容ハッシュを計算し、サーバーに既にあれば送らずに済ます
      String? hash;
      try {
        hash = await _sha256OfFile(file);
      } catch (_) {
        hash = null;
      }

      var success = false;
      if (hash != null && await uploader.exists(hash)) {
        skipped++;
        success = true;
      } else {
        final res = await uploader.upload(file, item.relativePath);
        if (res.ok) {
          done++;
          success = true;
        } else {
          failed++;
        }
      }

      if (success) {
        int? size;
        try {
          size = await file.length();
        } catch (_) {
          size = null;
        }
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

    setState(() {
      _status = null;
      _selected.clear();
    });
    _showSnack(
        '完了: 送信 $done 件 / スキップ $skipped 件 / 失敗 $failed 件');
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
                  : '送信先: ${server.name} (${server.host}:${server.port})',
            ),
          ),
        ],
      ),
    );
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
