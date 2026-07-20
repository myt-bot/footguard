import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/services/ble_frame_parser.dart';

const _leftHex =
    '46 47 01 02 00 00 00 00 00 01 00 00 00 01 00 00 00 00 c0 2c c8 99 01 00 00 '
    '08 07 1c 0c 68 10 98 08 c4 09 b0 04 fe 0b 08 0c e0 0b f4 0b 02 00 fd ff e5 03 '
    '01 00 02 00 ff ff 5f 2f 1c';
const _rightHex =
    '46 47 01 02 01 00 00 00 00 01 00 00 00 01 00 00 00 14 c0 2c c8 99 01 00 00 '
    'a4 06 b8 0b a0 0f d0 07 60 09 14 05 f4 0b fe 0b d6 0b ea 0b ff ff 02 00 e6 03 '
    'ff ff 01 00 00 00 5d c3 25';

List<int> _hex(String value) => value
    .trim()
    .split(RegExp(r'\s+'))
    .map((part) => int.parse(part, radix: 16))
    .toList(growable: false);

Matcher _parseError(String code) => isA<BleFrameParseException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  const parser = BleFrameParser();

  test('CRC implementation matches the CCITT-FALSE check vector', () {
    expect(BleFrameParser.crc16CcittFalse('123456789'.codeUnits), 0x29B1);
  });

  test('parses the official left 6P4T frame', () {
    final frame = parser.parse(
      _hex(_leftHex),
      deviceId: 'foot_left_001',
      expectedSide: 'left',
    );

    expect(frame.protocolVersion, 1);
    expect(frame.sensorLayoutVersion, 'layout_6p4t_v1');
    expect(frame.deviceId, 'foot_left_001');
    expect(frame.side, 'left');
    expect(frame.syncId, 1);
    expect(frame.packetSeq, 1);
    expect(frame.timestampMs, 1760000000000);
    expect(frame.pressure, [0.18, 0.31, 0.42, 0.22, 0.25, 0.12]);
    expect(frame.temperature, [30.7, 30.8, 30.4, 30.6]);
    expect(frame.imu.ax, closeTo(0.0196133, 0.000001));
    expect(frame.imu.ay, closeTo(-0.02941995, 0.000001));
    expect(frame.imu.az, closeTo(9.77723005, 0.000001));
    expect(frame.imu.gx, 0.1);
    expect(frame.imu.gy, 0.2);
    expect(frame.imu.gz, -0.1);
    expect(frame.battery, 95);
    expect(frame.qualityFlags, 0);
    expect(frame.source, 'ble');
  });

  test('parses the official right 6P4T frame', () {
    final frame = parser.parse(
      _hex(_rightHex),
      deviceId: 'foot_right_001',
      expectedSide: 'right',
    );

    expect(frame.side, 'right');
    expect(frame.timestampMs, 1760000000020);
    expect(frame.pressure, [0.17, 0.30, 0.40, 0.20, 0.24, 0.13]);
    expect(frame.temperature, [30.6, 30.7, 30.3, 30.5]);
    expect(frame.imu.ax, closeTo(-0.00980665, 0.000001));
    expect(frame.imu.ay, closeTo(0.0196133, 0.000001));
    expect(frame.imu.az, closeTo(9.7870367, 0.000001));
    expect(frame.battery, 93);
  });

  test('rejects a frame whose length is not 60 bytes', () {
    expect(
      () => parser.parse(_hex(_leftHex).sublist(0, 59), deviceId: 'left'),
      throwsA(_parseError('invalid_length')),
    );
  });

  test('rejects an invalid magic value', () {
    final bytes = _hex(_leftHex)..[0] = 0;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('invalid_magic')),
    );
  });

  test('rejects an unsupported protocol version', () {
    final bytes = _hex(_leftHex)..[2] = 2;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('unsupported_protocol')),
    );
  });

  test('rejects an unsupported sensor layout', () {
    final bytes = _hex(_leftHex)..[3] = 1;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('unsupported_layout')),
    );
  });

  test('rejects an invalid side code', () {
    final bytes = _hex(_leftHex)..[4] = 2;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('invalid_side')),
    );
  });

  test('rejects a side that differs from DeviceStatus', () {
    expect(
      () => parser.parse(
        _hex(_leftHex),
        deviceId: 'foot_right_001',
        expectedSide: 'right',
      ),
      throwsA(_parseError('side_mismatch')),
    );
  });

  test('rejects data modified inside the CRC-protected region', () {
    final bytes = _hex(_leftHex)..[25] ^= 0x01;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('crc_mismatch')),
    );
  });

  test('rejects a frame whose CRC bytes are swapped', () {
    final bytes = _hex(_leftHex);
    final low = bytes[58];
    bytes[58] = bytes[59];
    bytes[59] = low;
    expect(
      () => parser.parse(bytes, deviceId: 'left'),
      throwsA(_parseError('crc_mismatch')),
    );
  });
}
