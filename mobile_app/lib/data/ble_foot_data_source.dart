import 'dart:async';

import '../models/foot_frame.dart';
import 'foot_data_source.dart';

class BleFootDataSource implements FootDataSource {
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();

  @override
  Stream<FootFrame> get frames => _frames.stream;
  @override
  Stream<FootConnectionSnapshot> get connectionState => _connections.stream;
  @override
  Stream<String?> get errorState => _errors.stream;
  @override
  String get label => 'BLE（等待硬件）';
  @override
  bool get shouldUploadToBackend => true;

  @override
  Future<void> start() async {
    _connections.add(const FootConnectionSnapshot(
      left: FootConnectionStatus.connecting,
      right: FootConnectionStatus.connecting,
    ));
    _errors.add('BLE 接口已预留，将在固件可用后接入扫描、解析和马达写入');
  }

  @override
  Future<void> stop() async =>
      _connections.add(const FootConnectionSnapshot.disconnected());

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}
