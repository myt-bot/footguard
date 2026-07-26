import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';

void main() {
  test('realtime snapshot parses MPU activity state', () {
    final snapshot = RealtimeSnapshot.fromJson({
      'left': null,
      'right': null,
      'load_bias': null,
      'load_diff': null,
      'sync_error_ms': null,
      'activity_state': 'moving',
      'motion_score': 1.42,
      'risk': {
        'risk_type': 'data_incomplete',
        'risk_side': 'none',
        'risk_level': 0,
        'duration_ms': 0,
      },
      'regional_analysis': null,
    });

    expect(snapshot.activityState, 'moving');
    expect(snapshot.motionScore, 1.42);
  });

  test('older backend response degrades to unknown activity', () {
    final snapshot = RealtimeSnapshot.fromJson({
      'left': null,
      'right': null,
      'load_bias': null,
      'load_diff': null,
      'sync_error_ms': null,
      'risk': {
        'risk_type': 'data_incomplete',
        'risk_side': 'none',
        'risk_level': 0,
        'duration_ms': 0,
      },
      'regional_analysis': null,
    });

    expect(snapshot.activityState, 'unknown');
    expect(snapshot.motionScore, 0.0);
  });
}
