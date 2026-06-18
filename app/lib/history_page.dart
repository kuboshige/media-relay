import 'package:flutter/material.dart';
import 'sent_store.dart';

/// 送信履歴（ログ）画面。送信 / スキップ / 失敗を新しい順で表示する。
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('履歴を消去'),
        content: const Text('送信履歴をすべて消去します（送信済みの判定には影響しません）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('消去')),
        ],
      ),
    );
    if (ok == true) {
      await SentStore.clearLogs();
      await _load();
    }
  }

  ({IconData icon, Color color, String label}) _style(String status) {
    switch (status) {
      case 'sent':
        return (icon: Icons.check_circle, color: Colors.green, label: '送信');
      case 'skipped':
        return (icon: Icons.skip_next, color: Colors.blueGrey, label: 'スキップ');
      default:
        return (icon: Icons.error, color: Colors.red, label: '失敗');
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
    final sent = _logs.where((l) => l['status'] == 'sent').length;
    final skipped = _logs.where((l) => l['status'] == 'skipped').length;
    final failed = _logs.where((l) => l['status'] == 'failed').length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('送信履歴'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '履歴を消去',
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
                  child: Text(
                      '直近 ${_logs.length} 件 — 送信 $sent / スキップ $skipped / 失敗 $failed'),
                ),
                Expanded(
                  child: _logs.isEmpty
                      ? const Center(child: Text('まだ履歴はありません'))
                      : ListView.separated(
                          itemCount: _logs.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final l = _logs[i];
                            final s = _style(l['status'] as String? ?? '');
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
