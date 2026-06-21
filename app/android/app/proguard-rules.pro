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
