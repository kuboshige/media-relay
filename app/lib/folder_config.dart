import 'package:shared_preferences/shared_preferences.dart';

/// 送信対象フォルダ（アルバム）の選択を保存する。
///
/// 未設定（初回起動）のときは null を返し、呼び出し側で「全フォルダ選択」を
/// 既定とする。
class FolderConfig {
  static const _kSelected = 'selected_album_ids';
  static const _kConfigured = 'folders_configured';

  /// 選択中のアルバムID集合。未設定なら null。
  static Future<Set<String>?> loadSelected() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kConfigured) ?? false)) return null;
    return (prefs.getStringList(_kSelected) ?? const <String>[]).toSet();
  }

  static Future<void> save(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSelected, ids.toList());
    await prefs.setBool(_kConfigured, true);
  }
}
