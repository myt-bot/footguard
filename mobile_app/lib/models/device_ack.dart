class DeviceAck {
  const DeviceAck({
    required this.commandId,
    required this.deviceId,
    required this.status,
    required this.ackAtMs,
    required this.errorCode,
    this.executedAtMs,
  });

  final String commandId;
  final String deviceId;
  final String status;
  final int ackAtMs;
  final int? executedAtMs;
  final String errorCode;

  Map<String, dynamic> toJson() => {
        'protocol_version': 1,
        'command_id': commandId,
        'device_id': deviceId,
        'status': status,
        'ack_at_ms': ackAtMs,
        if (executedAtMs != null) 'executed_at_ms': executedAtMs,
        'error_code': errorCode,
      };
}
