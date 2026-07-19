import 'dart:async';

import '../models/foot_frame.dart';
import 'api_client.dart';
import 'foot_data_source.dart';

class BackendFootDataSource implements FootDataSource {
  BackendFootDataSource(this.api);

  final FootGuardApiClient api;
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  Timer? _timer;

  @override
  Stream<FootFrame> get frames => _frames.stream;
  @override
  Stream<FootConnectionSnapshot> get connectionState => _connections.stream;
  @override
  Stream<String?> get errorState => _errors.stream;
  @override
  String get label => 'FastAPI 实时数据';
  @override
  bool get shouldUploadToBackend => false;

  @override
  Future<void> start() async {
    await _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    try {
      final snapshot = await api.realtime();
      if (snapshot.left != null) _frames.add(snapshot.left!);
      if (snapshot.right != null) _frames.add(snapshot.right!);
      _connections.add(FootConnectionSnapshot(
        left: snapshot.left == null
            ? FootConnectionStatus.disconnected
            : FootConnectionStatus.connected,
        right: snapshot.right == null
            ? FootConnectionStatus.disconnected
            : FootConnectionStatus.connected,
      ));
      _errors.add(null);
    } catch (error) {
      _errors.add('后端连接失败：$error');
      _connections.add(const FootConnectionSnapshot(
        left: FootConnectionStatus.error,
        right: FootConnectionStatus.error,
      ));
    }
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
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
