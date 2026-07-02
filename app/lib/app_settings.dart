import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'media_store.dart';

/// アプリ全体の軽量設定（サーバー以外）。SharedPreferences に保存する。
class AppSettings {
  static const _kReminderDays = 'reminderDays';
  static const _kLastSync = 'lastSyncEpochMs';
  static const _kReceiverPort = 'receiverPort';
  static const _kDeviceName = 'deviceName';
  static const _kReceiverAutoStopMinutes = 'receiverAutoStopMinutes';
  static const _kStartupAction = 'startupAction';
  static const _kReceiverToken = 'receiverToken';
  static const _kLastSendError = 'lastSendErrorJson';
  static const _kNotifyOnSendResult = 'notifyOnSendResult';
  static const _kReminderSendNow = 'reminderSendNow';
  static const _kWifiAutoSendEnabled = 'wifiAutoSendEnabled';
  static const _kWifiAutoSendSsid = 'wifiAutoSendSsid';

  static const String startupActionNone = 'none';
  static const String startupActionSend = 'send';
  static const String startupActionSendAndDelete = 'sendAndDelete';

  /// この端末の表示名（受信モードのQRに載り、送信側に登録される名前）。
  /// 未設定のときは Android の Build.MODEL（例: "Pixel 5"）を返す。
  static Future<String> deviceName() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kDeviceName);
    if (saved != null && saved.isNotEmpty) return saved;
    return await MediaStore.deviceModel() ?? 'メディアリレー受信機';
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

  /// 最後の送信エラー情報を JSON で保存する。
  /// 型: 'connection' | 'auth' | 'storage' | 'files'
  static Future<Map<String, dynamic>?> lastSendError() async {
    final p = await SharedPreferences.getInstance();
    final json = p.getString(_kLastSendError);
    if (json == null) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setLastSendError({
    required String type,
    required String serverName,
    int failedCount = 0,
    int totalCount = 0,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kLastSendError,
      jsonEncode({
        'type': type,
        'serverName': serverName,
        'failedCount': failedCount,
        'totalCount': totalCount,
        'at': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  static Future<void> clearLastSendError() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLastSendError);
  }

  /// 送信完了後に通知で結果を表示するか（既定 ON）。
  static Future<bool> notifyOnSendResult() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kNotifyOnSendResult) ?? true;
  }

  static Future<void> setNotifyOnSendResult(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kNotifyOnSendResult, v);
  }

  /// リマインダー通知に「今すぐ送信」ボタンを表示するか（既定 ON）。
  static Future<bool> reminderSendNow() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kReminderSendNow) ?? true;
  }

  static Future<void> setReminderSendNow(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kReminderSendNow, v);
  }

  /// Wi-Fi 接続時に未送信ファイルを自動送信するか（既定 OFF）。
  static Future<bool> wifiAutoSendEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kWifiAutoSendEnabled) ?? false;
  }

  static Future<void> setWifiAutoSendEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kWifiAutoSendEnabled, v);
  }

  /// 自動送信を絞り込む対象 Wi-Fi の SSID。空なら全 Wi-Fi で自動送信。
  static Future<String?> wifiAutoSendSsid() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kWifiAutoSendSsid);
    return (v == null || v.isEmpty) ? null : v;
  }

  static Future<void> setWifiAutoSendSsid(String ssid) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kWifiAutoSendSsid, ssid);
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
