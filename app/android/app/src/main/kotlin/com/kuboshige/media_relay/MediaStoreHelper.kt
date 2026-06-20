package com.kuboshige.media_relay

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.File

/**
 * 受信ファイルを公開 MediaStore（/sdcard/MediaRelay/...）に登録する。
 * Android 10+（API 29+）必須。それ以外は null を返す。
 */
object MediaStoreHelper {

    /**
     * 一時ファイルを MediaStore 経由で公開ストレージに移動・登録する。
     *
     * @param sourcePath   書き込み済みの一時ファイルパス（呼び出し元が削除する）
     * @param relativePath 元の相対パス（例: "DCIM/Camera/photo.jpg"）
     *                     保存先は /sdcard/MediaRelay/<relativePath> になる
     * @param originalDateMs 元の撮影日時（ミリ秒）。0 なら設定しない
     * @param mimeType     null の場合は拡張子から推定する
     * @return 成功時は content:// URI 文字列、失敗・非対応時は null
     */
    fun insertFile(
        context: Context,
        sourcePath: String,
        relativePath: String,
        originalDateMs: Long,
        mimeType: String?,
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null

        val src = File(sourcePath)
        if (!src.exists()) return null

        val fileName = File(relativePath).name
        val dirPart = File(relativePath).parent?.trimEnd('/') ?: ""
        val relDir = if (dirPart.isEmpty()) "MediaRelay/" else "MediaRelay/$dirPart/"

        val mime = mimeType?.takeIf { it.isNotBlank() }
            ?: guessMime(fileName)
            ?: "application/octet-stream"

        val collection: Uri = when {
            mime.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            mime.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            else -> MediaStore.Files.getContentUri("external")
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            if (originalDateMs > 0L) {
                put(MediaStore.MediaColumns.DATE_ADDED, originalDateMs / 1000L)
                put(MediaStore.MediaColumns.DATE_MODIFIED, originalDateMs / 1000L)
                put(MediaStore.MediaColumns.DATE_TAKEN, originalDateMs)
            }
        }

        val uri = try {
            context.contentResolver.insert(collection, values)
        } catch (e: Exception) {
            return null
        } ?: return null

        return try {
            context.contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { it.copyTo(out) }
            }
            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            context.contentResolver.update(uri, done, null, null)
            uri.toString()
        } catch (e: Exception) {
            runCatching { context.contentResolver.delete(uri, null, null) }
            null
        }
    }

    private fun guessMime(name: String): String? = when (name.substringAfterLast('.').lowercase()) {
        "jpg", "jpeg" -> "image/jpeg"
        "png"         -> "image/png"
        "gif"         -> "image/gif"
        "webp"        -> "image/webp"
        "heic", "heif" -> "image/heic"
        "mp4"         -> "video/mp4"
        "mov"         -> "video/quicktime"
        "mkv"         -> "video/x-matroska"
        "avi"         -> "video/x-msvideo"
        "3gp"         -> "video/3gpp"
        "webm"        -> "video/webm"
        else          -> null
    }
}
