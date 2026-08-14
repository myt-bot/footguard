import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/risk_state.dart';
import 'package:footguard/services/risk_speech_coordinator.dart';

const leftBias = RiskState(
  riskType: 'left_load_bias',
  riskSide: 'left',
  riskLevel: 2,
  durationMs: 10000,
);
const rightForefoot = RiskState(
  riskType: 'forefoot_high',
  riskSide: 'right',
  riskLevel: 2,
  durationMs: 10000,
);

void main() {
  test('returns every new risk in the same poll and does not repeat it', () {
    final coordinator = RiskSpeechCoordinator();

    expect(coordinator.takeNew([leftBias, rightForefoot], 1000), [
      leftBias,
      rightForefoot,
    ]);
    expect(coordinator.takeNew([leftBias, rightForefoot], 2000), isEmpty);
  });

  test('a new risk is returned while an existing risk continues', () {
    final coordinator = RiskSpeechCoordinator();

    expect(coordinator.takeNew([leftBias], 1000), [leftBias]);
    expect(coordinator.takeNew([leftBias, rightForefoot], 2000), [
      rightForefoot,
    ]);
  });

  test('each risk needs five continuous missing seconds to rearm', () {
    final coordinator = RiskSpeechCoordinator();

    expect(coordinator.takeNew([leftBias], 1000), [leftBias]);
    expect(coordinator.takeNew([], 2000), isEmpty);
    expect(coordinator.takeNew([leftBias], 6000), isEmpty);
    expect(coordinator.takeNew([], 7000), isEmpty);
    expect(coordinator.takeNew([], 12000), isEmpty);
    expect(coordinator.takeNew([leftBias], 12001), [leftBias]);
  });
}
