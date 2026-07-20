import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ble_connection_state.dart';
import 'package:footguard/models/ble_device_status.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/screens/device_screen.dart';
import 'package:footguard/services/ble_connection_service.dart';
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

class _FakeConnectionService extends BleConnectionService {
  final _snapshots = StreamController<BleConnectionsSnapshot>.broadcast();
  BleConnectionsSnapshot _current = const BleConnectionsSnapshot.disconnected();
  BleScanDevice? connectedDevice;
  FootSide? disconnectedSide;

  @override
  Stream<BleConnectionsSnapshot> get snapshots => _snapshots.stream;
  @override
  BleConnectionsSnapshot get current => _current;

  @override
  Future<void> connect(BleScanDevice scanned) async {
    connectedDevice = scanned;
    _current = _current.replace(
      BleConnectionInfo(
        side: scanned.side,
        state: BleLinkState.ready,
        remoteId: scanned.remoteId,
        mtu: 247,
        deviceStatus: const BleDeviceStatus(
          protocolVersion: 1,
          firmwareVersion: '1.2.0',
          deviceId: 'foot_left_001',
          side: 'left',
          sensorLayoutVersion: 'layout_6p4t_v1',
          battery: 95,
          state: 'streaming',
          errorCode: 'none',
          timeSynced: false,
          syncId: 0,
        ),
      ),
    );
    _snapshots.add(_current);
  }

  @override
  Future<void> disconnect(FootSide side) async {
    disconnectedSide = side;
    _current = _current.replace(BleConnectionInfo.disconnected(side));
    _snapshots.add(_current);
  }

  @override
  Future<void> dispose() => _snapshots.close();
}

void main() {
  testWidgets('device page scans and connects a discovered left foot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final scanner = _FakeScanner();
    final connection = _FakeConnectionService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceScreen(
            backendUrl: 'http://127.0.0.1:1',
            scanner: scanner,
            connectionService: connection,
          ),
        ),
      ),
    );

    expect(find.text('双足设备'), findsOneWidget);
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

    await tester.tap(find.text('停止扫描'));
    await tester.pump();
    expect(scanner.stopCalled, isTrue);

    await tester.scrollUntilVisible(
      find.text('广播名称：FootGuard-L'),
      100,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('广播名称：FootGuard-L'), findsOneWidget);
    expect(find.text('remoteId：AA:BB:CC:DD:EE:01'), findsOneWidget);
    expect(find.text('信号强度：-48 dBm'), findsOneWidget);
    expect(find.text('已发现，尚未建立GATT连接'), findsOneWidget);

    final connectButton = find.byKey(const ValueKey('connect_FootGuard-L'));
    await tester.ensureVisible(connectButton);
    await tester.tap(connectButton);
    await tester.pump();

    expect(connection.connectedDevice?.remoteId, 'AA:BB:CC:DD:EE:01');
    expect(find.text('MTU：247'), findsOneWidget);
    expect(find.text('device_id：foot_left_001'), findsOneWidget);
    expect(find.text('固件版本：1.2.0'), findsOneWidget);
    expect(find.text('电量：95%'), findsOneWidget);
    expect(find.text('时间同步：未同步'), findsOneWidget);

    final disconnectButton =
        find.byKey(const ValueKey('disconnect_FootGuard-L'));
    await tester.ensureVisible(disconnectButton);
    await tester.tap(disconnectButton);
    await tester.pump();
    expect(connection.disconnectedSide, FootSide.left);

    await tester.pumpWidget(const SizedBox.shrink());
    await scanner.dispose();
    await connection.dispose();
  });
}
