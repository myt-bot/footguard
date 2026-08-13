class RegionalAnalysis {
  const RegionalAnalysis({
    required this.baselineReady,
    required this.baselineSource,
    this.baselineSampleCount = 0,
    this.baselineRequiredSamples = 40,
    this.pressureAvailable = false,
    this.leftPressureValid = const [true, true, true, true, true, true],
    this.rightPressureValid = const [true, true, true, true, true, true],
    this.leftPressureBaselineTrusted = const [
      true,
      true,
      true,
      true,
      true,
      true
    ],
    this.rightPressureBaselineTrusted = const [
      true,
      true,
      true,
      true,
      true,
      true
    ],
    this.leftPressureAnalysisValid = const [true, true, true, true, true, true],
    this.rightPressureAnalysisValid = const [
      true,
      true,
      true,
      true,
      true,
      true
    ],
    this.leftPressureChannelStatus = const ['ok', 'ok', 'ok', 'ok', 'ok', 'ok'],
    this.rightPressureChannelStatus = const [
      'ok',
      'ok',
      'ok',
      'ok',
      'ok',
      'ok'
    ],
    this.temperatureAvailable = false,
    this.leftTemperatureValid = const [true, true, true, true],
    this.rightTemperatureValid = const [true, true, true, true],
    required this.leftPressureScores,
    required this.rightPressureScores,
    required this.temperatureDeltaC,
    required this.leftTemperatureScores,
    required this.rightTemperatureScores,
  });

  final bool baselineReady;
  final String baselineSource;
  final int baselineSampleCount;
  final int baselineRequiredSamples;
  final bool pressureAvailable;
  final List<bool> leftPressureValid;
  final List<bool> rightPressureValid;
  final List<bool> leftPressureBaselineTrusted;
  final List<bool> rightPressureBaselineTrusted;
  final List<bool> leftPressureAnalysisValid;
  final List<bool> rightPressureAnalysisValid;
  final List<String> leftPressureChannelStatus;
  final List<String> rightPressureChannelStatus;
  final bool temperatureAvailable;
  final List<bool> leftTemperatureValid;
  final List<bool> rightTemperatureValid;
  final List<double> leftPressureScores;
  final List<double> rightPressureScores;
  final List<double?> temperatureDeltaC;
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

  static List<double?> _nullableValues(dynamic raw, int length, String field) {
    if (raw is! List ||
        raw.length != length ||
        raw.any((value) => value != null && value is! num)) {
      throw FormatException('$field must contain $length numeric/null values');
    }
    return raw
        .map((value) => value == null ? null : (value as num).toDouble())
        .toList(growable: false);
  }

  static List<bool> _flags(dynamic raw, int length, bool fallback) {
    if (raw is! List ||
        raw.length != length ||
        raw.any((value) => value is! bool)) {
      return List.filled(length, fallback);
    }
    return raw.cast<bool>().toList(growable: false);
  }

  static List<String> _statuses(dynamic raw, int length) {
    if (raw is! List ||
        raw.length != length ||
        raw.any((value) => value is! String)) {
      return List.filled(length, 'ok');
    }
    return raw.cast<String>().toList(growable: false);
  }

  factory RegionalAnalysis.fromJson(Map<String, dynamic> json) {
    return RegionalAnalysis(
      baselineReady: json['baseline_ready'] as bool,
      baselineSource: json['baseline_source'] as String,
      baselineSampleCount: json['baseline_sample_count'] as int? ?? 0,
      baselineRequiredSamples: json['baseline_required_samples'] as int? ?? 40,
      pressureAvailable: json['pressure_available'] as bool? ?? true,
      leftPressureValid: _flags(json['left_pressure_valid'], 6, true),
      rightPressureValid: _flags(json['right_pressure_valid'], 6, true),
      leftPressureBaselineTrusted:
          _flags(json['left_pressure_baseline_trusted'], 6, true),
      rightPressureBaselineTrusted:
          _flags(json['right_pressure_baseline_trusted'], 6, true),
      leftPressureAnalysisValid:
          _flags(json['left_pressure_analysis_valid'], 6, true),
      rightPressureAnalysisValid:
          _flags(json['right_pressure_analysis_valid'], 6, true),
      leftPressureChannelStatus:
          _statuses(json['left_pressure_channel_status'], 6),
      rightPressureChannelStatus:
          _statuses(json['right_pressure_channel_status'], 6),
      temperatureAvailable: json['temperature_available'] as bool? ?? true,
      leftTemperatureValid: _flags(json['left_temperature_valid'], 4, true),
      rightTemperatureValid: _flags(json['right_temperature_valid'], 4, true),
      leftPressureScores:
          _values(json['left_pressure_scores'], 6, 'left_pressure_scores'),
      rightPressureScores:
          _values(json['right_pressure_scores'], 6, 'right_pressure_scores'),
      temperatureDeltaC: _nullableValues(
          json['temperature_delta_c'], 4, 'temperature_delta_c'),
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
