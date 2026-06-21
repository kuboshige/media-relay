import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
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
  String _startupAction = AppSettings.startupActionNone;
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
    _startupAction = await AppSettings.startupAction();
    _deviceName = await AppSettings.deviceName();
    _receiverPort = await AppSettings.receiverPort();
    _autoStopMinutes = await AppSettings.receiverAutoStopMinutes();
    setState(() {});
  }

  String _startupActionLabel(String v) {
    switch (v) {
      case AppSettings.startupActionSend:
        return '未送信を自動送信';
      case AppSettings.startupActionSendAndDelete:
        return '未送信を送信して削除';
      default:
        return '何もしない';
    }
  }

  Widget _startupActionTile() {
    return ListTile(
      leading: const Icon(Icons.play_circle_outline),
      title: const Text('アプリを開いた時の動作'),
      subtitle: Text(_startupActionLabel(_startupAction)),
      trailing: DropdownButton<String>(
        value: _startupAction,
        onChanged: (v) async {
          if (v == null) return;
          await AppSettings.setStartupAction(v);
          setState(() => _startupAction = v);
        },
        items: [
          DropdownMenuItem(
              value: AppSettings.startupActionNone,
              child: Text(_startupActionLabel(AppSettings.startupActionNone))),
          DropdownMenuItem(
              value: AppSettings.startupActionSend,
              child: Text(_startupActionLabel(AppSettings.startupActionSend))),
          DropdownMenuItem(
              value: AppSettings.startupActionSendAndDelete,
              child: Text(_startupActionLabel(AppSettings.startupActionSendAndDelete))),
        ],
      ),
    );
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

  Widget _sectionHeader(String title, {List<Widget>? actions}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            if (actions != null) ...actions,
          ],
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

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('開けませんでした: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          // ━━━━ 送信先サーバー ━━━━
          _sectionHeader('送信先サーバー', actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: 'QRで追加',
              onPressed: _addFromQr,
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: '手動追加',
              onPressed: () => _edit(),
            ),
          ]),
          if (_servers.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('サーバー未登録'),
              subtitle: Text('右のQRアイコンでスキャン、または＋で手動追加'),
            )
          else
            for (int i = 0; i < _servers.length; i++)
              RadioListTile<int>(
                value: i,
                groupValue: _selected,
                onChanged: (v) async {
                  setState(() => _selected = v!);
                  await _persist();
                },
                title: Text(_servers[i].name),
                subtitle: Text('${_servers[i].host}:${_servers[i].port}'
                    '${_servers[i].token != null ? ' 🔒' : ''}'),
                secondary: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.wifi_tethering),
                      tooltip: '接続テスト',
                      onPressed: () => _test(_servers[i]),
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
              ),
          const Divider(height: 1),

          // ━━━━ 起動時の動作 ━━━━
          _sectionHeader('起動時の動作'),
          _startupActionTile(),
          const Divider(height: 1),

          // ━━━━ 受信設定 ━━━━
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

          // ━━━━ 通知 ━━━━
          _sectionHeader('通知'),
          _reminderTile(),
          const Divider(height: 1),

          // ━━━━ 情報 ━━━━
          _sectionHeader('情報'),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('GitHub リポジトリ'),
            subtitle: const Text('github.com/kuboshige/media-relay'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl('https://github.com/kuboshige/media-relay'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('プライバシーポリシー'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl(
                'https://github.com/kuboshige/media-relay/blob/main/PRIVACY.md'),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('ライセンス (MIT)'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl(
                'https://github.com/kuboshige/media-relay/blob/main/LICENSE'),
          ),
          ListTile(
            leading: const Icon(Icons.battery_alert_outlined),
            title: const Text('バックグラウンド動作の改善'),
            subtitle: const Text('Android の省電力設定で強制終了される場合はこちら'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl('https://dontkillmyapp.com/'),
          ),
          const SizedBox(height: 16),
        ],
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
  late final TextEditingController _token =
      TextEditingController(text: widget.entry?.token ?? '');

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? 'サーバー追加' : 'サーバー編集'),
      content: SingleChildScrollView(
        child: Column(
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
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                  labelText: 'トークン（任意）',
                  hintText: 'QRスキャンで自動設定されます',
                  prefixIcon: Icon(Icons.lock_outline, size: 18)),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
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
            final token = _token.text.trim();
            if (host.isEmpty) return;
            Navigator.pop(
              context,
              ServerEntry(
                name: name.isEmpty ? host : name,
                host: host,
                port: port,
                token: token.isEmpty ? null : token,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
