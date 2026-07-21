import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/ble_foot_data_source.dart';
import 'package:footguard/data/foot_data_source.dart';
import 'package:footguard/models/ble_connection_state.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/ble_connection_service.dart';

class _FakeBleConnectionService extends BleConnectionService {
  final _snapshots = StreamController<BleConnectionsSnapshot>.broadcast();
  BleConnectionsSnapshot _current = const BleConnectionsSnapshot.disconnected();

  @override
  Stream<BleConnectionsSnapshot> get snapshots => _snapshots.stream;

  @override
  BleConnectionsSnapshot get current => _current;

  void emit(BleConnectionsSnapshot value) {
    _current = value;
    _snapshots.add(value);
  }

  @override
  Future<void> dispose() => _snapshots.close();
}

void main() {
  test('BLE source forwards connected sensor frames to monitoring', () async {
    final connection = _FakeBleConnectionService();
    final source = BleFootDataSource(connection);
    final frameFuture = source.frames.first;
    final connectedFuture = source.connectionState.firstWhere(
      (value) => value.left == FootConnectionStatus.connected,
    );

    await source.start();
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 7,
      packetSeq: 12,
      timestampMs: 1784600800030,
      pressure: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
      temperature: [30.1, 30.2, 30.3, 30.4],
      imu: ImuData(
        ax: 0,
        ay: 0,
        az: 9.8,
        gx: 0,
        gy: 0,
        gz: 0,
      ),
      battery: 95,
      qualityFlags: 0,
      source: 'ble',
    );
    connection.emit(
      const BleConnectionsSnapshot(
        left: BleConnectionInfo(
          side: FootSide.left,
          state: BleLinkState.ready,
          remoteId: 'AA:BB:CC:DD:EE:01',
          mtu: 247,
          latestFrame: frame,
          receivedFrames: 1,
        ),
        right: BleConnectionInfo.disconnected(FootSide.right),
      ),
    );

    final received = await frameFuture.timeout(const Duration(seconds: 1));
    final connected = await connectedFuture.timeout(const Duration(seconds: 1));
    expect(received.deviceId, 'foot_left_001');
    expect(received.pressure, hasLength(6));
    expect(received.temperature, hasLength(4));
    expect(connected.left, FootConnectionStatus.connected);
    expect(connected.right, FootConnectionStatus.disconnected);
    expect(source.label, 'BLE 真机实时数据');

    await source.dispose();
    await connection.dispose();
  });

  test('BLE source reports frame timeout and recovers on a new frame',
      () async {
    final connection = _FakeBleConnectionService();
    final source = BleFootDataSource(
      connection,
      frameTimeout: const Duration(milliseconds: 40),
      freshnessCheckInterval: const Duration(milliseconds: 10),
    );
    await source.start();

    const firstFrame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 7,
      packetSeq: 12,
      timestampMs: 1784600800030,
      pressure: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
      temperature: [30.1, 30.2, 30.3, 30.4],
      imu: ImuData(
        ax: 0,
        ay: 0,
        az: 9.8,
        gx: 0,
        gy: 0,
        gz: 0,
      ),
      battery: 95,
      qualityFlags: 0,
      source: 'ble',
    );
    connection.emit(
      const BleConnectionsSnapshot(
        left: BleConnectionInfo(
          side: FootSide.left,
          state: BleLinkState.ready,
          latestFrame: firstFrame,
          receivedFrames: 1,
        ),
        right: BleConnectionInfo.disconnected(FootSide.right),
      ),
    );

    final timeoutMessageFuture = source.errorState.firstWhere(
      (value) => value?.contains('左脚实时数据超过3秒未更新') ?? false,
    );
    final timedOut = await source.connectionState
        .firstWhere((value) => value.left == FootConnectionStatus.error)
        .timeout(const Duration(seconds: 1));
    expect(timedOut.left, FootConnectionStatus.error);

    final timeoutMessage =
        await timeoutMessageFuture.timeout(const Duration(seconds: 1));
    expect(timeoutMessage, contains('左脚实时数据超过3秒未更新'));

    final recoveredConnection = source.connectionState.firstWhere(
      (value) => value.left == FootConnectionStatus.connected,
    );
    final clearedError = source.errorState.firstWhere((value) => value == null);
    connection.emit(
      const BleConnectionsSnapshot(
        left: BleConnectionInfo(
          side: FootSide.left,
          state: BleLinkState.ready,
          latestFrame: FootFrame(
            protocolVersion: 1,
            sensorLayoutVersion: 'layout_6p4t_v1',
            deviceId: 'foot_left_001',
            side: 'left',
            syncId: 7,
            packetSeq: 13,
            timestampMs: 1784600800230,
            pressure: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            temperature: [30.1, 30.2, 30.3, 30.4],
            imu: ImuData(
              ax: 0,
              ay: 0,
              az: 9.8,
              gx: 0,
              gy: 0,
              gz: 0,
            ),
            battery: 95,
            qualityFlags: 0,
            source: 'ble',
          ),
          receivedFrames: 2,
        ),
        right: BleConnectionInfo.disconnected(FootSide.right),
      ),
    );

    expect(
      (await recoveredConnection.timeout(const Duration(seconds: 1))).left,
      FootConnectionStatus.connected,
    );
    expect(await clearedError.timeout(const Duration(seconds: 1)), isNull);

    await source.dispose();
    await connection.dispose();
  });
}
