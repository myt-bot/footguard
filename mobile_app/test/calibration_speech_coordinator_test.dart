import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/services/calibration_speech_coordinator.dart';

void main() {
  test('calibration speech stays silent until an explicit reset', () {
    final coordinator = CalibrationSpeechCoordinator();

    expect(coordinator.active, isFalse);
    expect(coordinator.take('empty_reference'), isFalse);
    expect(coordinator.take('put_on'), isFalse);
    expect(coordinator.take('complete'), isFalse);
  });

  test('each audible calibration stage is taken once in one reset flow', () {
    final coordinator = CalibrationSpeechCoordinator()..start();

    expect(coordinator.take('empty_reference'), isTrue);
    expect(coordinator.take('empty_reference'), isFalse);
    expect(coordinator.take('put_on'), isTrue);
    expect(coordinator.take('put_on'), isFalse);
    expect(coordinator.take('standing_baseline'), isFalse);
    expect(coordinator.take('standing_baseline'), isFalse);
    expect(coordinator.take('complete'), isTrue);
    expect(coordinator.active, isFalse);
    expect(coordinator.take('empty_reference'), isFalse);
  });

  test('starting a new reset enables a fresh speech flow', () {
    final coordinator = CalibrationSpeechCoordinator()..start();
    expect(coordinator.take('empty_reference'), isTrue);
    coordinator.cancel();
    expect(coordinator.take('put_on'), isFalse);

    coordinator.start();
    expect(coordinator.take('empty_reference'), isTrue);
  });
}
