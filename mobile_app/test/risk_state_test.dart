import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/risk_state.dart';

void main() {
  test('risk speech uses the exact risk name and side', () {
    const cases = [
      (
        RiskState(
          riskType: 'left_load_bias',
          riskSide: 'left',
          riskLevel: 2,
          durationMs: 10000,
        ),
        '检测到左侧负载持续偏高，请调整受力并减负',
      ),
      (
        RiskState(
          riskType: 'forefoot_high',
          riskSide: 'right',
          riskLevel: 2,
          durationMs: 10000,
        ),
        '检测到右脚前掌负荷持续集中，请调整受力并减负',
      ),
      (
        RiskState(
          riskType: 'medial_load_concentration',
          riskSide: 'left',
          riskLevel: 2,
          durationMs: 10000,
        ),
        '检测到左脚内侧局部负荷集中，请调整受力并减负',
      ),
      (
        RiskState(
          riskType: 'lateral_load_concentration',
          riskSide: 'right',
          riskLevel: 2,
          durationMs: 10000,
        ),
        '检测到右脚外侧局部负荷集中，请调整受力并减负',
      ),
      (
        RiskState(
          riskType: 'temperature_asymmetry',
          riskSide: 'right',
          riskLevel: 2,
          durationMs: 15000,
        ),
        '右脚同区温度趋势异常，请检查足部并继续观察',
      ),
    ];

    for (final (risk, expected) in cases) {
      expect(riskVoiceMessage(risk), expected);
    }
  });
}
