import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/gait_summary.dart';
import 'package:footguard/services/monitoring_controller.dart';

void main() {
  GaitSummary summary(List<GaitIssue> issues) => GaitSummary(
        state: 'stationary',
        windowMs: 12000,
        stepCount: 0,
        leftSteps: 0,
        rightSteps: 0,
        lastCompletedEpisode: GaitEpisodeSummary(
          episodeId: 'gait_7_1000',
          startedAtMs: 1000,
          endedAtMs: 6000,
          durationMs: 5000,
          stepCount: 6,
          leftSteps: 3,
          rightSteps: 3,
          cadenceSpm: 72,
          stepIntervalCv: 0.2,
          leftLoadIndex: 1.4,
          rightLoadIndex: 0.7,
          loadAsymmetry: 0.33,
          leftForefootRatio: 0.6,
          rightForefootRatio: 0.5,
          leftMedialRatio: 0.4,
          rightMedialRatio: 0.4,
          leftLateralRatio: 0.2,
          rightLateralRatio: 0.2,
          issues: issues,
        ),
      );

  test('one recent primary gait issue produces a voice notice', () {
    final notice = gaitEpisodeNotice(
      summary(const [
        GaitIssue(
          issueType: 'walking_load_asymmetry',
          side: 'left',
          value: 0.33,
          threshold: 0.30,
        ),
      ]),
      latestTimestampMs: 8500,
    );

    expect(notice, contains('本段行走检测到左脚行走负荷持续偏高'));
  });

  test('engineering-only metrics and stale episodes stay silent', () {
    final engineeringOnly = summary(const [
      GaitIssue(
        issueType: 'step_timing_instability',
        side: 'none',
        value: 0.4,
        threshold: 0.25,
      ),
    ]);

    expect(
      gaitEpisodeNotice(engineeringOnly, latestTimestampMs: 8500),
      isNull,
    );
    expect(
      gaitEpisodeNotice(
        summary(const [
          GaitIssue(
            issueType: 'walking_forefoot_concentration',
            side: 'right',
            value: 0.18,
            threshold: 0.15,
          ),
        ]),
        latestTimestampMs: 20000,
      ),
      isNull,
    );
  });
}
