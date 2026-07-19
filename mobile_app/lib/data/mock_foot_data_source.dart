import 'dart:async';
import 'dart:math';

import '../models/foot_frame.dart';
import 'foot_data_source.dart';

class MockFootDataSource implements FootDataSource {
  MockFootDataSource({required this.scenario});

  final String scenario;
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  Timer? _timer;
  int _sequence = 0;
  late final int _syncId = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;

  @override
  Stream<FootFrame> get frames => _frames.stream;
  @override
  Stream<FootConnectionSnapshot> get connectionState => _connections.stream;
  @override
  Stream<String?> get errorState => _errors.stream;
  @override
  String get label => 'Mock · $scenario';
  @override
  bool get shouldUploadToBackend => true;

  @override
  Future<void> start() async {
    _connections.add(const FootConnectionSnapshot(
      left: FootConnectionStatus.connected,
      right: FootConnectionStatus.connected,
    ));
    _emitPair();
    _timer =
        Timer.periodic(const Duration(milliseconds: 200), (_) => _emitPair());
  }

  void _emitPair() {
    final elapsed = _sequence / 5.0;
    final loads = _loads(elapsed);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _frames.add(_frame('left', loads.$1, timestamp));
    if (!(scenario == 'right_disconnect' && _sequence >= 40)) {
      _frames.add(_frame('right', loads.$2, timestamp + 20));
    } else {
      _connections.add(const FootConnectionSnapshot(
        left: FootConnectionStatus.connected,
        right: FootConnectionStatus.disconnected,
      ));
    }
    _sequence += 1;
  }

  (double, double) _loads(double elapsed) {
    switch (scenario) {
      case 'normal_walk':
        final swing = sin(elapsed * pi * 2);
        return (max(0.2, 1.25 + swing), max(0.2, 1.25 - swing));
      case 'left_load_bias':
        return (2.8, 1.1);
      case 'left_forefoot_high':
        return (1.8, 1.75);
      case 'left_temperature_rise':
        return (1.8, 1.75);
      case 'right_load_bias':
        return (1.1, 2.8);
      default:
        return (1.8, 1.75);
    }
  }

  FootFrame _frame(String side, double total, int timestamp) {
    final weights = scenario == 'left_forefoot_high' && side == 'left'
        ? const [0.23, 0.22, 0.24, 0.20, 0.06, 0.05]
        : const [0.16, 0.17, 0.18, 0.14, 0.18, 0.17];
    final temperature = scenario == 'left_temperature_rise' && side == 'left'
        ? const [30.7, 33.6, 30.4, 30.6]
        : const [30.7, 30.8, 30.4, 30.6];
    return FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: side == 'left' ? 'foot_left_001' : 'foot_right_001',
      side: side,
      syncId: _syncId,
      packetSeq: _sequence,
      timestampMs: timestamp,
      pressure: weights.map((weight) => total * weight).toList(growable: false),
      temperature: temperature,
      imu:
          const ImuData(ax: 0.02, ay: -0.01, az: 9.81, gx: 0.1, gy: 0.1, gz: 0),
      battery: side == 'left' ? 95 : 93,
      qualityFlags: 0,
      source: 'mock',
    );
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _connections.add(const FootConnectionSnapshot.disconnected());
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}
