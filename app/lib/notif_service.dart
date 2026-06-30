import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'app_settings.dart';

/// アプリがバックグラウンド/停止中に通知アクションが叩かれたときの空ハンドラ。
/// @pragma が必要（ツリーシェイクから保護する）。
@pragma('vm:entry-point')
void _notifBackgroundHandler(NotificationResponse response) {
  // アプリ停止中は Flutter コンテキストが使えないため何もしない。
  // 起動後に getNotificationAppLaunchDetails で拾う。
}

/// ローカル通知サービス。
///
/// 機能:
/// 1. 未送信リマインダー（デッドマンスイッチ）— sendNow アクションボタン付き
/// 2. 送信完了通知
///
/// [sendNowEvents] を購読すると「今すぐ送信」タップ時に通知を受け取れる。
class NotifService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const int _reminderId = 1001;
  static const int _sendResultId = 1002;
  static bool _inited = false;

  static final _sendNowCtrl = StreamController<void>.broadcast();

  /// リマインダー通知の「今すぐ送信」が押されたとき発火するストリーム。
  static Stream<void> get sendNowEvents => _sendNowCtrl.stream;

  static Future<void> init() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _handleResponse,
      onDidReceiveBackgroundNotificationResponse: _notifBackgroundHandler,
    );
    _inited = true;

    // アプリが通知アクションから起動された場合を処理する
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse?.actionId == 'send_now') {
      Future.microtask(() => _sendNowCtrl.add(null));
    }
  }

  static void _handleResponse(NotificationResponse response) {
    if (response.actionId == 'send_now') {
      _sendNowCtrl.add(null);
    }
  }

  /// 通知許可を求める（Android 13+）。
  static Future<void> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  static Future<NotificationDetails> _reminderDetails() async {
    final showAction = await AppSettings.reminderSendNow();
    return NotificationDetails(
      android: AndroidNotificationDetails(
        'sync_reminder',
        '送信リマインダー',
        channelDescription: '未送信の写真があるとき送信を促します',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        actions: showAction
            ? const [
                AndroidNotificationAction(
                  'send_now',
                  '今すぐ送信',
                  showsUserInterface: true,
                )
              ]
            : const [],
      ),
    );
  }

  static const _sendResultDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'send_result',
      '送信完了',
      channelDescription: '送信が完了したとき結果を表示します',
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
    if (days <= 0) return;

    var lastMs = await AppSettings.lastSyncMs();
    if (lastMs == null) {
      await AppSettings.setLastSyncNow();
      lastMs = DateTime.now().millisecondsSinceEpoch;
    }

    final target =
        DateTime.fromMillisecondsSinceEpoch(lastMs).add(Duration(days: days));
    final now = tz.TZDateTime.now(tz.UTC);
    var fireAt = tz.TZDateTime.from(target.toUtc(), tz.UTC);
    if (!fireAt.isAfter(now)) {
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
      await _reminderDetails(),
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

  /// 送信完了を通知で知らせる（設定 OFF のときは何もしない）。
  static Future<void> showSendResult({
    required int done,
    required int skipped,
    required int failed,
    required String destName,
  }) async {
    if (done == 0 && skipped == 0 && failed == 0) return;
    final enabled = await AppSettings.notifyOnSendResult();
    if (!enabled) return;
    await init();
    final isJa = PlatformDispatcher.instance.locale.languageCode == 'ja';
    final title = isJa ? '$destName に送信完了' : 'Sent to $destName';
    final body = isJa
        ? '$done件送信 / $skipped件スキップ / $failed件失敗'
        : 'Sent: $done / Skipped: $skipped / Failed: $failed';
    await _plugin.show(_sendResultId, title, body, _sendResultDetails);
  }
}
