import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/foot_frame.dart';

Map<String, dynamic> validFrame() => {
      'protocol_version': 1,
      'sensor_layout_version': 'layout_6p4t_v1',
      'device_id': 'foot_left_001',
      'side': 'left',
      'sync_id': 1,
      'packet_seq': 1,
      'timestamp_ms': 1760000000000,
      'pressure': [0.1, 0.2, 0.3, 0.2, 0.1, 0.1],
      'temperature': [30.7, 30.8, 30.4, 30.6],
      'imu': {
        'ax': 0.0,
        'ay': 0.0,
        'az': 9.81,
        'gx': 0.0,
        'gy': 0.0,
        'gz': 0.0
      },
      'battery': 95,
      'quality_flags': 0,
      'source': 'mock',
    };

void main() {
  test('protocol JSON parses into FootFrame', () {
    final frame = FootFrame.fromJson(validFrame());
    expect(frame.side, 'left');
    expect(frame.pressure, hasLength(6));
    expect(frame.temperature, hasLength(4));
    expect(frame.totalLoad, closeTo(1.0, 0.0001));
  });

  test('wrong pressure length is rejected', () {
    final json = validFrame()..['pressure'] = [0.1, 0.2];
    expect(() => FootFrame.fromJson(json), throwsFormatException);
  });

  test('wrong temperature length is rejected', () {
    final json = validFrame()..['temperature'] = [30.7, 30.8, 30.4];
    expect(() => FootFrame.fromJson(json), throwsFormatException);
  });

  test('unknown side is rejected', () {
    final json = validFrame()..['side'] = 'LEFT';
    expect(() => FootFrame.fromJson(json), throwsFormatException);
  });
}
