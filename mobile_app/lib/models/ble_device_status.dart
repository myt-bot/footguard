class BleDeviceStatus {
  const BleDeviceStatus({
    required this.protocolVersion,
    required this.firmwareVersion,
    required this.deviceId,
    required this.side,
    required this.sensorLayoutVersion,
    required this.battery,
    required this.state,
    required this.errorCode,
    required this.timeSynced,
    required this.syncId,
  });

  final int protocolVersion;
  final String firmwareVersion;
  final String deviceId;
  final String side;
  final String sensorLayoutVersion;
  final int battery;
  final String state;
  final String errorCode;
  final bool timeSynced;
  final int syncId;

  Map<String, dynamic> toJson() => {
        'protocol_version': protocolVersion,
        'firmware_version': firmwareVersion,
        'device_id': deviceId,
        'side': side,
        'sensor_layout_version': sensorLayoutVersion,
        'battery': battery,
        'state': state,
        'error_code': errorCode,
        'time_synced': timeSynced,
        'sync_id': syncId,
      };
}
