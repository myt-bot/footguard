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

  test('parses the latest completed gait episode while stationary', () {
    final gait = GaitSummary.fromJson({
      'state': 'stationary',
      'window_ms': 12000,
      'step_count': 0,
      'left_steps': 0,
      'right_steps': 0,
      'last_completed_episode': {
        'episode_id': 'gait_7_1000_7000',
        'started_at_ms': 1000,
        'ended_at_ms': 7000,
        'duration_ms': 6000,
        'step_count': 8,
        'left_steps': 4,
        'right_steps': 4,
        'cadence_spm': 80.0,
        'step_interval_cv': 0.12,
        'left_load_index': 0.4,
        'right_load_index': 0.3,
        'load_asymmetry': 0.143,
        'left_forefoot_ratio': 0.55,
        'right_forefoot_ratio': 0.52,
        'left_medial_ratio': 0.30,
        'right_medial_ratio': 0.28,
        'left_lateral_ratio': 0.18,
        'right_lateral_ratio': 0.20,
        'issues': [
          {
            'issue_type': 'walking_load_asymmetry',
            'side': 'left',
            'value': 0.3,
            'threshold': 0.25,
          },
        ],
      },
    });

    expect(gait.state, 'stationary');
    expect(gait.lastCompletedEpisode?.stepCount, 8);
    expect(gait.lastCompletedEpisode?.issues.single.side, 'left');
  });
}
