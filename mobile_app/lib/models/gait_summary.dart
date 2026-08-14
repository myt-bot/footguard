class GaitSummary {
  const GaitSummary({
    required this.state,
    required this.windowMs,
    required this.stepCount,
    required this.leftSteps,
    required this.rightSteps,
    this.cadenceSpm,
  });

  const GaitSummary.insufficient()
      : state = 'insufficient_data',
        windowMs = 0,
        stepCount = 0,
        leftSteps = 0,
        rightSteps = 0,
        cadenceSpm = null;

  final String state;
  final int windowMs;
  final int stepCount;
  final int leftSteps;
  final int rightSteps;
  final double? cadenceSpm;

  factory GaitSummary.fromJson(Map<String, dynamic> json) => GaitSummary(
        state: json['state'] as String? ?? 'insufficient_data',
        windowMs: json['window_ms'] as int? ?? 0,
        stepCount: json['step_count'] as int? ?? 0,
        leftSteps: json['left_steps'] as int? ?? 0,
        rightSteps: json['right_steps'] as int? ?? 0,
        cadenceSpm: (json['cadence_spm'] as num?)?.toDouble(),
      );
}
