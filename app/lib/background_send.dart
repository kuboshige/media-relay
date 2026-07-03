import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:workmanager/workmanager.dart';
import 'app_settings.dart';
import 'folder_config.dart';
import 'media_source.dart';
import 'sent_store.dart';
import 'server_config.dart';
import 'uploader.dart';

const kBgSendTask = 'wifiAutoSend';
const kBgSendUniqueKey = 'media_relay_wifi_auto_send';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != kBgSendTask) return true;
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await _runBackgroundSend();
    } catch (_) {}
    return true;
  });
}

/// 設定に応じてバックグラウンド定期送信を登録または解除する。
///
/// WorkManager は Wi-Fi(unmetered) 接続時のみジョブを実行するため、
/// 「Wi-Fiが無ければ待機、掴んだら送信を試みる」という挙動になる。
/// 送信先は自宅LANの固定IPなので、別のWi-Fiでは ping が通らず即終了する。
///
/// [forceReschedule] が true のときは、間隔設定の変更を反映するため
/// 既存タスクを取り消してから登録し直す。
Future<void> scheduleBgSendIfEnabled({bool forceReschedule = false}) async {
  final enabled = await AppSettings.wifiAutoSendEnabled();
  if (!enabled) {
    await Workmanager().cancelByUniqueName(kBgSendUniqueKey);
    return;
  }
  if (forceReschedule) {
    await Workmanager().cancelByUniqueName(kBgSendUniqueKey);
  }
  final minutes = await AppSettings.bgIntervalMinutes();
  await Workmanager().registerPeriodicTask(
    kBgSendUniqueKey,
    kBgSendTask,
    frequency: Duration(minutes: minutes),
    constraints: Constraints(networkType: NetworkType.unmetered),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

Future<void> _runBackgroundSend() async {
  final enabled = await AppSettings.wifiAutoSendEnabled();
  if (!enabled) return;

  final servers = await ServerConfig.load();
  final selectedIdx = await ServerConfig.selectedIndex();
  if (servers.isEmpty || selectedIdx >= servers.length) return;
  final server = servers[selectedIdx];

  // 送るものが無ければ何も通知せず静かに終わる（未送信を先に確認）。
  PhotoManager.setIgnorePermissionCheck(true);
  final albumIds = await FolderConfig.loadSelected();
  final media = await MediaSource.listFromAlbums(albumIds);
  final sentIds = await SentStore.sentAssetIds();
  final unsent = media
      .where((m) => !sentIds.contains(m.id))
      .toList()
      .reversed
      .toList();
  if (unsent.isEmpty) return;

  final uploader = Uploader(server);
  final status = await uploader
      .pingStatus()
      .timeout(const Duration(seconds: 8), onTimeout: () => null);
  if (status != 200) {
    // 未送信があるのに送れなかった → 失敗を通知（設定で ON のとき）。
    final type = status == 401 ? 'auth' : 'connection';
    await AppSettings.setLastSendError(
        type: type, serverName: server.name, totalCount: unsent.length);
    await _notifyFailure(server.name, type);
    return;
  }

  final caps = await uploader
      .info()
      .timeout(const Duration(seconds: 10), onTimeout: () => null);
  if (caps == null) {
    await AppSettings.setLastSendError(
        type: 'connection', serverName: server.name, totalCount: unsent.length);
    await _notifyFailure(server.name, 'connection');
    return;
  }

  final targets = unsent.take(50).toList();
  int done = 0, failed = 0;
  var stoppedForStorage = false;

  for (final item in targets) {
    try {
      final File? file =
          await item.originFile().timeout(const Duration(seconds: 30));
      if (file == null) {
        failed++;
        continue;
      }
      int? size;
      try {
        size = await file.length();
      } catch (_) {}

      final UploadResult res;
      if (caps.app) {
        res = await uploader
            .uploadRaw(file, item.relativePath,
                originalDateMs: item.createdAt.millisecondsSinceEpoch)
            .timeout(const Duration(minutes: 5),
                onTimeout: () => UploadResult(ok: false, error: 'timeout'));
      } else {
        res = await uploader
            .upload(file, item.relativePath,
                originalDateMs: item.createdAt.millisecondsSinceEpoch)
            .timeout(const Duration(minutes: 5),
                onTimeout: () => UploadResult(ok: false, error: 'timeout'));
      }

      if (res.ok) {
        done++;
        await SentStore.markSent(
          assetId: item.id,
          fileSize: size,
          modifiedTime: item.modifiedAt.millisecondsSinceEpoch,
          relativePath: item.relativePath,
        );
        // 履歴に残す（アプリを開いたとき何が自動送信されたか分かるように）。
        await SentStore.log(
          assetId: item.id,
          title: item.title,
          relativePath: item.relativePath,
          status: 'sent',
          size: size,
        );
      } else if (res.insufficientStorage) {
        stoppedForStorage = true;
        await AppSettings.setLastSendError(
          type: 'storage',
          serverName: server.name,
          failedCount: failed,
          totalCount: targets.length,
        );
        break;
      } else {
        failed++;
        await SentStore.log(
          assetId: item.id,
          title: item.title,
          relativePath: item.relativePath,
          status: 'failed',
          detail: res.error,
          size: size,
        );
      }
    } catch (_) {
      failed++;
    }
  }

  if (done > 0 && caps.supportsMediaScan) {
    try {
      await uploader.scan().timeout(const Duration(minutes: 3));
    } catch (_) {}
  }

  if (done > 0) {
    await AppSettings.clearLastSendError();
    await AppSettings.setLastSyncNow();
  } else if (failed > 0 && !stoppedForStorage) {
    await AppSettings.setLastSendError(
      type: 'files',
      serverName: server.name,
      failedCount: failed,
      totalCount: targets.length,
    );
  }

  // 成功／失敗をそれぞれの通知設定に従って知らせる。
  if (done > 0) await _notifySuccess(done, server.name);
  if (stoppedForStorage) {
    await _notifyFailure(server.name, 'storage');
  } else if (failed > 0) {
    await _notifyFailure(server.name, 'files', failed: failed);
  }
}

Future<void> _notifySuccess(int done, String destName) async {
  if (!await AppSettings.notifyOnSuccess()) return;
  final isJa = PlatformDispatcher.instance.locale.languageCode == 'ja';
  await _show(
    3,
    isJa ? '$destName に自動送信' : 'Auto-sent to $destName',
    isJa ? '$done 件送信しました' : 'Sent $done file(s)',
  );
}

Future<void> _notifyFailure(String destName, String type,
    {int failed = 0}) async {
  if (!await AppSettings.notifyOnFailure()) return;
  final isJa = PlatformDispatcher.instance.locale.languageCode == 'ja';
  await _show(
    4,
    isJa ? '自動送信に失敗しました' : 'Auto-send failed',
    _failureBody(type, destName, failed, isJa),
  );
}

String _failureBody(String type, String destName, int failed, bool isJa) {
  switch (type) {
    case 'auth':
      return isJa
          ? '認証エラー（トークン不一致）。設定でQRを再スキャンしてください'
          : 'Auth error (token mismatch). Re-scan the QR in Settings.';
    case 'storage':
      return isJa
          ? '$destName の空き容量が不足しています'
          : '$destName is out of storage';
    case 'files':
      return isJa ? '$failed 件の送信に失敗しました' : 'Failed to send $failed file(s)';
    default:
      return isJa
          ? '$destName に接続できませんでした（受信側が起動していない可能性）'
          : 'Could not connect to $destName (receiver may be off)';
  }
}

Future<void> _show(int id, String title, String body) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await plugin.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'send_result',
          '送信結果',
          channelDescription: '送信の成功・失敗をお知らせします',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  } catch (_) {}
}
