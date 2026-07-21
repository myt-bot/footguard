import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/models/ble_connection_state.dart';
import 'package:footguard/models/ble_device_status.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/models/device_ack.dart';
import 'package:footguard/models/device_command.dart';
import 'package:footguard/services/ble_command_bridge.dart';
import 'package:footguard/services/ble_command_gateway.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeGateway implements BleCommandGateway {
  final _acks = StreamController<DeviceAck>.broadcast();
  final sent = <DeviceCommand>[];

  @override
  Stream<DeviceAck> get acknowledgements => _acks.stream;

  @override
  BleConnectionsSnapshot current = const BleConnectionsSnapshot(
    left: BleConnectionInfo(
      side: FootSide.left,
      state: BleLinkState.ready,
      mtu: 247,
      deviceStatus: BleDeviceStatus(
        protocolVersion: 1,
        firmwareVersion: '0.1.0',
        deviceId: 'foot_left_001',
        side: 'left',
        sensorLayoutVersion: 'layout_6p4t_v1',
        battery: 95,
        state: 'idle',
        errorCode: 'none',
        timeSynced: true,
        syncId: 1,
      ),
    ),
    right: BleConnectionInfo(
      side: FootSide.right,
      state: BleLinkState.ready,
      mtu: 247,
      deviceStatus: BleDeviceStatus(
        protocolVersion: 1,
        firmwareVersion: '0.1.0',
        deviceId: 'foot_right_001',
        side: 'right',
        sensorLayoutVersion: 'layout_6p4t_v1',
        battery: 93,
        state: 'idle',
        errorCode: 'none',
        timeSynced: true,
        syncId: 2,
      ),
    ),
  );

  @override
  Future<void> sendCommand(DeviceCommand command) async => sent.add(command);

  void emit(DeviceAck ack) => _acks.add(ack);

  Future<void> close() => _acks.close();
}

DeviceCommand _command(String target) => DeviceCommand(
      commandId: 'cmd_bridge_$target',
      target: target,
      pattern: 'double',
      durationMs: 800,
      expireAtMs: DateTime.now()
          .add(const Duration(seconds: 30))
          .millisecondsSinceEpoch,
      reasonCode: 'risk_persisted',
    );

DeviceAck _ack(String commandId, String deviceId) => DeviceAck(
      commandId: commandId,
      deviceId: deviceId,
      status: 'executed',
      ackAtMs: DateTime.now().millisecondsSinceEpoch,
      executedAtMs: DateTime.now().millisecondsSinceEpoch,
      errorCode: 'none',
    );

void main() {
  test('single-side command waits for device ACK before backend upload',
      () async {
    final requests = <Map<String, dynamic>>[];
    final gateway = _FakeGateway();
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'recorded': true}), 200);
      }),
    );
    final bridge = BleCommandBridge(api: api, gateway: gateway)..start();
    final command = _command('left');

    await bridge.submit(command);
    expect(gateway.sent, [command]);
    expect(requests, isEmpty);
    expect(bridge.status, contains('尚未确认马达执行'));

    gateway.emit(_ack(command.commandId, 'foot_left_001'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, hasLength(1));
    expect(requests.single['command_id'], command.commandId);
    expect(requests.single['device_id'], 'foot_left_001');
    expect(requests.single['status'], 'executed');
    expect(bridge.status, '设备返回executed，ACK已上传后端');

    await bridge.dispose();
    await gateway.close();
    api.close();
  });

  test('both command uploads two independent device ACKs', () async {
    final requests = <Map<String, dynamic>>[];
    final gateway = _FakeGateway();
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'recorded': true}), 200);
      }),
    );
    final bridge = BleCommandBridge(api: api, gateway: gateway)..start();
    final command = _command('both');

    await bridge.submit(command);
    gateway.emit(_ack(command.commandId, 'foot_left_001'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, hasLength(1));
    expect(bridge.status, contains('1/2'));

    gateway.emit(_ack(command.commandId, 'foot_right_001'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(requests, hasLength(2));
    expect(
      requests.map((value) => value['device_id']).toSet(),
      {'foot_left_001', 'foot_right_001'},
    );
    expect(bridge.status, '设备返回executed，ACK已上传后端');

    await bridge.dispose();
    await gateway.close();
    api.close();
  });

  test('command is not sent when the required device is disconnected',
      () async {
    final gateway = _FakeGateway();
    gateway.current = BleConnectionsSnapshot(
      left: gateway.current.left,
      right: const BleConnectionInfo.disconnected(FootSide.right),
    );
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: MockClient((request) async => http.Response('{}', 200)),
    );
    final bridge = BleCommandBridge(api: api, gateway: gateway)..start();

    await bridge.submit(_command('right'));
    expect(gateway.sent, isEmpty);
    expect(bridge.status, '右脚设备未连接，命令暂未下发');

    await bridge.dispose();
    await gateway.close();
    api.close();
  });
}
