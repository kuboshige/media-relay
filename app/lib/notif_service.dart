import 'dart:ui' show PlatformDispatcher;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'app_settings.dart';

/// 未送信リマインダー（ローカル通知）。
///
/// 仕組みはデッドマンスイッチ方式：送信のたびに「次回 N 日後」へ予約を先送りする。
/// こまめに送っている限り通知は出ず、N 日サボると「送信していません」と促す。
/// バックグラウンド通信もメディア走査も不要。N は設定から変更（0でオフ）。
class NotifService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const int _reminderId = 1001;
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _inited = true;
  }

  /// 通知許可を求める（Android 13+）。
  static Future<void> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'sync_reminder',
      '送信リマインダー',
      channelDescription: '未送信の写真があるとき送信を促します',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  /// 設定と最終送信時刻にもとづいてリマインダーを再設定する。
  /// reminderDays が 0 以下ならオフ（予約をキャンセルするだけ）。
  static Future<void> reschedule() async {
    await init();
    await _plugin.cancel(_reminderId);

    final days = await AppSettings.reminderDays();
    if (days <= 0) return; // オフ

    var lastMs = await AppSettings.lastSyncMs();
    if (lastMs == null) {
      // 初回はインストール直後に即通知しないよう、今を基準にする
      await AppSettings.setLastSyncNow();
      lastMs = DateTime.now().millisecondsSinceEpoch;
    }

    final target =
        DateTime.fromMillisecondsSinceEpoch(lastMs).add(Duration(days: days));
    final now = tz.TZDateTime.now(tz.UTC);
    var fireAt = tz.TZDateTime.from(target.toUtc(), tz.UTC);
    if (!fireAt.isAfter(now)) {
      // すでに過ぎている（=しばらく送っていない）なら少し先で促す
      fireAt = now.add(const Duration(minutes: 5));
    }

    final isJa = PlatformDispatcher.instance.locale.languageCode == 'ja';
    final body = isJa
        ? '$days日間 送信していません。未送信の写真を送信しましょう'
        : 'You haven\'t sent in $days day(s). Send your unsent photos now.';
    await _plugin.zonedSchedule(
      _reminderId,
      'media-relay',
      body,
      fireAt,
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  /// 送信が行われたとき：最終送信時刻を更新し、次のリマインダーを先送りする。
  static Future<void> markSynced() async {
    await AppSettings.setLastSyncNow();
    await reschedule();
  }
}
