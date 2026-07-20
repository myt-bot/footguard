import 'dart:typed_data';

import '../models/foot_frame.dart';

class BleFrameParseException implements Exception {
  const BleFrameParseException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleFrameParseException($code): $message';
}

class BleFrameParser {
  static const frameLength = 60;
  static const protocolVersion = 1;
  static const layoutId = 2;
  static const sensorLayoutVersion = 'layout_6p4t_v1';

  const BleFrameParser();

  FootFrame parse(
    List<int> raw, {
    required String deviceId,
    String? expectedSide,
  }) {
    if (raw.length != frameLength) {
      throw BleFrameParseException(
        'invalid_length',
        'SensorData must contain exactly $frameLength bytes, got ${raw.length}',
      );
    }

    final bytes = Uint8List.fromList(raw);
    final data = ByteData.sublistView(bytes);

    if (bytes[0] != 0x46 || bytes[1] != 0x47) {
      throw const BleFrameParseException(
          'invalid_magic', 'SensorData magic must be 46 47');
    }
    if (bytes[2] != protocolVersion) {
      throw BleFrameParseException(
        'unsupported_protocol',
        'Unsupported protocol_version ${bytes[2]}',
      );
    }
    if (bytes[3] != layoutId) {
      throw BleFrameParseException(
        'unsupported_layout',
        'Unsupported layout_id ${bytes[3]}',
      );
    }

    final side = switch (bytes[4]) {
      0 => 'left',
      1 => 'right',
      _ => throw BleFrameParseException(
          'invalid_side', 'Unsupported side ${bytes[4]}'),
    };
    if (expectedSide != null && side != expectedSide) {
      throw BleFrameParseException(
        'side_mismatch',
        'Connected $expectedSide device sent a $side frame',
      );
    }

    final encodedCrc = data.getUint16(58, Endian.little);
    final calculatedCrc = crc16CcittFalse(bytes, length: 58);
    if (encodedCrc != calculatedCrc) {
      throw BleFrameParseException(
        'crc_mismatch',
        'CRC mismatch: encoded=0x${encodedCrc.toRadixString(16).padLeft(4, '0')}, '
            'calculated=0x${calculatedCrc.toRadixString(16).padLeft(4, '0')}',
      );
    }

    final battery = bytes[57];
    if (battery > 100) {
      throw BleFrameParseException(
          'invalid_battery', 'Battery must be 0..100, got $battery');
    }

    final pressure = List<double>.generate(
      6,
      (index) => data.getUint16(25 + index * 2, Endian.little) / 10000.0,
      growable: false,
    );
    final temperature = List<double>.generate(
      4,
      (index) => data.getInt16(37 + index * 2, Endian.little) / 100.0,
      growable: false,
    );
    final acceleration = List<double>.generate(
      3,
      (index) =>
          data.getInt16(45 + index * 2, Endian.little) * 9.80665 / 1000.0,
      growable: false,
    );
    final gyroscope = List<double>.generate(
      3,
      (index) => data.getInt16(51 + index * 2, Endian.little) / 10.0,
      growable: false,
    );

    return FootFrame(
      protocolVersion: protocolVersion,
      sensorLayoutVersion: sensorLayoutVersion,
      deviceId: deviceId,
      side: side,
      syncId: data.getUint32(9, Endian.little),
      packetSeq: data.getUint32(13, Endian.little),
      timestampMs: data.getUint64(17, Endian.little),
      pressure: pressure,
      temperature: temperature,
      imu: ImuData(
        ax: acceleration[0],
        ay: acceleration[1],
        az: acceleration[2],
        gx: gyroscope[0],
        gy: gyroscope[1],
        gz: gyroscope[2],
      ),
      battery: battery,
      qualityFlags: data.getUint32(5, Endian.little),
      source: 'ble',
    );
  }

  static int crc16CcittFalse(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw RangeError.range(count, 0, bytes.length, 'length');
    }

    var crc = 0xFFFF;
    for (var index = 0; index < count; index++) {
      crc ^= (bytes[index] & 0xFF) << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc;
  }
}
