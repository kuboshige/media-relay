import 'package:flutter/services.dart';

class ReceiverService {
  static const _ch =
      MethodChannel('com.kuboshige.media_relay/receiver_service');

  static Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  static Future<bool> isBatteryOptimizationIgnored() async {
    try {
      return await _ch.invokeMethod<bool>('isBatteryOptimizationIgnored') ??
          true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestIgnoreBatteryOptimization() async {
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimization');
    } catch (_) {}
  }
}
