import 'dart:io';
import 'package:photo_manager/photo_manager.dart';

/// 端末内のメディア1件を表す
class MediaItem {
  final AssetEntity asset;
  MediaItem(this.asset);

  String get id => asset.id;
  String get title => asset.title ?? asset.id;
  bool get isVideo => asset.type == AssetType.video;
  DateTime get createdAt => asset.createDateTime;
  DateTime get modifiedAt => asset.modifiedDateTime;

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

/// 端末内のアルバム（フォルダ）1件を表す
class Album {
  final AssetPathEntity path;
  final int count;
  Album(this.path, this.count);

  String get id => path.id;
  String get name => path.name;
}

/// メディアの読み出し（権限取得・アルバム/一覧取得）
class MediaSource {
  /// 新しい順（撮影日時の降順）に並べるためのフィルタ
  static FilterOptionGroup get _newestFirst => FilterOptionGroup()
    ..addOrderOption(
        const OrderOption(type: OrderOptionType.createDate, asc: false));

  /// ストレージ/写真への権限を要求する。許可されたら true。
  static Future<bool> requestPermission() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth || ps.hasAccess;
  }

  /// 端末内のアルバム（フォルダ）一覧。空フォルダは除外し、件数の多い順に返す。
  static Future<List<Album>> listAlbums() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // 画像と動画
      hasAll: false, // 結合アルバム（最近の項目）は除外し、実フォルダだけ
      filterOption: _newestFirst,
    );
    final albums = <Album>[];
    for (final pth in paths) {
      final c = await pth.assetCountAsync;
      if (c == 0) continue;
      albums.add(Album(pth, c));
    }
    albums.sort((a, b) => b.count.compareTo(a.count));
    return albums;
  }

  /// アルバムの代表サムネ用に先頭（=最新）の1件を返す。
  static Future<AssetEntity?> firstAsset(AssetPathEntity path) async {
    final list = await path.getAssetListRange(start: 0, end: 1);
    return list.isEmpty ? null : list.first;
  }

  /// 選択アルバムからメディアを集約し、新しい順で返す。
  /// [albumIds] が null のときは全アルバムを対象にする。
  static Future<List<MediaItem>> listFromAlbums(
    Set<String>? albumIds, {
    int perAlbum = 500,
  }) async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: false,
      filterOption: _newestFirst,
    );
    // 複数アルバムにまたがる重複をIDで畳み込む
    final byId = <String, AssetEntity>{};
    for (final pth in paths) {
      if (albumIds != null && !albumIds.contains(pth.id)) continue;
      final c = await pth.assetCountAsync;
      if (c == 0) continue;
      final assets = await pth.getAssetListRange(
          start: 0, end: c < perAlbum ? c : perAlbum);
      for (final a in assets) {
        byId[a.id] = a;
      }
    }
    final items = byId.values.map((a) => MediaItem(a)).toList();
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }
}
