import 'dart:async';

import '../models/ble_connection_state.dart';
import '../models/ble_scan_device.dart';
import '../models/foot_frame.dart';
import '../services/ble_connection_service.dart';
import 'foot_data_source.dart';

class BleFootDataSource implements FootDataSource {
  BleFootDataSource(this.connectionService);

  final BleConnectionService connectionService;
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  StreamSubscription<BleConnectionsSnapshot>? _subscription;
  String? _lastLeftFrame;
  String? _lastRightFrame;

  @override
  Stream<FootFrame> get frames => _frames.stream;
  @override
  Stream<FootConnectionSnapshot> get connectionState => _connections.stream;
  @override
  Stream<String?> get errorState => _errors.stream;
  @override
  String get label => 'BLE 真机实时数据';
  @override
  bool get shouldUploadToBackend => true;

  @override
  Future<void> start() async {
    if (_subscription != null) {
      return;
    }
    _subscription = connectionService.snapshots.listen(
      _onSnapshot,
      onError: (Object error) => _errors.add('BLE数据流错误：$error'),
    );
    _onSnapshot(connectionService.current);
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _connections.add(const FootConnectionSnapshot.disconnected());
  }

  void _onSnapshot(BleConnectionsSnapshot snapshot) {
    _connections.add(FootConnectionSnapshot(
      left: _connectionStatus(snapshot.left),
      right: _connectionStatus(snapshot.right),
    ));
    _emitFrame(snapshot.left);
    _emitFrame(snapshot.right);

    final messages = <String?>[
      snapshot.left.error,
      snapshot.left.sensorError,
      snapshot.right.error,
      snapshot.right.sensorError,
    ].whereType<String>().where((value) => value.isNotEmpty).toList();
    _errors.add(messages.isEmpty ? null : messages.join('；'));
  }

  void _emitFrame(BleConnectionInfo connection) {
    final frame = connection.latestFrame;
    if (frame == null) {
      return;
    }
    final identity = '${frame.syncId}:${frame.packetSeq}:${frame.timestampMs}';
    if (connection.side == FootSide.left) {
      if (_lastLeftFrame == identity) {
        return;
      }
      _lastLeftFrame = identity;
    } else {
      if (_lastRightFrame == identity) {
        return;
      }
      _lastRightFrame = identity;
    }
    _frames.add(frame);
  }

  static FootConnectionStatus _connectionStatus(
    BleConnectionInfo connection,
  ) =>
      switch (connection.state) {
        BleLinkState.disconnected => FootConnectionStatus.disconnected,
        BleLinkState.connecting ||
        BleLinkState.discovering =>
          FootConnectionStatus.connecting,
        BleLinkState.ready => FootConnectionStatus.connected,
        BleLinkState.error => FootConnectionStatus.error,
      };

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}
