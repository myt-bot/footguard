import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/frame_pairing_service.dart';

void main() {
  FootFrame frame({
    required String side,
    required int packetSeq,
    required int timestampMs,
  }) =>
      FootFrame(
        protocolVersion: 1,
        sensorLayoutVersion: 'layout_6p4t_v1',
        deviceId: side == 'left' ? 'foot_left_001' : 'foot_right_001',
        side: side,
        syncId: 7,
        packetSeq: packetSeq,
        timestampMs: timestampMs,
        pressure: const [0, 0, 0, 0, 0, 0],
        temperature: const [30, 30, 30, 30],
        imu: const ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
        battery: 95,
        qualityFlags: 0,
        source: 'ble',
      );

  test('accepts a dual-foot pair at the 100 ms boundary', () {
    final pairing = FramePairingService();

    expect(
      pairing.add(frame(side: 'left', packetSeq: 10, timestampMs: 1000)),
      isNull,
    );
    final pair = pairing.add(
      frame(side: 'right', packetSeq: 10, timestampMs: 1100),
    );

    expect(pair, isNotNull);
    expect(pair!.map((item) => item.side), containsAll(['left', 'right']));
  });

  test('rejects frames outside the configured time window', () {
    final pairing = FramePairingService();

    pairing.add(frame(side: 'left', packetSeq: 10, timestampMs: 1000));
    expect(
      pairing.add(frame(side: 'right', packetSeq: 10, timestampMs: 1101)),
      isNull,
    );
  });

  test('waits for matching packet sequences before publishing', () {
    final pairing = FramePairingService();

    pairing.add(frame(side: 'left', packetSeq: 10, timestampMs: 1000));
    expect(
      pairing.add(frame(side: 'right', packetSeq: 11, timestampMs: 1200)),
      isNull,
    );
    final pair = pairing.add(
      frame(side: 'left', packetSeq: 11, timestampMs: 1210),
    );

    expect(pair, isNotNull);
    expect(pair!.every((item) => item.packetSeq == 11), isTrue);
  });
}
