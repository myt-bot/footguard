import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

abstract interface class AppSettingsStore {
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);
}

class SharedPreferencesAppSettingsStore implements AppSettingsStore {
  const SharedPreferencesAppSettingsStore();

  static const _backendUrlKey = 'settings.backend_url';
  static const _dataModeKey = 'settings.data_mode';
  static const _mockScenarioKey = 'settings.mock_scenario';
  static const _csvAssetKey = 'settings.csv_asset';
  static const _replaySpeedKey = 'settings.replay_speed';

  @override
  Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    const defaults = AppSettings();

    final savedBackendUrl = preferences.getString(_backendUrlKey)?.trim();
    final savedMode = preferences.getString(_dataModeKey);
    final savedScenario = preferences.getString(_mockScenarioKey);
    final savedCsvAsset = preferences.getString(_csvAssetKey)?.trim();
    final savedReplaySpeed = preferences.getDouble(_replaySpeedKey);

    return AppSettings(
      backendUrl: savedBackendUrl == null || savedBackendUrl.isEmpty
          ? defaults.backendUrl
          : savedBackendUrl,
      dataMode: _parseDataMode(savedMode) ?? defaults.dataMode,
      mockScenario:
          savedScenario != null && mockScenarios.contains(savedScenario)
              ? savedScenario
              : defaults.mockScenario,
      csvAsset: savedCsvAsset == null || savedCsvAsset.isEmpty
          ? defaults.csvAsset
          : savedCsvAsset,
      replaySpeed: savedReplaySpeed == null
          ? defaults.replaySpeed
          : savedReplaySpeed.clamp(0.5, 4.0).toDouble(),
    );
  }

  @override
  Future<void> save(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setString(_backendUrlKey, settings.backendUrl),
      preferences.setString(_dataModeKey, settings.dataMode.name),
      preferences.setString(_mockScenarioKey, settings.mockScenario),
      preferences.setString(_csvAssetKey, settings.csvAsset),
      preferences.setDouble(_replaySpeedKey, settings.replaySpeed),
    ]);
  }

  static FootDataMode? _parseDataMode(String? name) {
    for (final mode in FootDataMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return null;
  }
}
