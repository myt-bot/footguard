import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/services/local_tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('footguard/tts-test');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initializes Android Chinese TTS and speaks locally', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = AndroidTtsService(channel: channel);

    expect(await service.speak('请调整受力'), isTrue);
    expect(calls.map((call) => call.method), ['initialize', 'speak']);
    expect(calls.last.arguments, {'text': '请调整受力'});
  });

  test('keeps text fallback when Chinese speech is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    final service = AndroidTtsService(channel: channel);

    expect(await service.speak('风险提醒'), isFalse);
  });
}
