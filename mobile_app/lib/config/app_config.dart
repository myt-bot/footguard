enum FootDataMode { mock, csvReplay, backend, ble }

class AppSettings {
  const AppSettings({
    this.backendUrl = 'http://10.0.2.2:8000',
    this.dataMode = FootDataMode.mock,
    this.mockScenario = 'normal_stand',
    this.csvAsset = 'assets/sample_data/intervention_recovery.csv',
    this.replaySpeed = 1.0,
  });

  final String backendUrl;
  final FootDataMode dataMode;
  final String mockScenario;
  final String csvAsset;
  final double replaySpeed;

  AppSettings copyWith({
    String? backendUrl,
    FootDataMode? dataMode,
    String? mockScenario,
    String? csvAsset,
    double? replaySpeed,
  }) {
    return AppSettings(
      backendUrl: backendUrl ?? this.backendUrl,
      dataMode: dataMode ?? this.dataMode,
      mockScenario: mockScenario ?? this.mockScenario,
      csvAsset: csvAsset ?? this.csvAsset,
      replaySpeed: replaySpeed ?? this.replaySpeed,
    );
  }
}

const mockScenarios = <String>[
  'normal_stand',
  'normal_walk',
  'left_load_bias',
  'right_load_bias',
  'left_forefoot_high',
  'left_temperature_rise',
  'right_disconnect',
];
