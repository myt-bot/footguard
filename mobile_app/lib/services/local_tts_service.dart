import 'package:flutter/services.dart';

abstract interface class TtsSpeaker {
  Future<bool> speak(String text);

  Future<void> stop();
}

class AndroidTtsService implements TtsSpeaker {
  AndroidTtsService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('footguard/tts');

  final MethodChannel _channel;
  Future<bool>? _initialization;

  Future<bool> _initialize() => _initialization ??= _channel
      .invokeMethod<bool>('initialize')
      .then((value) => value ?? false)
      .catchError((Object _) => false);

  @override
  Future<bool> speak(String text) async {
    if (text.trim().isEmpty || !await _initialize()) return false;
    try {
      return await _channel.invokeMethod<bool>('speak', {'text': text}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
