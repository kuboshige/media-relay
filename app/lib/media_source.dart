import 'dart:io';
import 'package:photo_manager/photo_manager.dart';

/// 端末内のメディア1件を表す
class MediaItem {
  final AssetEntity asset;
  MediaItem(this.asset);

  String get id => asset.id;
  String get title => asset.title ?? asset.id;
  bool get isVideo => asset.type == AssetType.video;

  /// Pixel側で再現する相対パス（例: DCIM/Camera/IMG_0001.jpg）
  /// photo_manager の relativePath はバケットの相対パス（DCIM/Camera/ 等）
  String get relativePath {
    final dir = (asset.relativePath ?? '').replaceAll(RegExp(r'/+$'), '');
    final name = title;
    if (dir.isEmpty) return name;
    return '$dir/$name';
  }

  Future<File?> originFile() => asset.originFile;
}

/// メディアの読み出し（権限取得・一覧取得）
class MediaSource {
  /// ストレージ/写真への権限を要求する。許可されたら true。
  static Future<bool> requestPermission() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth || ps.hasAccess;
  }

  /// 画像・動画を新しい順で取得する。
  /// Step 2 では全件を対象とする（フォルダ選択UIは Step 7）。
  static Future<List<MediaItem>> listAll({int size = 200}) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // 画像と動画
      onlyAll: true,
    );
    if (paths.isEmpty) return [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    final assets =
        await all.getAssetListRange(start: 0, end: count < size ? count : size);
    return assets.map((a) => MediaItem(a)).toList();
  }
}
