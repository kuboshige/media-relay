import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 1台のPixelサーバーの設定（手入力。家・職場など複数登録できる）
class ServerEntry {
  final String name; // 表示名（例: 家のPixel）
  final String host; // IPアドレスまたはホスト名
  final int port;

  ServerEntry({required this.name, required this.host, this.port = 8765});

  String get baseUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => {'name': name, 'host': host, 'port': port};

  factory ServerEntry.fromJson(Map<String, dynamic> j) => ServerEntry(
        name: j['name'] as String,
        host: j['host'] as String,
        port: (j['port'] as num?)?.toInt() ?? 8765,
      );
}

/// サーバー一覧と「現在選択中のサーバー」をSharedPreferencesに保存する
class ServerConfig {
  static const _kServers = 'servers';
  static const _kSelected = 'selected_server_index';

  static Future<List<ServerEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kServers);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => ServerEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<ServerEntry> servers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kServers, jsonEncode(servers.map((e) => e.toJson()).toList()));
  }

  static Future<int> selectedIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kSelected) ?? 0;
  }

  static Future<void> setSelectedIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSelected, index);
  }
}
