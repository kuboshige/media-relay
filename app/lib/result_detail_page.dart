import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'media_source.dart';

enum FileOpStatus { sent, skipped, failed, deleted, unconfirmed }

class FileOp {
  final MediaItem item;
  final FileOpStatus status;
  final String? reason;
  const FileOp(this.item, this.status, [this.reason]);

  bool get needsAttention =>
      status == FileOpStatus.failed || status == FileOpStatus.unconfirmed;

  String get statusLabel {
    switch (status) {
      case FileOpStatus.sent:
        return '送信完了';
      case FileOpStatus.skipped:
        return 'スキップ（重複）';
      case FileOpStatus.failed:
        return '失敗';
      case FileOpStatus.deleted:
        return '削除完了';
      case FileOpStatus.unconfirmed:
        return '未確認スキップ';
    }
  }

  Color statusColor() {
    switch (status) {
      case FileOpStatus.sent:
        return Colors.green;
      case FileOpStatus.skipped:
        return Colors.blue;
      case FileOpStatus.failed:
        return Colors.red;
      case FileOpStatus.deleted:
        return Colors.teal;
      case FileOpStatus.unconfirmed:
        return Colors.orange;
    }
  }
}

/// ResultDetailPage から返る操作指示。
class DetailPageResult {
  final List<MediaItem> toSend;
  final List<MediaItem> toDelete;
  /// true のとき、受領確認をスキップして強制削除する（確認ダイアログは呼び出し元で表示済み）。
  final bool forcedDelete;
  const DetailPageResult({
    this.toSend = const [],
    this.toDelete = const [],
    this.forcedDelete = false,
  });
}

/// 送信・削除の操作結果をファイルごとに表示するページ。
/// サムネタップで選択 → アクションバーから再送信 or 削除 を実行できる。
class ResultDetailPage extends StatefulWidget {
  final List<FileOp> ops;
  final String serverName;
  const ResultDetailPage({
    super.key,
    required this.ops,
    required this.serverName,
  });

  @override
  State<ResultDetailPage> createState() => _ResultDetailPageState();
}

class _ResultDetailPageState extends State<ResultDetailPage> {
  final Set<String> _selected = {};
  bool _errorsOnly = true;

  List<FileOp> get _visible {
    if (!_errorsOnly) return widget.ops;
    final errors = widget.ops.where((o) => o.needsAttention).toList();
    return errors.isEmpty ? widget.ops : errors;
  }

  List<MediaItem> get _selectedItems => _visible
      .where((o) => _selected.contains(o.item.id))
      .map((o) => o.item)
      .toList();

  void _toggle(String id) => setState(() {
        if (_selected.contains(id)) {
          _selected.remove(id);
        } else {
          _selected.add(id);
        }
      });

  Future<void> _onDeleteTapped() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('バックアップなしで削除'),
        content: Text(
          '${items.length} 件は受信側での受領が確認できていません。\n\n'
          'このまま削除すると、ファイルはバックアップされずにこの端末から永久に消えます。\n\n'
          'よろしいですか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('それでも削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.pop(
        context, DetailPageResult(toDelete: items, forcedDelete: true));
  }

  @override
  Widget build(BuildContext context) {
    final errorCount = widget.ops.where((o) => o.needsAttention).length;
    return Scaffold(
      appBar: AppBar(
        title: Text('操作結果（${widget.ops.length} 件）'),
        actions: [
          if (errorCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(_errorsOnly ? 'エラー $errorCount 件' : 'すべて'),
                selected: _errorsOnly,
                onSelected: (v) => setState(() {
                  _errorsOnly = v;
                  _selected.clear();
                }),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_selected.isNotEmpty)
            _ActionBar(
              count: _selected.length,
              serverName: widget.serverName,
              onSend: () => Navigator.pop(
                context,
                DetailPageResult(toSend: _selectedItems),
              ),
              onDelete: () { _onDeleteTapped(); },
              onClear: () => setState(() => _selected.clear()),
            ),
          Expanded(
            child: _visible.isEmpty
                ? const Center(child: Text('表示する項目がありません'))
                : ListView.builder(
                    itemCount: _visible.length,
                    itemBuilder: (_, i) {
                      final op = _visible[i];
                      return _FileOpTile(
                        op: op,
                        selected: _selected.contains(op.item.id),
                        onToggle: () => _toggle(op.item.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final int count;
  final String serverName;
  final VoidCallback onSend;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  const _ActionBar({
    required this.count,
    required this.serverName,
    required this.onSend,
    required this.onDelete,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Text('$count 件選択中',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          TextButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.upload, size: 16),
            label: const Text('送信', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          ),
          TextButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
            label: const Text('削除',
                style: TextStyle(color: Colors.red, fontSize: 13)),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            tooltip: '選択解除',
          ),
        ],
      ),
    );
  }
}

class _FileOpTile extends StatelessWidget {
  final FileOp op;
  final bool selected;
  final VoidCallback onToggle;

  const _FileOpTile({
    required this.op,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final color = op.statusColor();
    return InkWell(
      onTap: onToggle,
      child: Container(
        color: selected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // サムネイル（選択時はオーバーレイ）
            SizedBox(
              width: 60,
              height: 60,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List?>(
                    future: op.item.asset
                        .thumbnailDataWithSize(const ThumbnailSize(120, 120)),
                    builder: (_, snap) {
                      if (snap.hasData && snap.data != null) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.memory(snap.data!, fit: BoxFit.cover),
                        );
                      }
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                            op.item.isVideo ? Icons.videocam : Icons.image,
                            color: Colors.grey),
                      );
                    },
                  ),
                  if (selected)
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child:
                          const Icon(Icons.check, color: Colors.white, size: 28),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // ファイル情報
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    op.item.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // ステータスチップ
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      op.statusLabel,
                      style: TextStyle(
                          fontSize: 11,
                          color: color,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (op.reason != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      op.reason!,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
