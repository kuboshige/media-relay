import 'package:flutter/material.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('送信対象フォルダ'),
        actions: [
          TextButton(
            onPressed: () =>
                setState(() => _selected = _albums.map((a) => a.id).toSet()),
            child: const Text('全選択', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => setState(() => _selected = {}),
            child: const Text('全解除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _albums.isEmpty
              ? const Center(child: Text('フォルダが見つかりません'))
              : ListView.builder(
                  itemCount: _albums.length,
                  itemBuilder: (context, i) {
                    final a = _albums[i];
                    return SwitchListTile(
                      value: _selected.contains(a.id),
                      onChanged: (v) => _toggle(a.id, v),
                      secondary: _AlbumThumb(a.path),
                      title: Text(a.name),
                      subtitle: Text('${a.count} 件'),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _save,
        icon: const Icon(Icons.check),
        label: const Text('保存'),
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
                asset.thumbnailDataWithSize(const ThumbnailSize.square(100)),
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
