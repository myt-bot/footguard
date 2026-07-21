import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/services/ble_control_codec.dart';
import 'package:footguard/services/ble_gatt.dart';
import 'package:footguard/models/device_command.dart';

Map<String, dynamic> _status({String side = 'left'}) => {
      'protocol_version': 1,
      'firmware_version': '0.1.0',
      'device_id': side == 'left' ? 'foot_left_001' : 'foot_right_001',
      'side': side,
      'sensor_layout_version': 'layout_6p4t_v1',
      'battery': side == 'left' ? 95 : 93,
      'state': 'streaming',
      'error_code': 'none',
      'time_synced': true,
      'sync_id': 1,
    };

Matcher _codecError(String code) => isA<BleControlCodecException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  const codec = BleControlCodec();

  test('GATT UUIDs and MTU limits match protocol v1', () {
    expect(FootGuardGatt.serviceUuid, '7d2f0000-5a6b-4c7d-8e9f-102030405060');
    expect(
        FootGuardGatt.sensorDataUuid, '7d2f0001-5a6b-4c7d-8e9f-102030405060');
    expect(
        FootGuardGatt.deviceStatusUuid, '7d2f0002-5a6b-4c7d-8e9f-102030405060');
    expect(FootGuardGatt.deviceCommandUuid,
        '7d2f0003-5a6b-4c7d-8e9f-102030405060');
    expect(FootGuardGatt.timeSyncUuid, '7d2f0004-5a6b-4c7d-8e9f-102030405060');
    expect(FootGuardGatt.ackEventUuid, '7d2f0005-5a6b-4c7d-8e9f-102030405060');
    expect(FootGuardGatt.preferredMtu, 247);
    expect(FootGuardGatt.minimumSensorMtu, 63);
  });

  test('decodes the official left DeviceStatus JSON', () {
    final status = codec.decodeDeviceStatus(
      utf8.encode(jsonEncode(_status())),
      expectedSide: 'left',
    );

    expect(status.deviceId, 'foot_left_001');
    expect(status.side, 'left');
    expect(status.battery, 95);
    expect(status.state, 'streaming');
    expect(status.timeSynced, isTrue);
    expect(status.syncId, 1);
  });

  test('decodes the official right DeviceStatus JSON', () {
    final status = codec.decodeDeviceStatus(
      utf8.encode(jsonEncode(_status(side: 'right'))),
      expectedSide: 'right',
    );
    expect(status.deviceId, 'foot_right_001');
    expect(status.side, 'right');
    expect(status.battery, 93);
  });

  test('rejects malformed UTF-8 and malformed JSON', () {
    expect(
      () => codec.decodeDeviceStatus([0xC3, 0x28]),
      throwsA(_codecError('invalid_utf8')),
    );
    expect(
      () => codec.decodeDeviceStatus(utf8.encode('{broken')),
      throwsA(_codecError('invalid_json')),
    );
  });

  test('rejects missing or additional DeviceStatus fields', () {
    final missing = _status()..remove('battery');
    final additional = _status()..['extra'] = true;
    expect(
      () => codec.parseDeviceStatus(missing),
      throwsA(_codecError('invalid_fields')),
    );
    expect(
      () => codec.parseDeviceStatus(additional),
      throwsA(_codecError('invalid_fields')),
    );
  });

  test('rejects unsupported protocol and layout versions', () {
    final protocol = _status()..['protocol_version'] = 2;
    final layout = _status()..['sensor_layout_version'] = 'layout_6p3t_v1';
    expect(
      () => codec.parseDeviceStatus(protocol),
      throwsA(_codecError('unsupported_protocol')),
    );
    expect(
      () => codec.parseDeviceStatus(layout),
      throwsA(_codecError('unsupported_layout')),
    );
  });

  test('rejects a DeviceStatus side mismatch', () {
    expect(
      () => codec.parseDeviceStatus(_status(), expectedSide: 'right'),
      throwsA(_codecError('side_mismatch')),
    );
  });

  test('rejects invalid battery, state and error code', () {
    expect(
      () => codec.parseDeviceStatus(_status()..['battery'] = 101),
      throwsA(_codecError('invalid_battery')),
    );
    expect(
      () => codec.parseDeviceStatus(_status()..['state'] = 'connected'),
      throwsA(_codecError('invalid_state')),
    );
    expect(
      () => codec.parseDeviceStatus(_status()..['error_code'] = 'unknown'),
      throwsA(_codecError('invalid_error_code')),
    );
  });

  test('enforces the relation between time_synced and sync_id', () {
    final falseWithId = _status()
      ..['time_synced'] = false
      ..['sync_id'] = 1;
    final trueWithoutId = _status()
      ..['time_synced'] = true
      ..['sync_id'] = 0;
    expect(
      () => codec.parseDeviceStatus(falseWithId),
      throwsA(_codecError('inconsistent_time_sync')),
    );
    expect(
      () => codec.parseDeviceStatus(trueWithoutId),
      throwsA(_codecError('inconsistent_time_sync')),
    );
  });

  test('encodes the official 12-byte little-endian TimeSync vector', () {
    final bytes = codec.encodeTimeSync(
      syncId: 1,
      unixTimeMs: 1760000000000,
    );
    expect(
      bytes,
      [0x01, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x2C, 0xC8, 0x99, 0x01, 0x00, 0x00],
    );
  });

  test('rejects zero sync_id and a negative Unix timestamp', () {
    expect(
      () => codec.encodeTimeSync(syncId: 0, unixTimeMs: 1760000000000),
      throwsA(_codecError('invalid_sync_id')),
    );
    expect(
      () => codec.encodeTimeSync(syncId: 1, unixTimeMs: -1),
      throwsA(_codecError('invalid_unix_time')),
    );
  });

  test('encodes DeviceCommand as compact protocol v1 JSON', () {
    const command = DeviceCommand(
      commandId: 'cmd_bridge_left_1',
      target: 'left',
      pattern: 'double',
      durationMs: 800,
      expireAtMs: 1784609999999,
      reasonCode: 'left_load_bias',
    );
    expect(
      utf8.decode(codec.encodeDeviceCommand(command)),
      '{"protocol_version":1,"command_id":"cmd_bridge_left_1","target":"left","pattern":"double","duration_ms":800,"expire_at_ms":1784609999999,"reason_code":"left_load_bias"}',
    );
  });

  test('rejects DeviceCommand duration that conflicts with pattern', () {
    const command = DeviceCommand(
      commandId: 'cmd_bad_duration',
      target: 'left',
      pattern: 'short',
      durationMs: 99,
      expireAtMs: 1784609999999,
      reasonCode: 'manual_test',
    );
    expect(
      () => codec.encodeDeviceCommand(command),
      throwsA(_codecError('invalid_duration')),
    );
  });

  test('decodes an executed AckEvent and preserves its exact fields', () {
    final ack = codec.decodeAckEvent(
      utf8.encode(
        '{"protocol_version":1,"command_id":"cmd_bridge_left_1","device_id":"foot_left_001","status":"executed","ack_at_ms":1784600000900,"executed_at_ms":1784600000800,"error_code":"none"}',
      ),
      expectedDeviceId: 'foot_left_001',
    );
    expect(ack.commandId, 'cmd_bridge_left_1');
    expect(ack.status, 'executed');
    expect(ack.executedAtMs, 1784600000800);
    expect(ack.toJson()['device_id'], 'foot_left_001');
  });

  test('rejects an invalid or mismatched AckEvent', () {
    expect(
      () => codec.decodeAckEvent(
        utf8.encode(
          '{"protocol_version":1,"command_id":"cmd_bridge_left_1","device_id":"foot_left_001","status":"executed","ack_at_ms":1784600000900,"error_code":"none"}',
        ),
      ),
      throwsA(_codecError('invalid_ack_state')),
    );
    expect(
      () => codec.decodeAckEvent(
        utf8.encode(
          '{"protocol_version":1,"command_id":"cmd_bridge_left_1","device_id":"foot_left_001","status":"expired","ack_at_ms":1784600000900,"error_code":"command_expired"}',
        ),
        expectedDeviceId: 'foot_right_001',
      ),
      throwsA(_codecError('ack_device_mismatch')),
    );
  });
}
