import 'package:flutter/material.dart';
import 'server_config.dart';
import 'uploader.dart';

/// Pixelサーバーの登録・選択画面（家・職場など複数登録できる）
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<ServerEntry> _servers = [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _servers = await ServerConfig.load();
    _selected = await ServerConfig.selectedIndex();
    setState(() {});
  }

  Future<void> _persist() async {
    await ServerConfig.save(_servers);
    await ServerConfig.setSelectedIndex(_selected);
  }

  Future<void> _edit({int? index}) async {
    final entry = index != null ? _servers[index] : null;
    final result = await showDialog<ServerEntry>(
      context: context,
      builder: (_) => _ServerDialog(entry: entry),
    );
    if (result == null) return;
    setState(() {
      if (index != null) {
        _servers[index] = result;
      } else {
        _servers.add(result);
        _selected = _servers.length - 1;
      }
    });
    await _persist();
  }

  Future<void> _delete(int index) async {
    setState(() {
      _servers.removeAt(index);
      if (_selected >= _servers.length) {
        _selected = _servers.isEmpty ? 0 : _servers.length - 1;
      }
    });
    await _persist();
  }

  Future<void> _test(ServerEntry s) async {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('接続確認中…')));
    final ok = await Uploader(s).ping();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? '接続OK: ${s.name}' : '接続できません: ${s.host}:${s.port}')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('送信先サーバー設定')),
      body: _servers.isEmpty
          ? const Center(child: Text('サーバー未登録\n右下の＋から追加', textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: _servers.length,
              itemBuilder: (context, i) {
                final s = _servers[i];
                return RadioListTile<int>(
                  value: i,
                  groupValue: _selected,
                  onChanged: (v) async {
                    setState(() => _selected = v!);
                    await _persist();
                  },
                  title: Text(s.name),
                  subtitle: Text('${s.host}:${s.port}'),
                  secondary: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.wifi_tethering),
                        tooltip: '接続テスト',
                        onPressed: () => _test(s),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () => _edit(index: i),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _delete(i),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ServerDialog extends StatefulWidget {
  final ServerEntry? entry;
  const _ServerDialog({this.entry});

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.entry?.name ?? '');
  late final TextEditingController _host =
      TextEditingController(text: widget.entry?.host ?? '');
  late final TextEditingController _port =
      TextEditingController(text: (widget.entry?.port ?? 8765).toString());

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? 'サーバー追加' : 'サーバー編集'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
                labelText: '表示名', hintText: '例: 家のPixel'),
          ),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
                labelText: 'IPアドレス / ホスト名', hintText: '例: 192.168.1.20'),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: 'ポート'),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final host = _host.text.trim();
            final port = int.tryParse(_port.text.trim()) ?? 8765;
            if (host.isEmpty) return;
            Navigator.pop(
              context,
              ServerEntry(
                name: name.isEmpty ? host : name,
                host: host,
                port: port,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
