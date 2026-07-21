import 'dart:convert';
import 'dart:typed_data';

import '../models/ble_device_status.dart';
import '../models/device_ack.dart';
import '../models/device_command.dart';

class BleControlCodecException implements Exception {
  const BleControlCodecException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleControlCodecException($code): $message';
}

class BleControlCodec {
  static const _requiredStatusFields = {
    'protocol_version',
    'firmware_version',
    'device_id',
    'side',
    'sensor_layout_version',
    'battery',
    'state',
    'error_code',
    'time_synced',
    'sync_id',
  };
  static const _states = {'booting', 'idle', 'streaming', 'error'};
  static const _errorCodes = {
    'none',
    'sensor_error',
    'calibration_error',
    'imu_error',
    'motor_error',
    'low_battery',
    'internal_error',
  };
  static const _commandTargets = {'left', 'right', 'both'};
  static const _commandReasons = {
    'manual_test',
    'left_load_bias',
    'right_load_bias',
    'forefoot_high',
    'temperature_asymmetry',
    'risk_persisted',
    'cancel',
  };
  static const _ackStatuses = {'executed', 'rejected', 'expired', 'failed'};
  static const _ackErrorCodes = {
    'none',
    'invalid_json',
    'unsupported_protocol',
    'target_mismatch',
    'invalid_pattern',
    'invalid_duration',
    'command_expired',
    'time_unsynced',
    'motor_fault',
    'command_conflict',
    'internal_error',
  };

  const BleControlCodec();

  BleDeviceStatus decodeDeviceStatus(
    List<int> bytes, {
    String? expectedSide,
  }) {
    late final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw BleControlCodecException('invalid_utf8', error.message);
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw BleControlCodecException('invalid_json', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BleControlCodecException(
          'invalid_status', 'DeviceStatus must be a JSON object');
    }
    return parseDeviceStatus(decoded, expectedSide: expectedSide);
  }

  BleDeviceStatus parseDeviceStatus(
    Map<String, dynamic> json, {
    String? expectedSide,
  }) {
    if (json.keys.toSet().difference(_requiredStatusFields).isNotEmpty ||
        _requiredStatusFields.difference(json.keys.toSet()).isNotEmpty) {
      throw const BleControlCodecException(
        'invalid_fields',
        'DeviceStatus fields do not match protocol v1',
      );
    }
    if (json['protocol_version'] != 1) {
      throw const BleControlCodecException(
          'unsupported_protocol', 'protocol_version must be 1');
    }

    final firmwareVersion = _string(json, 'firmware_version');
    if (!RegExp(r'^[A-Za-z0-9._-]{1,12}$').hasMatch(firmwareVersion)) {
      throw const BleControlCodecException(
          'invalid_firmware_version', 'Invalid firmware_version');
    }
    final deviceId = _string(json, 'device_id');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,16}$').hasMatch(deviceId)) {
      throw const BleControlCodecException(
          'invalid_device_id', 'Invalid device_id');
    }

    final side = _string(json, 'side');
    if (side != 'left' && side != 'right') {
      throw const BleControlCodecException(
          'invalid_side', 'side must be left or right');
    }
    if (expectedSide != null && side != expectedSide) {
      throw BleControlCodecException(
        'side_mismatch',
        'Connected $expectedSide device reported side=$side',
      );
    }
    if (json['sensor_layout_version'] != 'layout_6p4t_v1') {
      throw const BleControlCodecException(
        'unsupported_layout',
        'sensor_layout_version must be layout_6p4t_v1',
      );
    }

    final battery = _integer(json, 'battery');
    if (battery < 0 || battery > 100) {
      throw const BleControlCodecException(
          'invalid_battery', 'battery must be 0..100');
    }
    final state = _string(json, 'state');
    if (!_states.contains(state)) {
      throw const BleControlCodecException(
          'invalid_state', 'Unsupported DeviceStatus state');
    }
    final errorCode = _string(json, 'error_code');
    if (!_errorCodes.contains(errorCode)) {
      throw const BleControlCodecException(
          'invalid_error_code', 'Unsupported error_code');
    }

    final timeSynced = json['time_synced'];
    if (timeSynced is! bool) {
      throw const BleControlCodecException(
          'invalid_time_synced', 'time_synced must be boolean');
    }
    final syncId = _integer(json, 'sync_id');
    if (syncId < 0 || syncId > 0xFFFFFFFF) {
      throw const BleControlCodecException(
          'invalid_sync_id', 'sync_id must be uint32');
    }
    if ((!timeSynced && syncId != 0) || (timeSynced && syncId == 0)) {
      throw const BleControlCodecException(
        'inconsistent_time_sync',
        'time_synced and sync_id are inconsistent',
      );
    }

    return BleDeviceStatus(
      protocolVersion: 1,
      firmwareVersion: firmwareVersion,
      deviceId: deviceId,
      side: side,
      sensorLayoutVersion: 'layout_6p4t_v1',
      battery: battery,
      state: state,
      errorCode: errorCode,
      timeSynced: timeSynced,
      syncId: syncId,
    );
  }

  Uint8List encodeTimeSync({
    required int syncId,
    required int unixTimeMs,
  }) {
    if (syncId <= 0 || syncId > 0xFFFFFFFF) {
      throw const BleControlCodecException(
          'invalid_sync_id', 'sync_id must be uint32 and non-zero');
    }
    if (unixTimeMs < 0) {
      throw const BleControlCodecException(
          'invalid_unix_time', 'unix_time_ms must not be negative');
    }

    final bytes = Uint8List(12);
    final data = ByteData.sublistView(bytes);
    data.setUint32(0, syncId, Endian.little);
    data.setUint64(4, unixTimeMs, Endian.little);
    return bytes;
  }

  Uint8List encodeDeviceCommand(DeviceCommand command) {
    if (!RegExp(r'^cmd_[A-Za-z0-9_-]{1,48}$').hasMatch(command.commandId)) {
      throw const BleControlCodecException(
        'invalid_command_id',
        'command_id does not match protocol v1',
      );
    }
    if (!_commandTargets.contains(command.target)) {
      throw const BleControlCodecException(
        'invalid_target',
        'target must be left, right or both',
      );
    }
    final range = switch (command.pattern) {
      'off' => (0, 0),
      'short' => (100, 1000),
      'double' => (200, 2000),
      'long' => (1000, 5000),
      _ => null,
    };
    if (range == null) {
      throw const BleControlCodecException(
        'invalid_pattern',
        'Unsupported command pattern',
      );
    }
    if (command.durationMs < range.$1 || command.durationMs > range.$2) {
      throw const BleControlCodecException(
        'invalid_duration',
        'duration_ms does not match pattern',
      );
    }
    if (command.expireAtMs < 0) {
      throw const BleControlCodecException(
        'invalid_expiry',
        'expire_at_ms must not be negative',
      );
    }
    if (!_commandReasons.contains(command.reasonCode)) {
      throw const BleControlCodecException(
        'invalid_reason',
        'Unsupported reason_code',
      );
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(command.toJson())));
  }

  DeviceAck decodeAckEvent(
    List<int> bytes, {
    String? expectedDeviceId,
  }) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on FormatException catch (error) {
      throw BleControlCodecException('invalid_ack', error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BleControlCodecException(
        'invalid_ack',
        'AckEvent must be a JSON object',
      );
    }
    const required = {
      'protocol_version',
      'command_id',
      'device_id',
      'status',
      'ack_at_ms',
      'error_code',
    };
    const allowed = {...required, 'executed_at_ms'};
    final fields = decoded.keys.toSet();
    if (required.difference(fields).isNotEmpty ||
        fields.difference(allowed).isNotEmpty) {
      throw const BleControlCodecException(
        'invalid_ack_fields',
        'AckEvent fields do not match protocol v1',
      );
    }
    if (decoded['protocol_version'] != 1) {
      throw const BleControlCodecException(
        'unsupported_protocol',
        'protocol_version must be 1',
      );
    }
    final commandId = _string(decoded, 'command_id');
    final deviceId = _string(decoded, 'device_id');
    final status = _string(decoded, 'status');
    final ackAtMs = _integer(decoded, 'ack_at_ms');
    final errorCode = _string(decoded, 'error_code');
    final executedAtMs = decoded['executed_at_ms'];
    if (!RegExp(r'^cmd_[A-Za-z0-9_-]{1,48}$').hasMatch(commandId) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,16}$').hasMatch(deviceId) ||
        !_ackStatuses.contains(status) ||
        !_ackErrorCodes.contains(errorCode) ||
        ackAtMs < 0 ||
        (executedAtMs != null && (executedAtMs is! int || executedAtMs < 0))) {
      throw const BleControlCodecException(
        'invalid_ack',
        'AckEvent contains an invalid value',
      );
    }
    if (expectedDeviceId != null && deviceId != expectedDeviceId) {
      throw const BleControlCodecException(
        'ack_device_mismatch',
        'AckEvent device_id does not match the connected device',
      );
    }
    if (status == 'executed') {
      if (executedAtMs == null || errorCode != 'none') {
        throw const BleControlCodecException(
          'invalid_ack_state',
          'executed ACK requires executed_at_ms and error_code=none',
        );
      }
    } else if (executedAtMs != null) {
      throw const BleControlCodecException(
        'invalid_ack_state',
        'non-executed ACK must not contain executed_at_ms',
      );
    }
    if (status == 'expired' && errorCode != 'command_expired') {
      throw const BleControlCodecException(
        'invalid_ack_state',
        'expired ACK requires command_expired',
      );
    }
    if (status == 'failed' &&
        errorCode != 'motor_fault' &&
        errorCode != 'internal_error') {
      throw const BleControlCodecException(
        'invalid_ack_state',
        'failed ACK requires motor_fault or internal_error',
      );
    }
    if (status == 'rejected' &&
        (errorCode == 'none' ||
            errorCode == 'motor_fault' ||
            errorCode == 'internal_error')) {
      throw const BleControlCodecException(
        'invalid_ack_state',
        'rejected ACK requires a rejection error code',
      );
    }
    return DeviceAck(
      commandId: commandId,
      deviceId: deviceId,
      status: status,
      ackAtMs: ackAtMs,
      executedAtMs: executedAtMs as int?,
      errorCode: errorCode,
    );
  }

  static String _string(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! String) {
      throw BleControlCodecException(
          'invalid_$field', '$field must be a string');
    }
    return value;
  }

  static int _integer(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! int) {
      throw BleControlCodecException(
          'invalid_$field', '$field must be an integer');
    }
    return value;
  }
}
