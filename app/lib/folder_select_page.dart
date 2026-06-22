import 'package:flutter/material.dart';
import 'package:media_relay/gen_l10n/app_localizations.dart';
import 'package:photo_manager/photo_manager.dart';
import 'media_source.dart';
import 'folder_config.dart';

/// 送信対象フォルダ（アルバム）の選択画面。
/// アルバムごとにサムネ・件数を表示し、ON/OFFで対象を選ぶ。
class FolderSelectPage extends StatefulWidget {
  const FolderSelectPage({super.key});

  @override
  State<FolderSelectPage> createState() => _FolderSelectPageState();
}

class _FolderSelectPageState extends State<FolderSelectPage> {
  bool _loading = true;
  List<Album> _albums = [];
  Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final albums = await MediaSource.listAlbums();
    final saved = await FolderConfig.loadSelected();
    setState(() {
      _albums = albums;
      // 未設定なら全フォルダを既定でON
      _selected = saved ?? albums.map((a) => a.id).toSet();
      _loading = false;
    });
  }

  Future<void> _save() async {
    await FolderConfig.save(_selected);
    if (mounted) Navigator.pop(context, true);
  }

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.folderTooltip),
        actions: [
          TextButton(
            onPressed: () =>
                setState(() => _selected = _albums.map((a) => a.id).toSet()),
            child: Text(l10n.btnSelectAll,
                style: const TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => setState(() => _selected = {}),
            child: Text(l10n.btnDeselectAll,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _albums.isEmpty
              ? Center(child: Text(l10n.folderNotFound))
              : ListView.builder(
                  itemCount: _albums.length,
                  itemBuilder: (context, i) {
                    final a = _albums[i];
                    return ListTile(
                      leading: _AlbumThumb(a.path),
                      title: Text(a.name),
                      subtitle: Text(l10n.folderItemCountHint(a.count)),
                      // フォルダ名/サムネのタップは「中身プレビュー」を開く。
                      // 送信対象のON/OFFは右のスイッチだけで切り替える。
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => FolderPreviewPage(album: a)),
                      ),
                      trailing: Switch(
                        value: _selected.contains(a.id),
                        onChanged: (v) => _toggle(a.id, v),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _save,
        icon: const Icon(Icons.check),
        label: Text(l10n.btnSave),
      ),
    );
  }
}

/// フォルダの中身プレビュー（サムネのグリッド）。送信するか判断するための閲覧用。
class FolderPreviewPage extends StatefulWidget {
  final Album album;
  const FolderPreviewPage({super.key, required this.album});

  @override
  State<FolderPreviewPage> createState() => _FolderPreviewPageState();
}

class _FolderPreviewPageState extends State<FolderPreviewPage> {
  List<AssetEntity> _assets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // プレビューは最大200件まで（判断には十分）。
    final list =
        await widget.album.path.getAssetListPaged(page: 0, size: 200);
    if (!mounted) return;
    setState(() {
      _assets = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.album.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(l10n.folderPreviewHint(widget.album.count),
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _assets.isEmpty
              ? Center(child: Text(l10n.folderNoMedia))
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: _assets.length,
                  itemBuilder: (context, i) {
                    final asset = _assets[i];
                    return FutureBuilder(
                      future: asset.thumbnailDataWithSize(
                          const ThumbnailSize(200, 200)),
                      builder: (context, snap) {
                        if (snap.hasData && snap.data != null) {
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(snap.data!, fit: BoxFit.cover),
                              if (asset.type == AssetType.video)
                                const Positioned(
                                  right: 4,
                                  bottom: 4,
                                  child: Icon(Icons.videocam,
                                      color: Colors.white, size: 18),
                                ),
                            ],
                          );
                        }
                        return Container(color: Colors.grey.shade300);
                      },
                    );
                  },
                ),
    );
  }
}

class _AlbumThumb extends StatelessWidget {
  final AssetPathEntity path;
  const _AlbumThumb(this.path);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: FutureBuilder<AssetEntity?>(
        future: MediaSource.firstAsset(path),
        builder: (context, snap) {
          final asset = snap.data;
          if (asset == null) {
            return Container(color: Colors.grey.shade300);
          }
          return FutureBuilder(
            future:
                asset.thumbnailDataWithSize(const ThumbnailSize(100, 100)),
            builder: (context, t) {
              if (t.hasData && t.data != null) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(t.data!,
                      fit: BoxFit.cover, width: 48, height: 48),
                );
              }
              return Container(color: Colors.grey.shade300);
            },
          );
        },
      ),
    );
  }
}
