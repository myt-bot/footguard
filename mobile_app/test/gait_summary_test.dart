import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/gait_summary.dart';

void main() {
  test('parses a walking gait summary from the backend', () {
    final gait = GaitSummary.fromJson({
      'state': 'walking',
      'window_ms': 12000,
      'step_count': 8,
      'left_steps': 4,
      'right_steps': 4,
      'cadence_spm': 69.0,
    });

    expect(gait.state, 'walking');
    expect(gait.stepCount, 8);
    expect(gait.leftSteps, 4);
    expect(gait.rightSteps, 4);
    expect(gait.cadenceSpm, 69.0);
  });
}
