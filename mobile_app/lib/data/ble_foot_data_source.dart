import 'dart:async';

import '../models/ble_connection_state.dart';
import '../models/ble_scan_device.dart';
import '../models/foot_frame.dart';
import '../services/ble_connection_service.dart';
import 'foot_data_source.dart';

class BleFootDataSource implements FootDataSource {
  BleFootDataSource(
    this.connectionService, {
    this.frameTimeout = const Duration(seconds: 3),
    this.freshnessCheckInterval = const Duration(seconds: 1),
  });

  final BleConnectionService connectionService;
  final Duration frameTimeout;
  final Duration freshnessCheckInterval;
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  StreamSubscription<BleConnectionsSnapshot>? _subscription;
  Timer? _freshnessTimer;
  String? _lastLeftFrame;
  String? _lastRightFrame;
  DateTime? _lastLeftReceivedAt;
  DateTime? _lastRightReceivedAt;
  final Set<FootSide> _timedOutSides = <FootSide>{};

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
    _freshnessTimer = Timer.periodic(
      freshnessCheckInterval,
      (_) => _checkFreshness(),
    );
    _onSnapshot(connectionService.current);
  }

  @override
  Future<void> stop() async {
    _freshnessTimer?.cancel();
    _freshnessTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _lastLeftReceivedAt = null;
    _lastRightReceivedAt = null;
    _timedOutSides.clear();
    _connections.add(const FootConnectionSnapshot.disconnected());
  }

  void _onSnapshot(BleConnectionsSnapshot snapshot) {
    _emitFrame(snapshot.left);
    _emitFrame(snapshot.right);
    if (snapshot.left.state == BleLinkState.ready) {
      _lastLeftReceivedAt ??= DateTime.now();
    } else {
      _lastLeftReceivedAt = null;
      _timedOutSides.remove(FootSide.left);
    }
    if (snapshot.right.state == BleLinkState.ready) {
      _lastRightReceivedAt ??= DateTime.now();
    } else {
      _lastRightReceivedAt = null;
      _timedOutSides.remove(FootSide.right);
    }
    _publishState(snapshot);
  }

  void _publishState(BleConnectionsSnapshot snapshot) {
    _connections.add(FootConnectionSnapshot(
      left: _connectionStatus(snapshot.left),
      right: _connectionStatus(snapshot.right),
    ));

    final messages = <String?>[
      snapshot.left.error,
      snapshot.left.sensorError,
      snapshot.right.error,
      snapshot.right.sensorError,
      if (_timedOutSides.contains(FootSide.left)) '左脚实时数据超过3秒未更新',
      if (_timedOutSides.contains(FootSide.right)) '右脚实时数据超过3秒未更新',
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
      _lastLeftReceivedAt = DateTime.now();
      _timedOutSides.remove(FootSide.left);
    } else {
      if (_lastRightFrame == identity) {
        return;
      }
      _lastRightFrame = identity;
      _lastRightReceivedAt = DateTime.now();
      _timedOutSides.remove(FootSide.right);
    }
    _frames.add(frame);
  }

  void _checkFreshness() {
    final snapshot = connectionService.current;
    final now = DateTime.now();
    _updateTimeout(
      side: FootSide.left,
      connection: snapshot.left,
      receivedAt: _lastLeftReceivedAt,
      now: now,
    );
    _updateTimeout(
      side: FootSide.right,
      connection: snapshot.right,
      receivedAt: _lastRightReceivedAt,
      now: now,
    );
    _publishState(snapshot);
  }

  void _updateTimeout({
    required FootSide side,
    required BleConnectionInfo connection,
    required DateTime? receivedAt,
    required DateTime now,
  }) {
    if (connection.state != BleLinkState.ready) {
      _timedOutSides.remove(side);
      return;
    }
    if (receivedAt == null || now.difference(receivedAt) > frameTimeout) {
      _timedOutSides.add(side);
    } else {
      _timedOutSides.remove(side);
    }
  }

  FootConnectionStatus _connectionStatus(BleConnectionInfo connection) {
    if (_timedOutSides.contains(connection.side)) {
      return FootConnectionStatus.error;
    }
    return switch (connection.state) {
      BleLinkState.disconnected => FootConnectionStatus.disconnected,
      BleLinkState.connecting ||
      BleLinkState.discovering =>
        FootConnectionStatus.connecting,
      BleLinkState.ready => FootConnectionStatus.connected,
      BleLinkState.error => FootConnectionStatus.error,
    };
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}
