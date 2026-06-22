import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
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

  String statusLabel(AppLocalizations l10n) {
    switch (status) {
      case FileOpStatus.sent:
        return l10n.statusSent;
      case FileOpStatus.skipped:
        return l10n.statusSkipped;
      case FileOpStatus.failed:
        return l10n.statusFailed;
      case FileOpStatus.deleted:
        return l10n.statusDeleted;
      case FileOpStatus.unconfirmed:
        return l10n.statusUnconfirmed;
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

class DetailPageResult {
  final List<MediaItem> toSend;
  final List<MediaItem> toDelete;
  final bool forcedDelete;
  const DetailPageResult({
    this.toSend = const [],
    this.toDelete = const [],
    this.forcedDelete = false,
  });
}

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
    final l10n = AppLocalizations.of(context)!;
    final items = _selectedItems;
    if (items.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.deleteWithoutBackupTitle),
        content: Text(l10n.deleteWithoutBackupContent(items.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.btnCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.btnDeleteAnyway),
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
    final l10n = AppLocalizations.of(context)!;
    final errorCount = widget.ops.where((o) => o.needsAttention).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.resultDetailTitle(widget.ops.length)),
        actions: [
          if (errorCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(_errorsOnly
                    ? '${l10n.statusFailed} $errorCount'
                    : l10n.btnClose),
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
              l10n: l10n,
              onSend: () => Navigator.pop(
                context,
                DetailPageResult(toSend: _selectedItems),
              ),
              onDelete: () { _onDeleteTapped(); },
              onClear: () => setState(() => _selected.clear()),
            ),
          Expanded(
            child: _visible.isEmpty
                ? Center(child: Text(l10n.resultDetailEmpty))
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
  final AppLocalizations l10n;
  final VoidCallback onSend;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  const _ActionBar({
    required this.count,
    required this.serverName,
    required this.l10n,
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
          Text(l10n.actionBarSelected(count),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          TextButton.icon(
            onPressed: onSend,
            icon: const Icon(Icons.upload, size: 16),
            label: Text(l10n.btnSend, style: const TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          ),
          TextButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
            label: Text(l10n.btnDelete,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
            style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
            tooltip: l10n.deselectTooltip,
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
    final l10n = AppLocalizations.of(context)!;
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
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      op.statusLabel(l10n),
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
