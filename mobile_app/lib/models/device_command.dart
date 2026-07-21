class DeviceCommand {
  const DeviceCommand({
    required this.commandId,
    required this.target,
    required this.pattern,
    required this.durationMs,
    required this.expireAtMs,
    required this.reasonCode,
  });

  final String commandId;
  final String target;
  final String pattern;
  final int durationMs;
  final int expireAtMs;
  final String reasonCode;

  factory DeviceCommand.fromJson(Map<String, dynamic> json) => DeviceCommand(
        commandId: json['command_id'] as String,
        target: json['target'] as String,
        pattern: json['pattern'] as String,
        durationMs: json['duration_ms'] as int,
        expireAtMs: json['expire_at_ms'] as int,
        reasonCode: json['reason_code'] as String,
      );

  Map<String, dynamic> toJson() => {
        'protocol_version': 1,
        'command_id': commandId,
        'target': target,
        'pattern': pattern,
        'duration_ms': durationMs,
        'expire_at_ms': expireAtMs,
        'reason_code': reasonCode,
      };

  bool get expired => DateTime.now().millisecondsSinceEpoch >= expireAtMs;
}
