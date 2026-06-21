import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

/// このセッションで受信したファイルのサムネイル一覧。
/// photo_manager で最新 [count] 件を取得して表示する。
class ReceivedFilesPage extends StatefulWidget {
  final int count;
  const ReceivedFilesPage({super.key, required this.count});

  @override
  State<ReceivedFilesPage> createState() => _ReceivedFilesPageState();
}

class _ReceivedFilesPageState extends State<ReceivedFilesPage> {
  List<AssetEntity> _assets = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth && !ps.hasAccess) {
        setState(() {
          _error = 'メディアへのアクセス権限がありません';
          _loading = false;
        });
        return;
      }
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
      );
      if (paths.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      // hasAll: true の最初のパスが「すべてのメディア」アルバム
      final allPath = paths.first;
      final n = widget.count.clamp(1, 500);
      final assets = await allPath.getAssetListRange(start: 0, end: n);
      setState(() {
        _assets = assets;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openAsset(AssetEntity asset) async {
    try {
      await const MethodChannel('com.kuboshige.media_relay/media_store')
          .invokeMethod('openAsset', {
        'id': asset.id,
        'type': asset.type == AssetType.video ? 2 : 1,
      });
    } catch (_) {}
  }

  Widget _thumb(AssetEntity asset) {
    return GestureDetector(
      onTap: () => _openAsset(asset),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(const ThumbnailSize(200, 200)),
            builder: (_, snap) {
              if (snap.hasData && snap.data != null) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              return Container(color: Colors.grey.shade300);
            },
          ),
          if (asset.type == AssetType.video)
            const Positioned(
              right: 4,
              bottom: 4,
              child: Icon(Icons.videocam, color: Colors.white, size: 18),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!, textAlign: TextAlign.center),
      ));
    } else if (_assets.isEmpty) {
      body = const Center(child: Text('表示できるファイルがありません'));
    } else {
      body = GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemCount: _assets.length,
        itemBuilder: (_, i) => _thumb(_assets[i]),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('受信ファイル（${widget.count}件）'),
      ),
      body: body,
    );
  }
}
