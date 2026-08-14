import 'device_ack.dart';
import 'device_command.dart';
import 'risk_state.dart';

class OfflineIntervention {
  OfflineIntervention({
    required this.eventId,
    required this.command,
    required this.risk,
    required this.activeRisks,
    required this.startedAtMs,
    List<DeviceAck>? acknowledgements,
    this.beforeLoadDiff,
    this.afterLoadDiff,
    this.effectLabel,
    this.recoveryTimeMs,
  }) : acknowledgements = acknowledgements ?? [];

  final String eventId;
  final DeviceCommand command;
  final RiskState risk;
  final List<RiskState> activeRisks;
  final int startedAtMs;
  final List<DeviceAck> acknowledgements;
  final double? beforeLoadDiff;
  double? afterLoadDiff;
  String? effectLabel;
  int? recoveryTimeMs;

  factory OfflineIntervention.fromJson(Map<String, dynamic> json) =>
      OfflineIntervention(
        eventId: json['event_id'] as String,
        command:
            DeviceCommand.fromJson(json['command'] as Map<String, dynamic>),
        risk: RiskState.fromJson(json['risk'] as Map<String, dynamic>),
        activeRisks: (json['active_risks'] as List<dynamic>)
            .map((item) => RiskState.fromJson(item as Map<String, dynamic>))
            .toList(),
        startedAtMs: json['started_at_ms'] as int,
        acknowledgements: (json['acknowledgements'] as List<dynamic>)
            .map((item) => DeviceAck.fromJson(item as Map<String, dynamic>))
            .toList(),
        beforeLoadDiff: (json['before_load_diff'] as num?)?.toDouble(),
        afterLoadDiff: (json['after_load_diff'] as num?)?.toDouble(),
        effectLabel: json['effect_label'] as String?,
        recoveryTimeMs: json['recovery_time_ms'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'command': command.toJson(),
        'risk': risk.toJson(),
        'active_risks': activeRisks.map((item) => item.toJson()).toList(),
        'started_at_ms': startedAtMs,
        'acknowledgements':
            acknowledgements.map((item) => item.toJson()).toList(),
        'before_load_diff': beforeLoadDiff,
        'after_load_diff': afterLoadDiff,
        'effect_label': effectLabel,
        'recovery_time_ms': recoveryTimeMs,
      };
}
