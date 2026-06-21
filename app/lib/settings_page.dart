import 'package:flutter/material.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'app_settings.dart';
import 'notif_service.dart';
import 'qr_scan_page.dart';

/// Pixelサーバーの登録・選択画面（家・職場など複数登録できる）
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<ServerEntry> _servers = [];
  int _selected = 0;
  int _reminderDays = AppSettings.defaultReminderDays;
  // 受信設定
  String _deviceName = '';
  int _receiverPort = AppSettings.defaultReceiverPort;
  int _autoStopMinutes = AppSettings.defaultAutoStopMinutes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _servers = await ServerConfig.load();
    _selected = await ServerConfig.selectedIndex();
    _reminderDays = await AppSettings.reminderDays();
    _deviceName = await AppSettings.deviceName();
    _receiverPort = await AppSettings.receiverPort();
    _autoStopMinutes = await AppSettings.receiverAutoStopMinutes();
    setState(() {});
  }

  Future<void> _setReminderDays(int v) async {
    setState(() => _reminderDays = v);
    await AppSettings.setReminderDays(v);
    if (v > 0) await NotifService.requestPermission();
    await NotifService.reschedule();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(v <= 0 ? 'リマインダーをオフにしました' : '$v日ごとに送信を促します')));
  }

  String _reminderLabel(int d) => d <= 0 ? 'オフ' : '$d日';

  Widget _reminderTile() {
    return ListTile(
      leading: const Icon(Icons.notifications_active),
      title: const Text('未送信リマインダー'),
      subtitle: Text(_reminderDays <= 0
          ? 'オフ'
          : '最後の送信から$_reminderDays日後に通知します'),
      trailing: DropdownButton<int>(
        value: _reminderDays,
        onChanged: (v) {
          if (v != null) _setReminderDays(v);
        },
        items: [
          for (final d in AppSettings.reminderChoices)
            DropdownMenuItem(value: d, child: Text(_reminderLabel(d))),
        ],
      ),
    );
  }

  Future<void> _editDeviceName() async {
    final ctrl = TextEditingController(text: _deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('この端末の名前'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例: 家のPixel'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await AppSettings.setDeviceName(name);
      setState(() => _deviceName = name);
    }
  }

  Future<void> _editReceiverPort() async {
    final ctrl = TextEditingController(text: '$_receiverPort');
    final portStr = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('受信ポート番号'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '例: 8765'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    final port = int.tryParse(portStr ?? '');
    if (port != null && port > 1024 && port < 65536) {
      await AppSettings.setReceiverPort(port);
      setState(() => _receiverPort = port);
    }
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      );

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

  Future<void> _addFromQr() async {
    final entry = await Navigator.push<ServerEntry>(
        context, MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (entry == null) return;
    setState(() {
      _servers.add(entry);
      _selected = _servers.length - 1;
    });
    await _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('追加: ${entry.name} (${entry.host}:${entry.port})')));
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
      appBar: AppBar(
        title: const Text('設定'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'QRで送信先を追加',
            onPressed: _addFromQr,
          ),
        ],
      ),
      body: Column(
        children: [
          _sectionHeader('通知'),
          _reminderTile(),
          const Divider(height: 1),
          _sectionHeader('受信設定'),
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: const Text('この端末の名前'),
            subtitle: Text(_deviceName.isEmpty ? '未設定' : _deviceName),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editDeviceName,
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('受信ポート'),
            subtitle: Text('$_receiverPort'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editReceiverPort,
          ),
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: const Text('無通信で自動停止'),
            subtitle: Text(_autoStopMinutes == 0
                ? 'オフ'
                : '最後の受信から $_autoStopMinutes 分後'),
            trailing: DropdownButton<int>(
              value: _autoStopMinutes,
              onChanged: (v) async {
                if (v == null) return;
                await AppSettings.setReceiverAutoStopMinutes(v);
                setState(() => _autoStopMinutes = v);
              },
              items: [
                for (final m in AppSettings.autoStopChoices)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m == 0 ? '停止しない' : '${m}分'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          _sectionHeader('送信先サーバー'),
          Expanded(
            child: _servers.isEmpty
                ? const Center(
                    child: Text('サーバー未登録\n右下の＋から追加',
                        textAlign: TextAlign.center))
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
          ),
        ],
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
