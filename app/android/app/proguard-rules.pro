# ML Kit (mobile_scanner がバーコード/QRスキャンに使用)
# リフレクションでクラスを参照するため R8 に削除されないよう保護する
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**

# CameraX (mobile_scanner がカメラプレビューに使用)
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# mobile_scanner プラグイン本体
-keep class dev.steenbakker.mobile_scanner.** { *; }
-dontwarn dev.steenbakker.mobile_scanner.**

# workmanager（バックグラウンド定期送信）
# WorkManager は Worker クラスをクラス名からリフレクションで生成するため、
# R8 が削除するとプロセス起動時のタスク復元で即クラッシュする（release限定の起動不能バグ）。
# パッケージ名の変更に強いよう、Worker/ListenableWorker の派生をすべて保護する。
-keep class * extends androidx.work.ListenableWorker { *; }
-keep class * extends androidx.work.Worker { *; }
-keep class androidx.work.** { *; }
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class be.tramckrijte.workmanager.** { *; }
-dontwarn dev.fluttercommunity.workmanager.**
-dontwarn be.tramckrijte.workmanager.**

# flutter_local_notifications（スケジュール通知でレシーバをリフレクション参照）
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**
