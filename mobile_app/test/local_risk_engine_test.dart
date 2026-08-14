import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/local_risk_engine.dart';

FootFrame frame(
  String side,
  int sequence,
  List<double> pressure, {
  List<double> temperature = const [30, 30, 30, 30],
  int qualityFlags = 0,
}) =>
    FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_${side}_001',
      side: side,
      syncId: 7,
      packetSeq: sequence,
      timestampMs: 100000 + sequence * 200,
      pressure: pressure,
      temperature: temperature,
      imu: const ImuData(ax: 0, ay: 0, az: 9.8, gx: 0, gy: 0, gz: 0),
      battery: 50,
      qualityFlags: qualityFlags,
      source: 'ble',
    );

void main() {
  test('learns 40 balanced pairs and ignores unloaded single-point residual',
      () {
    final engine = LocalRiskEngine();
    const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];
    for (var sequence = 0; sequence < 40; sequence += 1) {
      engine.evaluate([
        frame('left', sequence, standing),
        frame('right', sequence, standing),
      ]);
    }
    expect(engine.baselineReady, isTrue);

    LocalRiskResult? result;
    for (var sequence = 40; sequence < 90; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, const [0, 0, 0, 0, 0, 0]),
        frame('right', sequence, const [0, 0, 0.12, 0, 0, 0]),
      ]);
    }
    expect(result!.activeRisks, isEmpty);
    expect(result.risk.isNormal, isTrue);
  });

  test('detects sustained left bias and keeps temperature dropout independent',
      () {
    final engine = LocalRiskEngine();
    const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];
    for (var sequence = 0; sequence < 40; sequence += 1) {
      engine.evaluate([
        frame('left', sequence, standing),
        frame('right', sequence, standing),
      ]);
    }

    LocalRiskResult? result;
    for (var sequence = 40; sequence < 75; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, const [0.08, 0.08, 0.08, 0.08, 0.12, 0.12],
            qualityFlags: 0x3c0),
        frame('right', sequence, standing, qualityFlags: 0x3c0),
      ]);
    }
    expect(
      result!.activeRisks.any((risk) => risk.riskType == 'left_load_bias'),
      isTrue,
    );
    expect(
      result.activeRisks
          .any((risk) => risk.riskType == 'temperature_asymmetry'),
      isFalse,
    );
  });

  test(
      'learns four empty temperature offsets and allows unloaded compensated heat',
      () {
    final engine = LocalRiskEngine();
    const emptyLeft = [33.0, 27.2, 30.4, 32.4];
    const emptyRight = [30.0, 30.0, 30.0, 30.0];
    const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];
    for (var sequence = 0; sequence < 140; sequence += 1) {
      engine.evaluate([
        frame('left', sequence, const [0, 0, 0, 0, 0, 0],
            temperature: emptyLeft),
        frame('right', sequence, const [0, 0, 0, 0, 0, 0],
            temperature: emptyRight),
      ]);
    }
    for (var sequence = 140; sequence < 180; sequence += 1) {
      engine.evaluate([
        frame('left', sequence, standing, temperature: emptyLeft),
        frame('right', sequence, standing, temperature: emptyRight),
      ]);
    }
    expect(engine.baselineReady, isTrue);

    LocalRiskResult? result;
    for (var sequence = 180; sequence < 230; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, const [0, 0, 0, 0, 0, 0],
            temperature: [36, 24.2, 30.4, 32.4]),
        frame('right', sequence, const [0, 0, 0, 0, 0, 0],
            temperature: emptyRight),
      ]);
    }
    expect(result!.temperatureRiskEnabled, isTrue);
    expect(
        result.activeRisks
            .any((risk) => risk.riskType == 'temperature_asymmetry'),
        isTrue);
  });
}
