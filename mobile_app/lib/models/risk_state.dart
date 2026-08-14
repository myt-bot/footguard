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

  Map<String, dynamic> toJson() => {
        'risk_type': riskType,
        'risk_side': riskSide,
        'risk_level': riskLevel,
        'duration_ms': durationMs,
      };

  bool get isNormal => riskType == 'normal';
  bool get isIncomplete => riskType == 'data_incomplete';
  bool get isTemperature => riskType == 'temperature_asymmetry';
  bool get isPressure => !isNormal && !isIncomplete && !isTemperature;
}

int pressureRiskPriority(String riskType) => switch (riskType) {
      'forefoot_high' ||
      'medial_load_concentration' ||
      'lateral_load_concentration' =>
        3,
      'left_load_bias' || 'right_load_bias' => 2,
      _ => 1,
    };

String riskDisplayLabel(String riskType, String side) {
  final sideLabel = switch (side) {
    'left' => '左脚',
    'right' => '右脚',
    'both' => '双脚',
    _ => '',
  };
  return switch (riskType) {
    'left_load_bias' => '左侧负载持续偏高',
    'right_load_bias' => '右侧负载持续偏高',
    'forefoot_high' => '$sideLabel前掌负荷持续集中',
    'medial_load_concentration' => '$sideLabel内侧局部负荷集中',
    'lateral_load_concentration' => '$sideLabel外侧局部负荷集中',
    'temperature_asymmetry' => '$sideLabel同区温度趋势异常',
    'normal' => '正常',
    'data_incomplete' => '数据不完整',
    _ => '$sideLabel区域负荷集中',
  };
}
