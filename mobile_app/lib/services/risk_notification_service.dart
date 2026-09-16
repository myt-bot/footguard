import 'package:flutter/services.dart';

class RiskNotificationService {
  static const _channel = MethodChannel('footguard/notifications');

  Future<void> initialize() async {
    try {
      await _channel.invokeMethod<void>('initialize');
    } catch (_) {
      // Foreground dialog remains the primary alert if notifications are denied.
    }
  }

  Future<void> show({required String title, required String body}) async {
    try {
      await _channel.invokeMethod<void>('show', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }
}
