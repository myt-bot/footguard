import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/data/foot_data_source.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/monitoring_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeFootDataSource implements FootDataSource {
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
  String get label => 'reliability-test';
  @override
  bool get shouldUploadToBackend => true;

  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}

  void emitFrame(FootFrame value) => _frames.add(value);
  void emitConnections(FootConnectionSnapshot value) => _connections.add(value);
  void emitError(String? value) => _errors.add(value);

  @override
  Future<void> dispose() async {
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}

FootFrame _frame(String side, int timestampMs) => FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: side == 'left' ? 'foot_left_001' : 'foot_right_001',
      side: side,
      syncId: 9,
      packetSeq: 3,
      timestampMs: timestampMs,
      pressure: const [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
      temperature: const [30.1, 30.2, 30.3, 30.4],
      imu: const ImuData(
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

void main() {
  test('disconnect clears live frames and stale bilateral backend results',
      () async {
    final left = _frame('left', 1000);
    final right = _frame('right', 1020);
    final client = MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      if (request.url.path == '/api/v1/realtime') {
        return http.Response(
          jsonEncode({
            'left': left.toJson(),
            'right': right.toJson(),
            'load_bias': 0.02,
            'load_diff': 0.04,
            'sync_error_ms': 20,
            'risk': {
              'risk_type': 'normal',
              'risk_side': 'none',
              'risk_level': 0,
              'duration_ms': 0,
            },
            'regional_analysis': null,
          }),
          200,
        );
      }
      if (request.url.path == '/api/v1/command/pending') {
        return http.Response(jsonEncode({'command': null}), 200);
      }
      if (request.url.path == '/api/v1/sensor/batch') {
        return http.Response(
          jsonEncode({'accepted': 2, 'rejected': 0}),
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final source = _FakeFootDataSource();
    final controller = MonitoringController(
      source: source,
      api: FootGuardApiClient(baseUrl: 'http://footguard.test', client: client),
    );
    await controller.start();

    source.emitConnections(const FootConnectionSnapshot(
      left: FootConnectionStatus.connected,
      right: FootConnectionStatus.connected,
    ));
    source.emitFrame(left);
    source.emitFrame(right);
    await Future<void>.delayed(Duration.zero);
    await controller.refreshBackend();
    expect(controller.risk.isNormal, isTrue);
    expect(controller.syncErrorMs, 20);

    source.emitConnections(const FootConnectionSnapshot(
      left: FootConnectionStatus.error,
      right: FootConnectionStatus.connected,
    ));
    source.emitError('左脚实时数据超过3秒未更新');
    await Future<void>.delayed(Duration.zero);

    expect(controller.left, isNull);
    expect(controller.right, isNotNull);
    expect(controller.risk.isIncomplete, isTrue);
    expect(controller.loadBias, isNull);
    expect(controller.loadDiff, isNull);
    expect(controller.syncErrorMs, isNull);
    expect(controller.motorCommand, isNull);
    expect(controller.motorStatus, '双足数据不完整，暂停马达提醒');

    await controller.refreshBackend();
    expect(controller.left, isNull);
    expect(controller.risk.isIncomplete, isTrue);
    expect(controller.errorMessage, '左脚实时数据超过3秒未更新');

    controller.dispose();
  });
}
