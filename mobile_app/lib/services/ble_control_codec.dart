import 'dart:convert';
import 'dart:typed_data';

import '../models/ble_device_status.dart';

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
