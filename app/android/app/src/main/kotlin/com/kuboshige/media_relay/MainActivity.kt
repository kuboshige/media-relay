package com.kuboshige.media_relay

import android.content.ContentUris
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kuboshige.media_relay/media_store",
        ).setMethodCallHandler { call, result ->
            if (call.method == "insertFile") {
                val sourcePath = call.argument<String>("sourcePath")
                val relativePath = call.argument<String>("relativePath")
                // Dart int は値によって Java Integer / Long どちらで届くか不定のため Number で受ける
                val originalDateMs =
                    (call.argument<Any>("originalDateMs") as? Number)?.toLong() ?: 0L
                val mimeType = call.argument<String>("mimeType")

                if (sourcePath == null || relativePath == null) {
                    result.error("INVALID_ARGS", "sourcePath and relativePath required", null)
                    return@setMethodCallHandler
                }

                // ContentResolver の I/O をバックグラウンドで実行（UI スレッドをブロックしない）
                Thread {
                    try {
                        val uri = MediaStoreHelper.insertFile(
                            applicationContext, sourcePath, relativePath, originalDateMs, mimeType)
                        mainHandler.post { result.success(uri) }
                    } catch (e: Exception) {
                        mainHandler.post {
                            result.error("MEDIA_STORE_ERROR", e.message ?: "unknown", null)
                        }
                    }
                }.start()
            } else if (call.method == "openAsset") {
                val id = call.argument<String>("id")
                val type = call.argument<Int>("type") ?: 1
                if (id == null) { result.success(null); return@setMethodCallHandler }
                try {
                    val baseUri = if (type == 2)
                        MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    else
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    val uri = ContentUris.withAppendedId(baseUri, id.toLong())
                    val intent = Intent(Intent.ACTION_VIEW, uri)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(intent)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kuboshige.media_relay/upload_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startForegroundService(
                        Intent(this, UploadForegroundService::class.java))
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, UploadForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kuboshige.media_relay/receiver_service",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startForegroundService(
                        Intent(this, ReceiverForegroundService::class.java))
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, ReceiverForegroundService::class.java))
                    result.success(null)
                }
                "isBatteryOptimizationIgnored" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimization" -> {
                    try {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
