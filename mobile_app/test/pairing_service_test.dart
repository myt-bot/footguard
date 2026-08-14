import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/services/frame_pairing_service.dart';

FootFrame frame(String side, int timestamp, {int packetSeq = 3}) => FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_${side}_001',
      side: side,
      syncId: 7,
      packetSeq: packetSeq,
      timestampMs: timestamp,
      pressure: const [0.1, 0.1, 0.1, 0.1, 0.1, 0.1],
      temperature: const [30, 30, 30, 30],
      imu: const ImuData(ax: 0, ay: 0, az: 9.8, gx: 0, gy: 0, gz: 0),
      battery: 90,
      qualityFlags: 0,
      source: 'mock',
    );

void main() {
  test('pairs left and right within 50 ms', () {
    final service = FramePairingService();
    expect(service.add(frame('left', 1000)), isNull);
    expect(service.add(frame('right', 1020)), hasLength(2));
  });

  test('does not pair frames outside sync window', () {
    final service = FramePairingService();
    service.add(frame('left', 1000));
    expect(service.add(frame('right', 1100)), isNull);
  });

  test('keeps an older packet while one foot advances first', () {
    final service = FramePairingService();
    expect(service.add(frame('left', 1000, packetSeq: 10)), isNull);
    expect(service.add(frame('left', 1050, packetSeq: 11)), isNull);

    final first = service.add(frame('right', 1020, packetSeq: 10));
    final second = service.add(frame('right', 1070, packetSeq: 11));

    expect(first!.map((item) => item.packetSeq), everyElement(10));
    expect(second!.map((item) => item.packetSeq), everyElement(11));
  });
}
