import 'package:shared_preferences/shared_preferences.dart';

/// アプリ全体の軽量設定（サーバー以外）。SharedPreferences に保存する。
class AppSettings {
  static const _kReminderDays = 'reminderDays';
  static const _kLastSync = 'lastSyncEpochMs';
  static const _kReceiverPort = 'receiverPort';

  /// 受信モードの待ち受けポート（既定8765）。
  static const int defaultReceiverPort = 8765;

  static Future<int> receiverPort() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kReceiverPort) ?? defaultReceiverPort;
  }

  static Future<void> setReceiverPort(int port) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kReceiverPort, port);
  }

  /// 未送信リマインダーの間隔（日）。0 はオフ。既定3日。
  static const int defaultReminderDays = 3;

  /// 設定UIで選べる候補（0=オフ）。
  static const List<int> reminderChoices = [0, 1, 3, 7, 14];

  static Future<int> reminderDays() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kReminderDays) ?? defaultReminderDays;
  }

  static Future<void> setReminderDays(int days) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kReminderDays, days);
  }

  /// 最後に送信した時刻（ms）。未記録なら null。
  static Future<int?> lastSyncMs() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kLastSync);
  }

  static Future<void> setLastSyncNow() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kLastSync, DateTime.now().millisecondsSinceEpoch);
  }
}
