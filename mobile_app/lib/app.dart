import 'dart:async';

import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'screens/device_screen.dart';
import 'screens/history_screen.dart';
import 'screens/home_screen.dart';
import 'screens/realtime_screen.dart';
import 'screens/settings_screen.dart';
import 'services/ble_connection_service.dart';

class FootGuardApp extends StatefulWidget {
  const FootGuardApp({super.key});

  @override
  State<FootGuardApp> createState() => _FootGuardAppState();
}

class _FootGuardAppState extends State<FootGuardApp> {
  AppSettings settings = const AppSettings();
  int selectedIndex = 0;
  late final BleConnectionService _bleConnectionService;

  @override
  void initState() {
    super.initState();
    _bleConnectionService = BleConnectionService();
  }

  @override
  void dispose() {
    unawaited(_bleConnectionService.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '足安智垫',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF147D73), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF4F7F7),
        useMaterial3: true,
        cardTheme: const CardThemeData(color: Colors.white),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('FootGuard 足安智垫',
              style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Chip(
                avatar: const Icon(Icons.circle,
                    color: Color(0xFF1A9B78), size: 12),
                label: Text(_modeLabel(settings.dataMode)),
              ),
            ),
          ],
        ),
        body: IndexedStack(
          index: selectedIndex,
          children: [
            HomeScreen(
                onStartMonitoring: () => setState(() => selectedIndex = 1)),
            RealtimeScreen(
              key: ValueKey(
                  '${settings.backendUrl}-${settings.dataMode}-${settings.mockScenario}-${settings.replaySpeed}'),
              settings: settings,
              connectionService: _bleConnectionService,
            ),
            HistoryScreen(
                key: ValueKey(settings.backendUrl),
                backendUrl: settings.backendUrl),
            DeviceScreen(
                key: ValueKey('device-${settings.backendUrl}'),
                backendUrl: settings.backendUrl,
                connectionService: _bleConnectionService),
            SettingsScreen(
              settings: settings,
              onChanged: (next) => setState(() => settings = next),
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
                label: '首页'),
            NavigationDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                selectedIcon: Icon(Icons.monitor_heart),
                label: '实时'),
            NavigationDestination(
                icon: Icon(Icons.history_rounded), label: '历史'),
            NavigationDestination(
                icon: Icon(Icons.devices_other_rounded), label: '设备'),
            NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置'),
          ],
        ),
      ),
    );
  }

  static String _modeLabel(FootDataMode mode) => switch (mode) {
        FootDataMode.mock => 'Mock',
        FootDataMode.csvReplay => 'CSV',
        FootDataMode.backend => 'API',
        FootDataMode.ble => 'BLE',
      };
}
