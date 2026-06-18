import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// 送信履歴のローカルDB（Step 3：重複送信防止）。
///
/// 日常運用での「未送信だけ表示」は端末内で安定している asset_id を使って
/// 高速に判定する。SHA256 はサーバー側の重複判定（GET /exists）と
/// 機種変更時の照合のために保存しておく。
class SentStore {
  static Database? _db;

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'media_relay.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sent_files(
            asset_id      TEXT PRIMARY KEY,
            sha256        TEXT,
            file_size     INTEGER,
            modified_time INTEGER,
            relative_path TEXT,
            sent_at       INTEGER,
            status        TEXT
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_sent_sha256 ON sent_files(sha256)');
      },
    );
    // 送信ログ（毎回の結果を残す）。マイグレーション不要にするため都度作成。
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS transfer_log(
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        asset_id      TEXT,
        title         TEXT,
        relative_path TEXT,
        status        TEXT,
        detail        TEXT,
        size          INTEGER,
        at            INTEGER
      )
    ''');
    return _db!;
  }

  /// 送信結果を1件ログに残す（status: sent / skipped / failed）。
  static Future<void> log({
    required String assetId,
    required String title,
    required String relativePath,
    required String status,
    String? detail,
    int? size,
  }) async {
    final db = await _open();
    await db.insert('transfer_log', {
      'asset_id': assetId,
      'title': title,
      'relative_path': relativePath,
      'status': status,
      'detail': detail,
      'size': size,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 直近の送信ログ（新しい順）。
  static Future<List<Map<String, Object?>>> recentLogs({int limit = 500}) async {
    final db = await _open();
    return db.query('transfer_log', orderBy: 'at DESC', limit: limit);
  }

  /// 送信ログを全消去する。
  static Future<void> clearLogs() async {
    final db = await _open();
    await db.delete('transfer_log');
  }

  /// 送信済み（status = sent）の asset_id 集合。
  static Future<Set<String>> sentAssetIds() async {
    final db = await _open();
    final rows = await db.query(
      'sent_files',
      columns: ['asset_id'],
      where: 'status = ?',
      whereArgs: ['sent'],
    );
    return rows.map((r) => r['asset_id'] as String).toSet();
  }

  /// 同一内容（SHA256）が既に送信済みか。
  static Future<bool> sha256AlreadySent(String sha256) async {
    final db = await _open();
    final rows = await db.query(
      'sent_files',
      where: 'sha256 = ? AND status = ?',
      whereArgs: [sha256, 'sent'],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> markSent({
    required String assetId,
    String? sha256,
    int? fileSize,
    int? modifiedTime,
    required String relativePath,
  }) async {
    final db = await _open();
    await db.insert(
      'sent_files',
      {
        'asset_id': assetId,
        'sha256': sha256,
        'file_size': fileSize,
        'modified_time': modifiedTime,
        'relative_path': relativePath,
        'sent_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'sent',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
