import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/config/app_config.dart';
import 'package:footguard/services/app_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('returns safe defaults when no settings were saved', () async {
    const store = SharedPreferencesAppSettingsStore();

    final settings = await store.load();

    expect(settings.backendUrl, 'http://10.0.2.2:8000');
    expect(settings.dataMode, FootDataMode.mock);
    expect(settings.mockScenario, 'normal_stand');
    expect(settings.replaySpeed, 1.0);
  });

  test('saves and restores all configurable settings', () async {
    const store = SharedPreferencesAppSettingsStore();
    const expected = AppSettings(
      backendUrl: 'http://172.20.10.2:8000',
      dataMode: FootDataMode.ble,
      mockScenario: 'left_load_bias',
      csvAsset: 'assets/sample_data/normal_walk.csv',
      replaySpeed: 2.5,
    );

    await store.save(expected);
    final restored = await store.load();

    expect(restored.backendUrl, expected.backendUrl);
    expect(restored.dataMode, expected.dataMode);
    expect(restored.mockScenario, expected.mockScenario);
    expect(restored.csvAsset, expected.csvAsset);
    expect(restored.replaySpeed, expected.replaySpeed);
  });

  test('rejects invalid saved enum, scenario, and replay speed', () async {
    SharedPreferences.setMockInitialValues({
      'settings.backend_url': '',
      'settings.data_mode': 'invalid',
      'settings.mock_scenario': 'invalid',
      'settings.csv_asset': '',
      'settings.replay_speed': 99.0,
    });
    const store = SharedPreferencesAppSettingsStore();

    final restored = await store.load();

    expect(restored.backendUrl, const AppSettings().backendUrl);
    expect(restored.dataMode, FootDataMode.mock);
    expect(restored.mockScenario, 'normal_stand');
    expect(restored.csvAsset, const AppSettings().csvAsset);
    expect(restored.replaySpeed, 4.0);
  });
}
