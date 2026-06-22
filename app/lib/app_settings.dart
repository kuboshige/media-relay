import 'package:shared_preferences/shared_preferences.dart';

/// アプリ全体の軽量設定（サーバー以外）。SharedPreferences に保存する。
class AppSettings {
  static const _kReminderDays = 'reminderDays';
  static const _kLastSync = 'lastSyncEpochMs';
  static const _kReceiverPort = 'receiverPort';
  static const _kDeviceName = 'deviceName';
  static const _kReceiverAutoStopMinutes = 'receiverAutoStopMinutes';
  static const _kStartupAction = 'startupAction';
  static const _kReceiverToken = 'receiverToken';

  static const String startupActionNone = 'none';
  static const String startupActionSend = 'send';
  static const String startupActionSendAndDelete = 'sendAndDelete';

  /// この端末の表示名（受信モードのQRに載り、送信側に登録される名前）。
  static Future<String> deviceName() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kDeviceName) ?? 'メディアリレー受信機';
  }

  static Future<void> setDeviceName(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDeviceName, name);
  }

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

  /// 受信モードの自動停止時間（分）。0 は停止しない。既定30分。
  static const int defaultAutoStopMinutes = 30;
  static const List<int> autoStopChoices = [0, 15, 30, 60, 120];

  static Future<int> receiverAutoStopMinutes() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kReceiverAutoStopMinutes) ?? defaultAutoStopMinutes;
  }

  static Future<void> setReceiverAutoStopMinutes(int minutes) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kReceiverAutoStopMinutes, minutes);
  }

  /// 起動時の自動動作。
  static Future<String> startupAction() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kStartupAction) ?? startupActionNone;
  }

  static Future<void> setStartupAction(String action) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStartupAction, action);
  }

  /// 受信サーバーの認証トークン。起動ごとに再生成しないよう永続化する。
  static Future<String?> receiverToken() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kReceiverToken);
  }

  static Future<void> setReceiverToken(String token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kReceiverToken, token);
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
