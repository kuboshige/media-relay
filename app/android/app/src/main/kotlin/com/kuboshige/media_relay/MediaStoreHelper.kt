package com.kuboshige.media_relay

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import java.io.File

object MediaStoreHelper {

    private const val TAG = "MediaStoreHelper"

    /**
     * 一時ファイルを MediaStore 経由で公開ストレージに登録する。
     * Android 10+（API 29+）必須。
     *
     * @param sourcePath     書き込み済みの一時ファイルパス
     * @param relativePath   元の相対パス（例: "DCIM/Camera/photo.jpg"）。ファイル名の取得に使う
     * @param originalDateMs 元の撮影日時（ミリ秒）。0 なら設定しない
     * @param mimeType       null の場合は拡張子から推定する
     * @return 成功時は content:// URI 文字列
     * @throws RuntimeException 失敗時（呼び出し元でキャッチしてエラー詳細を表示する）
     */
    fun insertFile(
        context: Context,
        sourcePath: String,
        relativePath: String,
        originalDateMs: Long,
        mimeType: String?,
    ): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw RuntimeException("Android 10+ (API 29+) required")
        }

        val src = File(sourcePath)
        if (!src.exists()) {
            throw RuntimeException("Source file not found: $sourcePath")
        }

        val fileName = File(relativePath).name
        val mime = mimeType?.takeIf { it.isNotBlank() }
            ?: guessMime(fileName)
            ?: "application/octet-stream"

        // Android 標準の media バケットに置くことで、非標準パスへの insert 拒否を回避する。
        // Google フォトは DCIM/Pictures/Movies 配下を常にインデックスする。
        val (collection, relDir) = when {
            mime.startsWith("image/") ->
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "Pictures/MediaRelay/"
            mime.startsWith("video/") ->
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "Movies/MediaRelay/"
            else ->
                MediaStore.Files.getContentUri("external") to "Download/MediaRelay/"
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

        Log.d(TAG, "insert: $relDir$fileName mime=$mime src=${src.length()} bytes")

        val uri: Uri = try {
            context.contentResolver.insert(collection, values)
                ?: throw RuntimeException(
                    "contentResolver.insert returned null " +
                    "(collection=$collection relDir=$relDir fileName=$fileName)"
                )
        } catch (e: Exception) {
            Log.e(TAG, "insert failed: ${e.message}", e)
            throw RuntimeException("insert failed: ${e.message}", e)
        }

        return try {
            val out = context.contentResolver.openOutputStream(uri)
                ?: throw RuntimeException("openOutputStream returned null for $uri")
            out.use { o -> src.inputStream().use { it.copyTo(o) } }

            val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            context.contentResolver.update(uri, done, null, null)
            Log.d(TAG, "success: $uri")
            uri.toString()
        } catch (e: Exception) {
            Log.e(TAG, "write failed: ${e.message}", e)
            runCatching { context.contentResolver.delete(uri, null, null) }
            throw RuntimeException("write failed: ${e.message}", e)
        }
    }

    private fun guessMime(name: String): String? = when (name.substringAfterLast('.').lowercase()) {
        "jpg", "jpeg"  -> "image/jpeg"
        "png"          -> "image/png"
        "gif"          -> "image/gif"
        "webp"         -> "image/webp"
        "heic", "heif" -> "image/heic"
        "mp4"          -> "video/mp4"
        "mov"          -> "video/quicktime"
        "mkv"          -> "video/x-matroska"
        "avi"          -> "video/x-msvideo"
        "3gp"          -> "video/3gpp"
        "webm"         -> "video/webm"
        else           -> null
    }
}
