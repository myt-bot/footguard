import 'dart:async';

import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'data/api_client.dart';
import 'screens/device_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/realtime_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_settings_store.dart';
import 'services/ble_connection_service.dart';
import 'services/calibration_speech_coordinator.dart';
import 'services/local_tts_service.dart';

class FootGuardApp extends StatefulWidget {
  const FootGuardApp({super.key, this.settingsStore});

  final AppSettingsStore? settingsStore;

  @override
  State<FootGuardApp> createState() => _FootGuardAppState();
}

class _FootGuardAppState extends State<FootGuardApp> {
  AppSettings settings = const AppSettings();
  int selectedIndex = 0;
  int _calibrationEpoch = 0;
  late final BleConnectionService _bleConnectionService;
  late final AppSettingsStore _settingsStore;
  late final TtsSpeaker _ttsSpeaker;
  final CalibrationSpeechCoordinator _calibrationSpeech =
      CalibrationSpeechCoordinator();

  @override
  void initState() {
    super.initState();
    _bleConnectionService = BleConnectionService(
      unixTimeProvider: _backendUnixTimeMs,
    );
    _ttsSpeaker = AndroidTtsService();
    _settingsStore =
        widget.settingsStore ?? const SharedPreferencesAppSettingsStore();
    unawaited(_restoreSettings());
  }

  Future<void> _restoreSettings() async {
    try {
      final restored = await _settingsStore.load();
      if (mounted) {
        setState(() => settings = restored);
        unawaited(_synchronizeConnectedDeviceClocks());
      }
    } catch (_) {
      // Keep safe defaults when local storage is temporarily unavailable.
    }
  }

  void _applySettings(AppSettings next) {
    setState(() => settings = next);
    unawaited(_saveSettings(next));
    unawaited(_synchronizeConnectedDeviceClocks());
  }

  void _handleCalibrationReset() {
    unawaited(_ttsSpeaker.stop());
    _calibrationSpeech.start();
    setState(() {
      _calibrationEpoch += 1;
      selectedIndex = 1;
    });
  }

  Future<int> _backendUnixTimeMs() async {
    final api = FootGuardApiClient(baseUrl: settings.backendUrl);
    try {
      try {
        return await api.serverTimeMs(refresh: true);
      } catch (_) {
        // Phone UTC keeps BLE frame durations usable in App-local mode when
        // the computer backend is unavailable before the shoes connect.
        return DateTime.now().millisecondsSinceEpoch;
      }
    } finally {
      api.close();
    }
  }

  Future<void> _synchronizeConnectedDeviceClocks() async {
    try {
      await _bleConnectionService.synchronizeConnectedClocks();
    } catch (_) {
      // A later connection or command retries time sync when the backend returns.
    }
  }

  Future<void> _saveSettings(AppSettings next) async {
    try {
      await _settingsStore.save(next);
    } catch (_) {
      // The settings are still applied for this session.
    }
  }

  @override
  void dispose() {
    unawaited(_bleConnectionService.dispose());
    unawaited(_ttsSpeaker.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '足安智垫',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF147D73),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F7F7),
        useMaterial3: true,
        cardTheme: const CardThemeData(color: Colors.white),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text(
            'FootGuard 足安智垫',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Chip(
                avatar: const Icon(
                  Icons.circle,
                  color: Color(0xFF1A9B78),
                  size: 12,
                ),
                label: Text(_modeLabel(settings.dataMode)),
              ),
            ),
          ],
        ),
        body: IndexedStack(
          index: selectedIndex,
          children: [
            HomeScreen(
              onStartMonitoring: () => setState(() => selectedIndex = 1),
            ),
            RealtimeScreen(
              key: ValueKey(
                '${settings.backendUrl}-${settings.dataMode}-${settings.mockScenario}-${settings.csvAsset}-${settings.replaySpeed}-$_calibrationEpoch',
              ),
              settings: settings,
              connectionService: _bleConnectionService,
              ttsSpeaker: _ttsSpeaker,
              calibrationSpeech: _calibrationSpeech,
            ),
            HistoryScreen(
              key: ValueKey(settings.backendUrl),
              backendUrl: settings.backendUrl,
            ),
            DeviceScreen(
              key: ValueKey('device-${settings.backendUrl}'),
              backendUrl: settings.backendUrl,
              connectionService: _bleConnectionService,
            ),
            SettingsScreen(
              settings: settings,
              onChanged: _applySettings,
              onCalibrationReset: _handleCalibrationReset,
              ttsSpeaker: _ttsSpeaker,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (index) =>
              setState(() => selectedIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.monitor_heart_outlined),
              selectedIcon: Icon(Icons.monitor_heart),
              label: '实时',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_rounded),
              label: '历史',
            ),
            NavigationDestination(
              icon: Icon(Icons.devices_other_rounded),
              label: '设备',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }

  static String _modeLabel(FootDataMode mode) => switch (mode) {
        FootDataMode.mock => '模拟',
        FootDataMode.csvReplay => 'CSV',
        FootDataMode.backend => '后端',
        FootDataMode.ble => 'BLE',
      };
}
