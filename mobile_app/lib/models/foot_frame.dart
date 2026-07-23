class ImuData {
  const ImuData({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
  });

  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;

  factory ImuData.fromJson(Map<String, dynamic> json) {
    double value(String key) {
      final raw = json[key];
      if (raw is! num) throw FormatException('imu.$key must be numeric');
      return raw.toDouble();
    }

    return ImuData(
      ax: value('ax'),
      ay: value('ay'),
      az: value('az'),
      gx: value('gx'),
      gy: value('gy'),
      gz: value('gz'),
    );
  }

  Map<String, dynamic> toJson() => {
        'ax': ax,
        'ay': ay,
        'az': az,
        'gx': gx,
        'gy': gy,
        'gz': gz,
      };
}

class FootFrame {
  const FootFrame({
    required this.protocolVersion,
    required this.sensorLayoutVersion,
    required this.deviceId,
    required this.side,
    required this.syncId,
    required this.packetSeq,
    required this.timestampMs,
    required this.pressure,
    required this.temperature,
    required this.imu,
    required this.battery,
    required this.qualityFlags,
    required this.source,
  });

  final int protocolVersion;
  final String sensorLayoutVersion;
  final String deviceId;
  final String side;
  final int syncId;
  final int packetSeq;
  final int timestampMs;
  final List<double> pressure;
  final List<double> temperature;
  final ImuData imu;
  final int battery;
  final int qualityFlags;
  final String source;

  static const int pressureInvalidMask = 0x0000003f;
  static const int temperatureInvalidMask = 0x000003c0;

  double get totalLoad => pressure.fold(0, (sum, value) => sum + value);
  bool get qualityOk => qualityFlags == 0;
  bool get pressureChannelsValid => qualityFlags & pressureInvalidMask == 0;
  bool get temperatureChannelsValid =>
      qualityFlags & temperatureInvalidMask == 0;

  bool pressureChannelValid(int index) =>
      index >= 0 && index < 6 && qualityFlags & (1 << index) == 0;

  bool temperatureChannelValid(int index) =>
      index >= 0 && index < 4 && qualityFlags & (0x40 << index) == 0;

  static List<double> _channels(dynamic raw, int length, String field) {
    if (raw is! List ||
        raw.length != length ||
        raw.any((value) => value is! num)) {
      throw FormatException(
          '$field must contain exactly $length numeric values');
    }
    return raw
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
  }

  factory FootFrame.fromJson(Map<String, dynamic> json) {
    if (json['protocol_version'] != 1) {
      throw const FormatException('unsupported protocol_version');
    }
    if (!const {'left', 'right'}.contains(json['side'])) {
      throw const FormatException('side must be left or right');
    }
    if (json['sensor_layout_version'] != 'layout_6p4t_v1') {
      throw const FormatException('unsupported sensor_layout_version');
    }
    final battery = json['battery'];
    if (battery is! int || battery < 0 || battery > 100) {
      throw const FormatException('battery must be 0..100');
    }
    return FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: json['sensor_layout_version'] as String,
      deviceId: json['device_id'] as String,
      side: json['side'] as String,
      syncId: json['sync_id'] as int,
      packetSeq: json['packet_seq'] as int,
      timestampMs: json['timestamp_ms'] as int,
      pressure: _channels(json['pressure'], 6, 'pressure'),
      temperature: _channels(json['temperature'], 4, 'temperature'),
      imu: ImuData.fromJson(json['imu'] as Map<String, dynamic>),
      battery: battery,
      qualityFlags: json['quality_flags'] as int,
      source: json['source'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'protocol_version': protocolVersion,
        'sensor_layout_version': sensorLayoutVersion,
        'device_id': deviceId,
        'side': side,
        'sync_id': syncId,
        'packet_seq': packetSeq,
        'timestamp_ms': timestampMs,
        'pressure': pressure,
        'temperature': temperature,
        'imu': imu.toJson(),
        'battery': battery,
        'quality_flags': qualityFlags,
        'source': source,
      };
}
