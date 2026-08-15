import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/screens/realtime_screen.dart';

void main() {
  test('realtime hides the enabled temperature offset compensation text', () {
    const status = CalibrationStatus(
      baselineReady: true,
      sampleCount: 40,
      requiredSamples: 40,
      emptyTemperatureReferenceReady: true,
      temperatureRiskEnabled: true,
      temperatureOffsetChannels: [0, 2],
    );

    expect(realtimeTemperatureStatusText(status), isNull);
  });

  test('realtime keeps other temperature calibration states visible', () {
    const status = CalibrationStatus(
      baselineReady: true,
      sampleCount: 40,
      requiredSamples: 40,
      emptyTemperatureReferenceReady: true,
      temperatureRiskEnabled: true,
    );

    expect(realtimeTemperatureStatusText(status), contains('温度基线已就绪'));
  });
}
