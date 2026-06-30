package com.kuboshige.media_relay

import android.content.ContentUris
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var wifiSsidSink: EventChannel.EventSink? = null
    private var wifiNetworkCallback: ConnectivityManager.NetworkCallback? = null

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
            } else if (call.method == "getDeviceModel") {
                result.success(Build.MODEL)
            } else if (call.method == "getCurrentSsid") {
                result.success(getSsidBestEffort())
            } else {
                result.notImplemented()
            }
        }

        // Wi-Fi SSID 変化を Dart に通知する EventChannel
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.kuboshige.media_relay/wifi_ssid",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                wifiSsidSink = events
                startWifiMonitoring()
            }
            override fun onCancel(arguments: Any?) {
                stopWifiMonitoring()
                wifiSsidSink = null
            }
        })

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

    private fun startWifiMonitoring() {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        wifiNetworkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val ssid = extractSsid(caps)
                mainHandler.post { wifiSsidSink?.success(ssid) }
            }
            override fun onLost(network: Network) {
                mainHandler.post { wifiSsidSink?.success(null) }
            }
        }
        cm.registerNetworkCallback(request, wifiNetworkCallback!!)
        // 現在の SSID を初回イベントとして送出する
        mainHandler.post { wifiSsidSink?.success(getSsidBestEffort()) }
    }

    private fun stopWifiMonitoring() {
        wifiNetworkCallback?.let {
            try {
                val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        wifiNetworkCallback = null
    }

    /** ベストエフォートで現在の Wi-Fi SSID を取得する。取得不可なら null。 */
    @Suppress("DEPRECATION")
    private fun getSsidBestEffort(): String? {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return null
        val caps = cm.getNetworkCapabilities(network) ?: return null
        return extractSsid(caps)
    }

    private fun extractSsid(caps: NetworkCapabilities): String? {
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return null
        // API 29+ では transportInfo 経由で WifiInfo を取得できるが
        // SSID は位置情報権限なしでは "<unknown ssid>" になることが多い。
        // それでもベストエフォートで試みる。
        val wifiInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            caps.transportInfo as? WifiInfo
        } else null
        val ssid = wifiInfo?.ssid?.removeSurrounding("\"")
        return if (ssid.isNullOrBlank() || ssid == "<unknown ssid>") null else ssid
    }
}
