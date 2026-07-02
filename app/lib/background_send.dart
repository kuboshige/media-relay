import 'dart:io';
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
Future<void> scheduleBgSendIfEnabled() async {
  final enabled = await AppSettings.wifiAutoSendEnabled();
  if (enabled) {
    await Workmanager().registerPeriodicTask(
      kBgSendUniqueKey,
      kBgSendTask,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.unmetered),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  } else {
    await Workmanager().cancelByUniqueName(kBgSendUniqueKey);
  }
}

Future<void> _runBackgroundSend() async {
  final enabled = await AppSettings.wifiAutoSendEnabled();
  if (!enabled) return;

  final servers = await ServerConfig.load();
  final selectedIdx = await ServerConfig.selectedIndex();
  if (servers.isEmpty || selectedIdx >= servers.length) return;
  final server = servers[selectedIdx];

  final uploader = Uploader(server);
  final status = await uploader
      .pingStatus()
      .timeout(const Duration(seconds: 8), onTimeout: () => null);
  if (status != 200) {
    if (status == 401) {
      await AppSettings.setLastSendError(type: 'auth', serverName: server.name);
    }
    return;
  }

  final caps = await uploader
      .info()
      .timeout(const Duration(seconds: 10), onTimeout: () => null);
  if (caps == null) return;

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

  final targets = unsent.take(50).toList();
  int done = 0, failed = 0;
  var stoppedForStorage = false;

  for (final item in targets) {
    try {
      final File? file = await item
          .originFile()
          .timeout(const Duration(seconds: 30));
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
            .timeout(
                const Duration(minutes: 5),
                onTimeout: () => UploadResult(ok: false, error: 'timeout'));
      } else {
        res = await uploader
            .upload(file, item.relativePath,
                originalDateMs: item.createdAt.millisecondsSinceEpoch)
            .timeout(
                const Duration(minutes: 5),
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
  } else if (failed > 0 && done == 0 && !stoppedForStorage) {
    await AppSettings.setLastSendError(
      type: 'files',
      serverName: server.name,
      failedCount: failed,
      totalCount: targets.length,
    );
  }

  final notifyEnabled = await AppSettings.notifyOnSendResult();
  if (notifyEnabled && (done > 0 || failed > 0)) {
    await _showBgNotification(done, failed, server.name);
  }
}

Future<void> _showBgNotification(
    int done, int failed, String destName) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await plugin.show(
      3,
      'MediaRelay',
      '送信完了: $done件 / 失敗: $failed件 → $destName',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'send_result',
          '送信結果',
          importance: Importance.low,
          priority: Priority.low,
        ),
      ),
    );
  } catch (_) {}
}
