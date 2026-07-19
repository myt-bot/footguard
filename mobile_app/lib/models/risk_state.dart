class RiskState {
  const RiskState({
    required this.riskType,
    required this.riskSide,
    required this.riskLevel,
    required this.durationMs,
  });

  const RiskState.incomplete()
      : riskType = 'data_incomplete',
        riskSide = 'none',
        riskLevel = 0,
        durationMs = 0;

  final String riskType;
  final String riskSide;
  final int riskLevel;
  final int durationMs;

  factory RiskState.fromJson(Map<String, dynamic> json) => RiskState(
        riskType: json['risk_type'] as String,
        riskSide: json['risk_side'] as String,
        riskLevel: json['risk_level'] as int,
        durationMs: json['duration_ms'] as int,
      );

  bool get isNormal => riskType == 'normal';
  bool get isIncomplete => riskType == 'data_incomplete';
}
