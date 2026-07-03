import 'package:flutter/material.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_settings.dart';
import 'background_send.dart';
import 'notif_service.dart';
import 'qr_scan_page.dart';
import 'server_config.dart';
import 'uploader.dart';
import 'wifi_monitor.dart';

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
  String _deviceName = '';
  int _receiverPort = AppSettings.defaultReceiverPort;
  int _autoStopMinutes = AppSettings.defaultAutoStopMinutes;
  bool _notifyOnSuccess = true;
  bool _notifyOnFailure = true;
  bool _reminderSendNow = true;
  bool _wifiAutoSendEnabled = false;
  int _bgIntervalMinutes = AppSettings.defaultBgIntervalMinutes;
  String _wifiAutoSendSsid = '';
  String? _currentSsid;
  final TextEditingController _ssidCtrl = TextEditingController();

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
    _notifyOnSuccess = await AppSettings.notifyOnSuccess();
    _notifyOnFailure = await AppSettings.notifyOnFailure();
    _reminderSendNow = await AppSettings.reminderSendNow();
    _wifiAutoSendEnabled = await AppSettings.wifiAutoSendEnabled();
    _bgIntervalMinutes = await AppSettings.bgIntervalMinutes();
    _wifiAutoSendSsid = (await AppSettings.wifiAutoSendSsid()) ?? '';
    _ssidCtrl.text = _wifiAutoSendSsid;
    _currentSsid = await WifiMonitor.getCurrentSsid();
    setState(() {});
  }

  @override
  void dispose() {
    _ssidCtrl.dispose();
    super.dispose();
  }

  String _startupActionLabel(String v, AppLocalizations l10n) {
    switch (v) {
      case AppSettings.startupActionSend:
        return l10n.startupActionSend;
      case AppSettings.startupActionSendAndDelete:
        return l10n.startupActionSendAndDelete;
      default:
        return l10n.startupActionNone;
    }
  }

  Widget _startupActionTile(AppLocalizations l10n) {
    return ListTile(
      leading: const Icon(Icons.play_circle_outline),
      title: Text(l10n.startupActionLabel),
      subtitle: Text(_startupActionLabel(_startupAction, l10n)),
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
              child: Text(_startupActionLabel(AppSettings.startupActionNone, l10n))),
          DropdownMenuItem(
              value: AppSettings.startupActionSend,
              child: Text(_startupActionLabel(AppSettings.startupActionSend, l10n))),
          DropdownMenuItem(
              value: AppSettings.startupActionSendAndDelete,
              child: Text(_startupActionLabel(AppSettings.startupActionSendAndDelete, l10n))),
        ],
      ),
    );
  }

  Future<void> _setReminderDays(int v, AppLocalizations l10n) async {
    setState(() => _reminderDays = v);
    await AppSettings.setReminderDays(v);
    if (v > 0) await NotifService.requestPermission();
    await NotifService.reschedule();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(v <= 0 ? l10n.reminderDisabled : l10n.reminderEnabled(v))));
  }

  String _reminderLabel(int d, AppLocalizations l10n) =>
      d <= 0 ? l10n.reminderOff : l10n.reminderDays(d);

  Widget _reminderTile(AppLocalizations l10n) {
    return ListTile(
      leading: const Icon(Icons.notifications_active),
      title: Text(l10n.reminderTileTitle),
      subtitle: Text(_reminderDays <= 0
          ? l10n.reminderOff
          : l10n.reminderActive(_reminderDays)),
      trailing: DropdownButton<int>(
        value: _reminderDays,
        onChanged: (v) {
          if (v != null) _setReminderDays(v, l10n);
        },
        items: [
          for (final d in AppSettings.reminderChoices)
            DropdownMenuItem(value: d, child: Text(_reminderLabel(d, l10n))),
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
      setState(() => _deviceName = name);
    }
  }

  Future<void> _editReceiverPort(AppLocalizations l10n) async {
    final ctrl = TextEditingController(text: '$_receiverPort');
    final portStr = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.receiverPortDialogTitle),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '8765'),
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

  String _bgIntervalLabel(int minutes, AppLocalizations l10n) =>
      minutes < 60 ? l10n.intervalMinutes(minutes) : l10n.intervalHours(minutes ~/ 60);

  String _wifiAutoSendStatusText(AppLocalizations l10n) {
    if (!_wifiAutoSendEnabled) return '';
    if (_wifiAutoSendSsid.isEmpty) return l10n.wifiAutoSendStatusAny;
    if (_currentSsid == null) return l10n.wifiAutoSendStatusSsidUnknown;
    return l10n.wifiAutoSendStatusSsid(_wifiAutoSendSsid);
  }

  /// Wi-Fi 自動送信をオンにしたとき、受信側（Pixel）の準備が必要なことを案内する。
  /// これをしないと受信サーバーが途中で止まり、送っても届かない。
  Future<void> _showReceiverSetupWarning(AppLocalizations l10n) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.wifiAutoSendReceiverWarnTitle),
        content: SingleChildScrollView(
          child: Text(l10n.wifiAutoSendReceiverWarnBody),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.btnClose),
          ),
        ],
      ),
    );
  }

  /// 位置情報の許可を求める前に、なぜ必要かを説明する。
  /// 許可して進んでよいなら true を返す。
  Future<bool> _confirmLocationRationale(AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.wifiAutoSendLocationRationaleTitle),
        content: SingleChildScrollView(
          child: Text(l10n.wifiAutoSendLocationRationaleBody),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.btnCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.btnContinue),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Widget _wifiSsidTile(AppLocalizations l10n) {
    final subtleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.wifiAutoSendSsidLabel,
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          TextField(
            controller: _ssidCtrl,
            decoration: InputDecoration(
              hintText: l10n.wifiAutoSendSsidHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            // 入力の都度保存する（確定キーを押さずに戻っても消えないように）。
            onChanged: (v) async {
              await AppSettings.setWifiAutoSendSsid(v.trim());
              setState(() => _wifiAutoSendSsid = v.trim());
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.wifi_find, size: 16),
                label: Text(l10n.wifiAutoSendUseCurrent),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () async {
                  var status = await Permission.locationWhenInUse.status;
                  if (!status.isGranted) {
                    // OSの権限ダイアログの前に、なぜ位置情報が要るのか説明する。
                    if (!await _confirmLocationRationale(l10n)) return;
                    status = await Permission.locationWhenInUse.request();
                  }
                  if (!status.isGranted) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.wifiAutoSendCurrentSsidNone)),
                    );
                    return;
                  }
                  final ssid = await WifiMonitor.getCurrentSsid();
                  if (ssid == null) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l10n.wifiAutoSendCurrentSsidNone)),
                    );
                    return;
                  }
                  await AppSettings.setWifiAutoSendSsid(ssid);
                  _ssidCtrl.text = ssid;
                  if (!mounted) return;
                  setState(() {
                    _currentSsid = ssid;
                    _wifiAutoSendSsid = ssid;
                  });
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _currentSsid != null
                      ? l10n.wifiAutoSendCurrentSsid(_currentSsid!)
                      : l10n.wifiAutoSendCurrentSsidNone,
                  style: subtleStyle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Expanded(
                child: Text(l10n.wifiAutoSendHowToFind, style: subtleStyle),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _persist() async {
    await ServerConfig.save(_servers);
    await ServerConfig.setSelectedIndex(_selected);
  }

  Future<void> _edit({int? index}) async {
    final l10n = AppLocalizations.of(context)!;
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
    if (!mounted) return;
    if (index == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.serverAdded(result.name, '${result.host}:${result.port}'))));
    }
  }

  Future<void> _addFromQr() async {
    final l10n = AppLocalizations.of(context)!;
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
        content: Text(l10n.serverAdded(entry.name, '${entry.host}:${entry.port}'))));
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
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.connectTestPending)));
    final status = await Uploader(s).pingStatus();
    if (!mounted) return;
    final msg = status == 200
        ? l10n.connectTestOk(s.name)
        : status == 401
            ? l10n.connectTestAuth('${s.host}:${s.port}')
            : l10n.connectTestFail('${s.host}:${s.port}');
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _launchUrl(String url, AppLocalizations l10n) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.urlOpenError(url))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tabSettings)),
      body: ListView(
        children: [
          // ━━━━ Destination server ━━━━
          _sectionHeader(l10n.settingsSectionServer, actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: l10n.addServerQr,
              onPressed: _addFromQr,
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: l10n.addServerManual,
              onPressed: () => _edit(),
            ),
          ]),
          if (_servers.isEmpty) ...[
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(l10n.serverNotRegistered),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: Text(l10n.addServerQr),
                    onPressed: _addFromQr,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l10n.addServerManual),
                    onPressed: () => _edit(),
                  ),
                ],
              ),
            ),
          ]
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
                      tooltip: l10n.connectTestPending,
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

          // ━━━━ On app launch ━━━━
          _sectionHeader(l10n.settingsSectionStartup),
          _startupActionTile(l10n),
          const Divider(height: 1),

          // ━━━━ Receiver settings ━━━━
          _sectionHeader(l10n.settingsSectionReceiver),
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: Text(l10n.deviceNameLabel),
            subtitle: Text(_deviceName.isEmpty ? l10n.deviceNameNotSet : _deviceName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editDeviceName(l10n),
          ),
          ListTile(
            leading: const Icon(Icons.settings_ethernet),
            title: Text(l10n.receiverPortLabel),
            subtitle: Text('$_receiverPort'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editReceiverPort(l10n),
          ),
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: Text(l10n.autoStopLabel),
            subtitle: Text(_autoStopMinutes == 0
                ? l10n.autoStopOff
                : l10n.autoStopActive(_autoStopMinutes)),
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
                    child: Text(m == 0 ? l10n.autoStopOff : l10n.autoStopMinutes(m)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),

          // ━━━━ Notifications ━━━━
          _sectionHeader(l10n.settingsSectionNotifications),
          _reminderTile(l10n),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(l10n.reminderActionLabel),
            subtitle: Text(l10n.reminderActionSubtitle),
            value: _reminderSendNow,
            onChanged: (v) async {
              await AppSettings.setReminderSendNow(v);
              setState(() => _reminderSendNow = v);
              await NotifService.reschedule();
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.check_circle_outline),
            title: Text(l10n.notifyOnSuccessLabel),
            subtitle: Text(l10n.notifyOnSuccessSubtitle),
            value: _notifyOnSuccess,
            onChanged: (v) async {
              await AppSettings.setNotifyOnSuccess(v);
              setState(() => _notifyOnSuccess = v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.error_outline),
            title: Text(l10n.notifyOnFailureLabel),
            subtitle: Text(l10n.notifyOnFailureSubtitle),
            value: _notifyOnFailure,
            onChanged: (v) async {
              await AppSettings.setNotifyOnFailure(v);
              setState(() => _notifyOnFailure = v);
            },
          ),
          const Divider(height: 1),

          // ━━━━ Auto-send ━━━━
          _sectionHeader(l10n.settingsSectionAutoSend),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: Text(l10n.wifiAutoSendLabel),
            subtitle: Text(_wifiAutoSendStatusText(l10n)),
            value: _wifiAutoSendEnabled,
            onChanged: (v) async {
              await AppSettings.setWifiAutoSendEnabled(v);
              if (v) _currentSsid = await WifiMonitor.getCurrentSsid();
              setState(() => _wifiAutoSendEnabled = v);
              try { await scheduleBgSendIfEnabled(forceReschedule: true); } catch (_) {}
              // オンにした直後、受信側の準備が必要なことを案内する。
              if (v && mounted) await _showReceiverSetupWarning(l10n);
            },
          ),
          if (_wifiAutoSendEnabled) ...[
            _wifiSsidTile(l10n),
            ListTile(
              leading: const Icon(Icons.timelapse),
              title: Text(l10n.bgIntervalLabel),
              subtitle: Text(l10n.bgIntervalSubtitle),
              trailing: DropdownButton<int>(
                value: _bgIntervalMinutes,
                onChanged: (v) async {
                  if (v == null) return;
                  await AppSettings.setBgIntervalMinutes(v);
                  setState(() => _bgIntervalMinutes = v);
                  try {
                    await scheduleBgSendIfEnabled(forceReschedule: true);
                  } catch (_) {}
                },
                items: [
                  for (final m in AppSettings.bgIntervalChoices)
                    DropdownMenuItem(
                        value: m, child: Text(_bgIntervalLabel(m, l10n))),
                ],
              ),
            ),
          ],
          const Divider(height: 1),

          // ━━━━ About ━━━━
          _sectionHeader(l10n.settingsSectionInfo),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(l10n.infoGithub),
            subtitle: const Text('github.com/kuboshige/media-relay'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl('https://github.com/kuboshige/media-relay', l10n),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.infoPrivacyPolicy),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl(
                'https://github.com/kuboshige/media-relay/blob/main/PRIVACY.md', l10n),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(l10n.infoLicense),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl(
                'https://github.com/kuboshige/media-relay/blob/main/LICENSE', l10n),
          ),
          ListTile(
            leading: const Icon(Icons.battery_alert_outlined),
            title: Text(l10n.infoDontKillMyApp),
            subtitle: Text(l10n.infoDontKillMyAppSubtitle),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _launchUrl('https://dontkillmyapp.com/', l10n),
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
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(widget.entry == null
          ? l10n.serverDialogAddTitle
          : l10n.serverDialogEditTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                  labelText: l10n.serverNameLabel,
                  hintText: l10n.serverNameHint),
            ),
            TextField(
              controller: _host,
              decoration: InputDecoration(
                  labelText: l10n.serverHostLabel,
                  hintText: l10n.serverHostHint),
              keyboardType: TextInputType.url,
            ),
            TextField(
              controller: _port,
              decoration: InputDecoration(labelText: l10n.serverPortLabel),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: _token,
              decoration: InputDecoration(
                  labelText: l10n.serverTokenLabel,
                  hintText: l10n.serverTokenHint,
                  prefixIcon: const Icon(Icons.lock_outline, size: 18)),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.btnCancel),
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
          child: Text(l10n.btnSave),
        ),
      ],
    );
  }
}
