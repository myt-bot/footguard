class RegionalAnalysis {
  const RegionalAnalysis({
    required this.baselineReady,
    required this.baselineSource,
    required this.leftPressureScores,
    required this.rightPressureScores,
    required this.temperatureDeltaC,
    required this.leftTemperatureScores,
    required this.rightTemperatureScores,
  });

  final bool baselineReady;
  final String baselineSource;
  final List<double> leftPressureScores;
  final List<double> rightPressureScores;
  final List<double> temperatureDeltaC;
  final List<double> leftTemperatureScores;
  final List<double> rightTemperatureScores;

  static List<double> _values(dynamic raw, int length, String field) {
    if (raw is! List ||
        raw.length != length ||
        raw.any((value) => value is! num)) {
      throw FormatException('$field must contain $length numeric values');
    }
    return raw
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
  }

  factory RegionalAnalysis.fromJson(Map<String, dynamic> json) {
    return RegionalAnalysis(
      baselineReady: json['baseline_ready'] as bool,
      baselineSource: json['baseline_source'] as String,
      leftPressureScores:
          _values(json['left_pressure_scores'], 6, 'left_pressure_scores'),
      rightPressureScores:
          _values(json['right_pressure_scores'], 6, 'right_pressure_scores'),
      temperatureDeltaC:
          _values(json['temperature_delta_c'], 4, 'temperature_delta_c'),
      leftTemperatureScores: _values(
          json['left_temperature_scores'], 4, 'left_temperature_scores'),
      rightTemperatureScores: _values(
        json['right_temperature_scores'],
        4,
        'right_temperature_scores',
      ),
    );
  }
}
