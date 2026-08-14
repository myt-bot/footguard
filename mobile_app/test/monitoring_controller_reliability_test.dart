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

FootFrame _frame(
  String side,
  int timestampMs, {
  int packetSeq = 3,
}) {
  return FootFrame(
    protocolVersion: 1,
    sensorLayoutVersion: 'layout_6p4t_v1',
    deviceId: side == 'left' ? 'foot_left_001' : 'foot_right_001',
    side: side,
    syncId: 9,
    packetSeq: packetSeq,
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
}

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

  test('slow backend upload preserves a bounded recent pair history', () async {
    final firstUploadStarted = Completer<void>();
    final releaseFirstUpload = Completer<void>();
    final uploadedPacketSeqBatches = <List<int>>[];
    var uploadCount = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response(
          jsonEncode({'status': 'ok', 'server_time_ms': 1000}),
          200,
        );
      }
      if (request.url.path == '/api/v1/realtime') {
        return http.Response(
          jsonEncode({
            'left': null,
            'right': null,
            'paired_timestamp_ms': null,
            'load_bias': null,
            'load_diff': null,
            'sync_error_ms': null,
            'risk': {
              'risk_type': 'data_incomplete',
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
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final frames = body['frames'] as List<dynamic>;
        uploadedPacketSeqBatches.add(frames
            .cast<Map<String, dynamic>>()
            .map((frame) => frame['packet_seq'] as int)
            .toSet()
            .toList());
        uploadCount += 1;
        if (uploadCount == 1) {
          firstUploadStarted.complete();
          await releaseFirstUpload.future;
        }
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

    source.emitFrame(_frame('left', 1000, packetSeq: 1));
    source.emitFrame(_frame('right', 1001, packetSeq: 1));
    await firstUploadStarted.future;

    for (var packetSeq = 2; packetSeq <= 5; packetSeq += 1) {
      source.emitFrame(
        _frame('left', 1000 + packetSeq * 200, packetSeq: packetSeq),
      );
      source.emitFrame(
        _frame('right', 1001 + packetSeq * 200, packetSeq: packetSeq),
      );
    }
    await Future<void>.delayed(Duration.zero);
    releaseFirstUpload.complete();

    for (var attempt = 0;
        attempt < 20 && uploadedPacketSeqBatches.length < 2;
        attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(uploadedPacketSeqBatches, [
      [1],
      [2, 3, 4, 5],
    ]);
    controller.dispose();
  });

  test('offline upload failure keeps a healthy backend online and backs off',
      () async {
    var uploadCount = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response(
          jsonEncode({'status': 'ok', 'server_time_ms': 1000}),
          200,
        );
      }
      if (request.url.path == '/api/v1/realtime') {
        return http.Response(
          jsonEncode({
            'left': null,
            'right': null,
            'paired_timestamp_ms': null,
            'load_bias': null,
            'load_diff': null,
            'sync_error_ms': null,
            'risk': {
              'risk_type': 'data_incomplete',
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
      if (request.url.path == '/api/v1/sensor/batch' ||
          request.url.path == '/api/v1/sensor/offline-sync') {
        uploadCount += 1;
        return http.Response('Internal Server Error', 500);
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
    source.emitFrame(_frame('left', 1000, packetSeq: 20));
    source.emitFrame(_frame('right', 1001, packetSeq: 20));

    for (var attempt = 0;
        attempt < 20 && controller.syncWarningMessage == null;
        attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.backendOnline, isTrue);
    expect(controller.errorMessage, isNull);
    expect(controller.syncWarningMessage, contains('离线数据补传失败'));
    expect(controller.offlinePairCount, 1);
    expect(uploadCount, 1);

    await controller.refreshBackend();
    await controller.refreshBackend();
    expect(controller.backendOnline, isTrue);
    expect(uploadCount, 1);
    controller.dispose();
  });
}
