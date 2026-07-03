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
  static const int _sendFailId = 1003;
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

  /// 通知許可を求める（Android 13+）。許可されたか（結果）を返す。
  static Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? true;
  }

  /// OS レベルで通知が有効か（Android 13+ の権限や、チャンネル無効化も反映）。
  static Future<bool> areNotificationsEnabled() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? true;
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
      '送信結果',
      channelDescription: '送信の成功・失敗をお知らせします',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    ),
  );

  /// 通知が実際に表示できるかを確認するためのテスト通知。
  /// 例外は握りつぶさず呼び出し側に投げる（原因を画面に出すため）。
  /// 表示できたか（OSレベルで通知が有効か）を返す。
  static Future<bool> showTest() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final enabled = await android?.areNotificationsEnabled() ?? true;
    await _plugin.show(
      9999,
      'MediaRelay テスト通知',
      'これが見えれば通知は正常です',
      _sendResultDetails,
    );
    return enabled;
  }

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

  /// 送信結果を通知で知らせる。成功通知・失敗通知は設定で個別にオン/オフできる。
  /// [failureReason] は失敗時の理由（null なら件数から生成）。
  static Future<void> showSendResult({
    required int done,
    required int skipped,
    required int failed,
    required String destName,
    String? failureReason,
  }) async {
    if (done == 0 && skipped == 0 && failed == 0) return;
    await init();
    final isJa = PlatformDispatcher.instance.locale.languageCode == 'ja';

    // 失敗通知
    if (failed > 0 && await AppSettings.notifyOnFailure()) {
      final title = isJa ? '送信に失敗しました' : 'Send failed';
      final body = failureReason ??
          (isJa
              ? '$destName へ $failed 件送信できませんでした'
              : 'Failed to send $failed file(s) to $destName');
      await _plugin.show(_sendFailId, title, body, _sendResultDetails);
    }

    // 成功通知
    if ((done > 0 || skipped > 0) && await AppSettings.notifyOnSuccess()) {
      final title = isJa ? '$destName に送信しました' : 'Sent to $destName';
      final body = isJa
          ? '$done 件送信${skipped > 0 ? ' / $skipped 件スキップ' : ''}'
          : 'Sent $done${skipped > 0 ? ' / Skipped $skipped' : ''}';
      await _plugin.show(_sendResultId, title, body, _sendResultDetails);
    }
  }
}
