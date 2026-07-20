import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/screens/device_screen.dart';
import 'package:footguard/services/ble_scanner_service.dart';

class _FakeScanner extends BleScannerService {
  final _snapshots = StreamController<BleScanSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  BleScanSnapshot _current = const BleScanSnapshot.empty();
  bool stopCalled = false;

  @override
  Stream<BleScanSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<String?> get errors => _errors.stream;
  @override
  BleScanSnapshot get current => _current;

  @override
  Future<void> startScan() async {
    _current = const BleScanSnapshot(isScanning: true);
    _snapshots.add(_current);
  }

  void emit(BleScanSnapshot value) {
    _current = value;
    _snapshots.add(value);
  }

  @override
  Future<void> stopScan({bool clearResults = false}) async {
    stopCalled = true;
    _current = BleScanSnapshot(
      isScanning: false,
      left: clearResults ? null : _current.left,
      right: clearResults ? null : _current.right,
    );
    _snapshots.add(_current);
  }

  @override
  Future<void> dispose() async {
    await _snapshots.close();
    await _errors.close();
  }
}

void main() {
  testWidgets('device page starts scanning and shows a discovered left foot', (
    tester,
  ) async {
    final scanner = _FakeScanner();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceScreen(
            backendUrl: 'http://127.0.0.1:1',
            scanner: scanner,
          ),
        ),
      ),
    );

    expect(find.text('FootGuard-L'), findsOneWidget);
    expect(find.text('FootGuard-R'), findsOneWidget);
    await tester.tap(find.text('开始扫描'));
    await tester.pump();
    expect(find.text('正在搜索FootGuard设备…'), findsOneWidget);

    scanner.emit(
      const BleScanSnapshot(
        isScanning: true,
        left: BleScanDevice(
          remoteId: 'AA:BB:CC:DD:EE:01',
          name: 'FootGuard-L',
          side: FootSide.left,
          rssi: -48,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('remoteId：AA:BB:CC:DD:EE:01'), findsOneWidget);
    expect(find.text('信号强度：-48 dBm'), findsOneWidget);
    expect(find.text('已发现，尚未建立GATT连接'), findsOneWidget);

    await tester.tap(find.text('停止扫描'));
    await tester.pump();
    expect(scanner.stopCalled, isTrue);
    await scanner.dispose();
  });
}
