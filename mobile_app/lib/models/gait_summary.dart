class GaitSummary {
  const GaitSummary({
    required this.state,
    required this.windowMs,
    required this.stepCount,
    required this.leftSteps,
    required this.rightSteps,
    this.cadenceSpm,
    this.lastCompletedEpisode,
  });

  const GaitSummary.insufficient()
      : state = 'insufficient_data',
        windowMs = 0,
        stepCount = 0,
        leftSteps = 0,
        rightSteps = 0,
        cadenceSpm = null,
        lastCompletedEpisode = null;

  final String state;
  final int windowMs;
  final int stepCount;
  final int leftSteps;
  final int rightSteps;
  final double? cadenceSpm;
  final GaitEpisodeSummary? lastCompletedEpisode;

  factory GaitSummary.fromJson(Map<String, dynamic> json) => GaitSummary(
        state: json['state'] as String? ?? 'insufficient_data',
        windowMs: json['window_ms'] as int? ?? 0,
        stepCount: json['step_count'] as int? ?? 0,
        leftSteps: json['left_steps'] as int? ?? 0,
        rightSteps: json['right_steps'] as int? ?? 0,
        cadenceSpm: (json['cadence_spm'] as num?)?.toDouble(),
        lastCompletedEpisode: json['last_completed_episode'] == null
            ? null
            : GaitEpisodeSummary.fromJson(
                json['last_completed_episode'] as Map<String, dynamic>,
              ),
      );

  Map<String, dynamic> toJson() => {
        'state': state,
        'window_ms': windowMs,
        'step_count': stepCount,
        'left_steps': leftSteps,
        'right_steps': rightSteps,
        'cadence_spm': cadenceSpm,
        'last_completed_episode': lastCompletedEpisode?.toJson(),
      };
}

class GaitIssue {
  const GaitIssue({
    required this.issueType,
    required this.side,
    required this.value,
    required this.threshold,
  });

  final String issueType;
  final String side;
  final double value;
  final double threshold;

  factory GaitIssue.fromJson(Map<String, dynamic> json) => GaitIssue(
        issueType: json['issue_type'] as String,
        side: json['side'] as String,
        value: (json['value'] as num).toDouble(),
        threshold: (json['threshold'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'issue_type': issueType,
        'side': side,
        'value': value,
        'threshold': threshold,
      };
}

class GaitEpisodeSummary {
  const GaitEpisodeSummary({
    required this.episodeId,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.durationMs,
    required this.stepCount,
    required this.leftSteps,
    required this.rightSteps,
    required this.cadenceSpm,
    required this.stepIntervalCv,
    required this.leftLoadIndex,
    required this.rightLoadIndex,
    required this.loadAsymmetry,
    required this.leftForefootRatio,
    required this.rightForefootRatio,
    required this.leftMedialRatio,
    required this.rightMedialRatio,
    required this.leftLateralRatio,
    required this.rightLateralRatio,
    this.issues = const [],
  });

  final String episodeId;
  final int startedAtMs;
  final int endedAtMs;
  final int durationMs;
  final int stepCount;
  final int leftSteps;
  final int rightSteps;
  final double cadenceSpm;
  final double stepIntervalCv;
  final double leftLoadIndex;
  final double rightLoadIndex;
  final double loadAsymmetry;
  final double leftForefootRatio;
  final double rightForefootRatio;
  final double leftMedialRatio;
  final double rightMedialRatio;
  final double leftLateralRatio;
  final double rightLateralRatio;
  final List<GaitIssue> issues;

  factory GaitEpisodeSummary.fromJson(Map<String, dynamic> json) =>
      GaitEpisodeSummary(
        episodeId: json['episode_id'] as String,
        startedAtMs: json['started_at_ms'] as int,
        endedAtMs: json['ended_at_ms'] as int,
        durationMs: json['duration_ms'] as int,
        stepCount: json['step_count'] as int,
        leftSteps: json['left_steps'] as int,
        rightSteps: json['right_steps'] as int,
        cadenceSpm: (json['cadence_spm'] as num).toDouble(),
        stepIntervalCv: (json['step_interval_cv'] as num).toDouble(),
        leftLoadIndex: (json['left_load_index'] as num).toDouble(),
        rightLoadIndex: (json['right_load_index'] as num).toDouble(),
        loadAsymmetry: (json['load_asymmetry'] as num).toDouble(),
        leftForefootRatio: (json['left_forefoot_ratio'] as num).toDouble(),
        rightForefootRatio: (json['right_forefoot_ratio'] as num).toDouble(),
        leftMedialRatio: (json['left_medial_ratio'] as num).toDouble(),
        rightMedialRatio: (json['right_medial_ratio'] as num).toDouble(),
        leftLateralRatio: (json['left_lateral_ratio'] as num).toDouble(),
        rightLateralRatio: (json['right_lateral_ratio'] as num).toDouble(),
        issues: (json['issues'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(GaitIssue.fromJson)
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
        'episode_id': episodeId,
        'started_at_ms': startedAtMs,
        'ended_at_ms': endedAtMs,
        'duration_ms': durationMs,
        'step_count': stepCount,
        'left_steps': leftSteps,
        'right_steps': rightSteps,
        'cadence_spm': cadenceSpm,
        'step_interval_cv': stepIntervalCv,
        'left_load_index': leftLoadIndex,
        'right_load_index': rightLoadIndex,
        'load_asymmetry': loadAsymmetry,
        'left_forefoot_ratio': leftForefootRatio,
        'right_forefoot_ratio': rightForefootRatio,
        'left_medial_ratio': leftMedialRatio,
        'right_medial_ratio': rightMedialRatio,
        'left_lateral_ratio': leftLateralRatio,
        'right_lateral_ratio': rightLateralRatio,
        'issues': issues.map((item) => item.toJson()).toList(),
      };
}
