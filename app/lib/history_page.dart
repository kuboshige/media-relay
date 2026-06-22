import 'package:flutter/material.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
import 'sent_store.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _loading = true;
  List<Map<String, Object?>> _logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs = await SentStore.recentLogs();
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.clearHistoryTitle),
        content: Text(l10n.clearHistoryContent),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.btnCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.btnClearHistory)),
        ],
      ),
    );
    if (ok == true) {
      await SentStore.clearLogs();
      await _load();
    }
  }

  ({IconData icon, Color color, String label}) _style(
      String status, AppLocalizations l10n) {
    switch (status) {
      case 'sent':
        return (icon: Icons.check_circle, color: Colors.green, label: l10n.historySent);
      case 'skipped':
        return (icon: Icons.skip_next, color: Colors.blueGrey, label: l10n.historySkipped);
      default:
        return (icon: Icons.error, color: Colors.red, label: l10n.historyFailed);
    }
  }

  String _time(int? ms) {
    if (ms == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sent = _logs.where((l) => l['status'] == 'sent').length;
    final skipped = _logs.where((l) => l['status'] == 'skipped').length;
    final failed = _logs.where((l) => l['status'] == 'failed').length;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pageHistory),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: l10n.clearHistoryTitle,
            onPressed: _clear,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.teal.withValues(alpha: 0.08),
                  padding: const EdgeInsets.all(10),
                  child: Text(l10n.historyStats(
                      _logs.length, sent, skipped, failed)),
                ),
                Expanded(
                  child: _logs.isEmpty
                      ? Center(child: Text(l10n.historyEmpty))
                      : ListView.separated(
                          itemCount: _logs.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final l = _logs[i];
                            final s = _style(
                                l['status'] as String? ?? '', l10n);
                            final detail = l['detail'] as String?;
                            return ListTile(
                              dense: true,
                              leading: Icon(s.icon, color: s.color),
                              title: Text(
                                (l['title'] as String?) ??
                                    (l['relative_path'] as String? ?? ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${s.label} · ${_time(l['at'] as int?)}'
                                '${detail != null && detail.isNotEmpty ? '\n$detail' : ''}',
                              ),
                              isThreeLine:
                                  detail != null && detail.isNotEmpty,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
