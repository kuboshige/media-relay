package com.kuboshige.media_relay

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kuboshige.media_relay/media_store",
        ).setMethodCallHandler { call, result ->
            if (call.method == "insertFile") {
                val sourcePath = call.argument<String>("sourcePath")
                val relativePath = call.argument<String>("relativePath")
                val originalDateMs = call.argument<Long>("originalDateMs") ?: 0L
                val mimeType = call.argument<String>("mimeType")
                if (sourcePath == null || relativePath == null) {
                    result.error("INVALID_ARGS", "sourcePath and relativePath required", null)
                    return@setMethodCallHandler
                }
                val uri = MediaStoreHelper.insertFile(
                    context, sourcePath, relativePath, originalDateMs, mimeType)
                result.success(uri)
            } else {
                result.notImplemented()
            }
        }
    }
}
