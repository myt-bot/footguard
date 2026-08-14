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

  factory DeviceAck.fromJson(Map<String, dynamic> json) => DeviceAck(
        commandId: json['command_id'] as String,
        deviceId: json['device_id'] as String,
        status: json['status'] as String,
        ackAtMs: json['ack_at_ms'] as int,
        executedAtMs: json['executed_at_ms'] as int?,
        errorCode: json['error_code'] as String,
      );

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
