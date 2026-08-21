import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/local_risk_engine.dart';

FootFrame frame(
  String side,
  int sequence,
  List<double> pressure, {
  List<double> temperature = const [30, 30, 30, 30],
  ImuData imu = const ImuData(ax: 0, ay: 0, az: 9.8, gx: 0, gy: 0, gz: 0),
  int qualityFlags = 0,
  int? timestampMs,
}) =>
    FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_${side}_001',
      side: side,
      syncId: 7,
      packetSeq: sequence,
      timestampMs: timestampMs ?? 100000 + sequence * 200,
      pressure: pressure,
      temperature: temperature,
      imu: imu,
      battery: 50,
      qualityFlags: qualityFlags,
      source: 'ble',
    );

void main() {
  test('uses adjacent IMU vectors to recognize smooth walking motion', () {
    final engine = LocalRiskEngine();
    LocalRiskResult? result;
    for (var sequence = 0; sequence < 3; sequence += 1) {
      final ax = sequence == 0 ? 0.0 : 1.0;
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          const [0.03, 0.03, 0.03, 0.03, 0.05, 0.05],
          imu: ImuData(ax: ax, ay: 0, az: 9.75, gx: 1, gy: 0, gz: 0),
        ),
        frame(
          'right',
          sequence,
          const [0.03, 0.03, 0.03, 0.03, 0.05, 0.05],
          imu: ImuData(ax: ax, ay: 0, az: 9.75, gx: 1, gy: 0, gz: 0),
        ),
      ]);
    }
    expect(result!.motionState, 'moving');
  });

  test(
    'learns 40 balanced pairs and ignores unloaded single-point residual',
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
    },
  );

  test(
    'detects sustained left bias and keeps temperature dropout independent',
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
          frame(
              'left',
              sequence,
              const [
                0.08,
                0.08,
                0.08,
                0.08,
                0.12,
                0.12,
              ],
              qualityFlags: 0x3c0),
          frame('right', sequence, standing, qualityFlags: 0x3c0),
        ]);
      }
      expect(
        result!.activeRisks.any((risk) => risk.riskType == 'left_load_bias'),
        isTrue,
      );
      expect(
        result.activeRisks.any(
          (risk) => risk.riskType == 'temperature_asymmetry',
        ),
        isFalse,
      );
    },
  );

  test('20 Hz frames need about eight seconds to build wearing baseline', () {
    final engine = LocalRiskEngine();
    const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];

    LocalRiskResult? result;
    for (var sequence = 0; sequence <= 40; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          standing,
          timestampMs: 100000 + sequence * 50,
        ),
        frame(
          'right',
          sequence,
          standing,
          timestampMs: 100013 + sequence * 50,
        ),
      ]);
    }

    expect(result!.baselineReady, isFalse);
    expect(result.baselineSamples, 11);

    for (var sequence = 41; sequence <= 156; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          standing,
          timestampMs: 100000 + sequence * 50,
        ),
        frame(
          'right',
          sequence,
          standing,
          timestampMs: 100013 + sequence * 50,
        ),
      ]);
    }

    expect(result!.baselineReady, isTrue);
    expect(result.baselineSamples, LocalRiskEngine.requiredSamples);
  });

  test('low-load multipoint stance builds a baseline', () {
    final engine = LocalRiskEngine();
    const leftStanding = [0.006, 0.010, 0.019, 0.005, 0.011, 0.0345];
    const rightStanding = [0.006, 0.004, 0.014, 0.004, 0.010, 0.028];

    LocalRiskResult? result;
    for (var sequence = 0; sequence < 40; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, leftStanding),
        frame('right', sequence, rightStanding),
      ]);
    }

    expect(result!.baselineReady, isTrue);
    expect(result.baselineSamples, LocalRiskEngine.requiredSamples);
  });

  test('low-load floor does not accept single-point residuals', () {
    final engine = LocalRiskEngine();
    const residual = [0.0, 0.0, 0.07, 0.0, 0.0, 0.0];

    LocalRiskResult? result;
    for (var sequence = 0; sequence < 60; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, residual),
        frame('right', sequence, residual),
      ]);
    }

    expect(result!.baselineReady, isFalse);
    expect(result.baselineSamples, 0);
  });

  test('20 Hz empty reference keeps 15 second warmup and 200 ms samples', () {
    final engine = LocalRiskEngine();
    const unloaded = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0];

    LocalRiskResult? result;
    for (var sequence = 0; sequence <= 340; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          unloaded,
          timestampMs: 200000 + sequence * 50,
        ),
        frame(
          'right',
          sequence,
          unloaded,
          timestampMs: 200011 + sequence * 50,
        ),
      ]);
    }
    expect(result!.calibrationStage, 'empty_reference');

    for (var sequence = 341; sequence <= 536; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          unloaded,
          timestampMs: 200000 + sequence * 50,
        ),
        frame(
          'right',
          sequence,
          unloaded,
          timestampMs: 200011 + sequence * 50,
        ),
      ]);
    }
    expect(result!.calibrationStage, 'put_on');
  });

  test(
    'uses timestamps rather than a fixed sample interval for motor timing',
    () {
      final engine = LocalRiskEngine();
      const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];
      for (var sequence = 0; sequence < 40; sequence += 1) {
        engine.evaluate([
          frame(
            'left',
            sequence,
            standing,
            timestampMs: 100000 + sequence * 200,
          ),
          frame(
            'right',
            sequence,
            standing,
            timestampMs: 100017 + sequence * 200,
          ),
        ]);
      }

      const biased = [0.08, 0.08, 0.08, 0.08, 0.12, 0.12];
      LocalRiskResult evaluateAt(
        int offsetMs,
        int sequence, {
        bool moving = false,
      }) =>
          engine.evaluate([
            frame(
              'left',
              sequence,
              biased,
              timestampMs: 200000 + offsetMs,
              imu: ImuData(
                ax: 0,
                ay: 0,
                az: 9.8,
                gx: moving ? 30 : 0,
                gy: 0,
                gz: 0,
              ),
            ),
            frame(
              'right',
              sequence,
              standing,
              timestampMs: 200013 + offsetMs,
              imu: ImuData(
                ax: 0,
                ay: 0,
                az: 9.8,
                gx: moving ? 30 : 0,
                gy: 0,
                gz: 0,
              ),
            ),
          ]);

      evaluateAt(0, 40);
      final warning = evaluateAt(10000, 41);
      expect(warning.risk.riskLevel, 2);
      expect(warning.motorTarget, isNull);

      final movingPersistent = evaluateAt(20000, 42, moving: true);
      expect(movingPersistent.risk.riskLevel, 0);
      expect(movingPersistent.motionState, 'moving');
      expect(movingPersistent.motorTarget, isNull);

      final resumed = evaluateAt(21500, 43);
      expect(resumed.risk.riskLevel, 0);
      expect(resumed.motorTarget, isNull);

      final persistent = evaluateAt(41500, 44);
      expect(persistent.risk.riskLevel, 3);
      expect(persistent.motorTarget, 'left');
      expect(persistent.motorPattern, 'long');

      final repeated = evaluateAt(42000, 45);
      expect(repeated.risk.riskLevel, 3);
      expect(repeated.motorTarget, isNull);
    },
  );

  test(
      'learns four empty temperature offsets and allows unloaded compensated heat',
      () {
    final engine = LocalRiskEngine();
    const emptyLeft = [33.0, 27.2, 30.4, 32.4];
    const emptyRight = [30.0, 30.0, 30.0, 30.0];
    const standing = [0.03, 0.03, 0.03, 0.03, 0.05, 0.05];
    LocalRiskResult? result;
    for (var sequence = 0; sequence < 140; sequence += 1) {
      result = engine.evaluate([
        frame(
            'left',
            sequence,
            const [
              0,
              0,
              0,
              0,
              0,
              0,
            ],
            temperature: emptyLeft),
        frame(
            'right',
            sequence,
            const [
              0,
              0,
              0,
              0,
              0,
              0,
            ],
            temperature: emptyRight),
      ]);
    }
    expect(result!.calibrationStage, 'put_on');

    result = engine.evaluate([
      frame('left', 140, standing, temperature: emptyLeft),
      frame('right', 140, standing, temperature: emptyRight),
    ]);
    expect(result.calibrationStage, 'standing_baseline');
    for (var sequence = 141; sequence < 180; sequence += 1) {
      result = engine.evaluate([
        frame('left', sequence, standing, temperature: emptyLeft),
        frame('right', sequence, standing, temperature: emptyRight),
      ]);
    }
    expect(engine.baselineReady, isTrue);
    expect(result!.calibrationStage, 'complete');

    for (var sequence = 180; sequence <= 255; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          const [0, 0, 0, 0, 0, 0],
          temperature: [36, 24.2, 30.4, 32.4],
        ),
        frame(
            'right',
            sequence,
            const [
              0,
              0,
              0,
              0,
              0,
              0,
            ],
            temperature: emptyRight),
      ]);
    }
    expect(result!.temperatureRiskEnabled, isTrue);
    expect(
      result.activeRisks.any(
        (risk) => risk.riskType == 'temperature_asymmetry',
      ),
      isTrue,
    );
    expect(result.risk.riskLevel, 2);
    expect(result.motorTarget, isNull);

    for (var sequence = 256; sequence <= 330; sequence += 1) {
      result = engine.evaluate([
        frame(
          'left',
          sequence,
          const [0, 0, 0, 0, 0, 0],
          temperature: [36, 24.2, 30.4, 32.4],
        ),
        frame(
          'right',
          sequence,
          const [0, 0, 0, 0, 0, 0],
          temperature: emptyRight,
        ),
      ]);
    }
    expect(result!.risk.riskLevel, 3);
    expect(result.motorTarget, 'both');
    expect(result.motorPattern, 'long');

    result = engine.evaluate([
      frame(
        'left',
        331,
        const [0, 0, 0, 0, 0, 0],
        temperature: [36, 24.2, 30.4, 32.4],
      ),
      frame(
        'right',
        331,
        const [0, 0, 0, 0, 0, 0],
        temperature: emptyRight,
      ),
    ]);
    expect(result.motorTarget, isNull);
  });
}
