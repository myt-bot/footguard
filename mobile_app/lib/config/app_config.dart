enum FootDataMode { mock, csvReplay, backend, ble }

const diagnosticReplayEnabled = bool.fromEnvironment(
  'FOOTGUARD_DIAGNOSTIC_REPLAY',
  defaultValue: false,
);

const defaultBackendUrl = String.fromEnvironment(
  'FOOTGUARD_BACKEND_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

bool isValidBackendUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      uri.hasScheme &&
      {'http', 'https'}.contains(uri.scheme) &&
      uri.host.isNotEmpty;
}

String normalizeBackendUrl(String value) =>
    value.trim().replaceFirst(RegExp(r'/$'), '');

class MockScenarioOption {
  const MockScenarioOption({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;
}

class CsvReplayOption {
  const CsvReplayOption({required this.assetPath, required this.label});

  final String assetPath;
  final String label;
}

class AppSettings {
  const AppSettings({
    this.backendUrl = defaultBackendUrl,
    this.dataMode = FootDataMode.ble,
    this.mockScenario = 'normal_stand',
    this.csvAsset = 'assets/sample_data/intervention_recovery.csv',
    this.replaySpeed = 1.0,
    this.voiceEnabled = true,
  });

  final String backendUrl;
  final FootDataMode dataMode;
  final String mockScenario;
  final String csvAsset;
  final double replaySpeed;
  final bool voiceEnabled;

  AppSettings copyWith({
    String? backendUrl,
    FootDataMode? dataMode,
    String? mockScenario,
    String? csvAsset,
    double? replaySpeed,
    bool? voiceEnabled,
  }) {
    return AppSettings(
      backendUrl: backendUrl ?? this.backendUrl,
      dataMode: dataMode ?? this.dataMode,
      mockScenario: mockScenario ?? this.mockScenario,
      csvAsset: csvAsset ?? this.csvAsset,
      replaySpeed: replaySpeed ?? this.replaySpeed,
      voiceEnabled: voiceEnabled ?? this.voiceEnabled,
    );
  }
}

const mockScenarioOptions = <MockScenarioOption>[
  MockScenarioOption(
    id: 'normal_stand',
    label: '正常站立',
    description: '双脚稳定承重，用于学习个人压力与温度基线。',
  ),
  MockScenarioOption(
    id: 'normal_walk',
    label: '正常行走',
    description: '左右脚载荷周期变化，用于观察行走时的实时曲线。',
  ),
  MockScenarioOption(
    id: 'left_load_bias',
    label: '左脚持续偏载',
    description: '左脚总负荷持续高于右脚，演示偏载风险升级。',
  ),
  MockScenarioOption(
    id: 'right_load_bias',
    label: '右脚持续偏载',
    description: '右脚总负荷持续高于左脚，演示偏载风险升级。',
  ),
  MockScenarioOption(
    id: 'left_forefoot_high',
    label: '左脚前掌高压',
    description: '左脚前掌压力占比持续升高，演示前掌高压风险。',
  ),
  MockScenarioOption(
    id: 'right_forefoot_high',
    label: '右脚前掌高压',
    description: '右脚前掌压力占比持续升高，演示前掌高压风险。',
  ),
  MockScenarioOption(
    id: 'left_temperature_rise',
    label: '左脚局部升温',
    description: '左脚 T2 相对右脚持续升温，演示同区温差风险。',
  ),
  MockScenarioOption(
    id: 'right_temperature_rise',
    label: '右脚局部升温',
    description: '右脚 T2 相对左脚持续升温，演示同区温差风险。',
  ),
  MockScenarioOption(
    id: 'left_disconnect',
    label: '左脚连接中断',
    description: '运行约 8 秒后停止左脚数据，演示单侧掉线处理。',
  ),
  MockScenarioOption(
    id: 'right_disconnect',
    label: '右脚连接中断',
    description: '运行约 8 秒后停止右脚数据，演示单侧掉线处理。',
  ),
];

final mockScenarios = List<String>.unmodifiable(
  mockScenarioOptions.map((option) => option.id),
);

const csvReplayOptions = <CsvReplayOption>[
  CsvReplayOption(
    assetPath: 'assets/sample_data/intervention_recovery.csv',
    label: '提醒前后恢复演示',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/normal_stand.csv',
    label: '正常站立',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/normal_walk.csv',
    label: '正常行走',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/left_load_bias.csv',
    label: '左脚持续偏载',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/right_load_bias.csv',
    label: '右脚持续偏载',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/left_forefoot_high.csv',
    label: '左脚前掌高压',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/left_temperature_rise.csv',
    label: '左脚局部升温',
  ),
  CsvReplayOption(
    assetPath: 'assets/sample_data/right_disconnect.csv',
    label: '右脚连接中断',
  ),
];

MockScenarioOption mockScenarioOption(String id) =>
    mockScenarioOptions.firstWhere(
      (option) => option.id == id,
      orElse: () => mockScenarioOptions.first,
    );

String mockScenarioLabel(String id) => mockScenarioOption(id).label;
