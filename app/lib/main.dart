import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'media_source.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'settings_page.dart';

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
  List<MediaItem> _items = [];
  final Set<String> _selected = {};
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
    final items = await MediaSource.listAll();
    setState(() {
      _items = items;
      _loading = false;
    });
  }

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

  Future<void> _sendSelected() async {
    final server = _currentServer;
    if (server == null) {
      _showSnack('先に設定でPixelのサーバーを登録してください');
      return;
    }
    if (_selected.isEmpty) {
      _showSnack('送信するファイルを選択してください');
      return;
    }

    final uploader = Uploader(server);
    setState(() => _status = 'サーバー確認中…');
    if (!await uploader.ping()) {
      setState(() => _status = null);
      _showSnack('Pixelに接続できません（${server.host}:${server.port}）');
      return;
    }

    final targets = _items.where((m) => _selected.contains(m.id)).toList();
    int done = 0;
    int failed = 0;
    for (final item in targets) {
      setState(() => _status =
          '送信中 ${done + failed + 1}/${targets.length}: ${item.title}');
      final file = await item.originFile();
      if (file == null) {
        failed++;
        continue;
      }
      final res = await uploader.upload(file, item.relativePath);
      if (res.ok) {
        done++;
      } else {
        failed++;
      }
    }

    setState(() {
      _status = null;
      _selected.clear();
    });
    _showSnack('完了: 成功 $done 件 / 失敗 $failed 件');
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
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: _items.isEmpty
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
        if (_status != null) const LinearProgressIndicator(minHeight: 3),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_status!),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) => _thumb(_items[i]),
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

  Widget _thumb(MediaItem item) {
    final selected = _selected.contains(item.id);
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
                .thumbnailDataWithSize(const ThumbnailSize.square(200)),
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
