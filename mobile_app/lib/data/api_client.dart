import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_advice.dart';
import '../models/ai_chat_answer.dart';
import '../models/ai_question_answer.dart';
import '../models/device_command.dart';
import '../models/device_ack.dart';
import '../models/foot_frame.dart';
import '../models/regional_analysis.dart';
import '../models/risk_state.dart';
import '../models/session_advice.dart';
import '../models/offline_intervention.dart';

class RealtimeSnapshot {
  const RealtimeSnapshot({
    required this.left,
    required this.right,
    required this.loadBias,
    required this.loadDiff,
    required this.syncErrorMs,
    this.motionState = 'unavailable',
    this.leftMotionState = 'unavailable',
    this.rightMotionState = 'unavailable',
    this.pressureAvailable = false,
    this.temperatureAvailable = false,
    required this.risk,
    this.activeRisks = const [],
    required this.regionalAnalysis,
    this.recoveryObservation,
  });

  final FootFrame? left;
  final FootFrame? right;
  final double? loadBias;
  final double? loadDiff;
  final int? syncErrorMs;
  final String motionState;
  final String leftMotionState;
  final String rightMotionState;
  final bool pressureAvailable;
  final bool temperatureAvailable;
  final RiskState risk;
  final List<RiskState> activeRisks;
  final RegionalAnalysis? regionalAnalysis;
  final RecoveryObservation? recoveryObservation;

  factory RealtimeSnapshot.fromJson(Map<String, dynamic> json) =>
      RealtimeSnapshot(
        left: json['left'] == null
            ? null
            : FootFrame.fromJson(json['left'] as Map<String, dynamic>),
        right: json['right'] == null
            ? null
            : FootFrame.fromJson(json['right'] as Map<String, dynamic>),
        loadBias: (json['load_bias'] as num?)?.toDouble(),
        loadDiff: (json['load_diff'] as num?)?.toDouble(),
        syncErrorMs: json['sync_error_ms'] as int?,
        motionState: json['motion_state'] as String? ?? 'unavailable',
        leftMotionState: json['left_motion_state'] as String? ?? 'unavailable',
        rightMotionState:
            json['right_motion_state'] as String? ?? 'unavailable',
        pressureAvailable: json['pressure_available'] as bool? ?? false,
        temperatureAvailable: json['temperature_available'] as bool? ?? false,
        risk: RiskState.fromJson(json['risk'] as Map<String, dynamic>),
        activeRisks: (json['active_risks'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(RiskState.fromJson)
                .toList(growable: false) ??
            const [],
        regionalAnalysis: json['regional_analysis'] == null
            ? null
            : RegionalAnalysis.fromJson(
                json['regional_analysis'] as Map<String, dynamic>,
              ),
        recoveryObservation: json['recovery_observation'] == null
            ? null
            : RecoveryObservation.fromJson(
                json['recovery_observation'] as Map<String, dynamic>,
              ),
      );
}

class RecoveryObservation {
  const RecoveryObservation({
    required this.eventId,
    required this.status,
    required this.startedAtMs,
    required this.deadlineAtMs,
    required this.remainingMs,
    this.effectLabel,
  });

  final String eventId;
  final String status;
  final int startedAtMs;
  final int deadlineAtMs;
  final int remainingMs;
  final String? effectLabel;

  factory RecoveryObservation.fromJson(Map<String, dynamic> json) =>
      RecoveryObservation(
        eventId: json['event_id'] as String,
        status: json['status'] as String,
        startedAtMs: json['started_at_ms'] as int,
        deadlineAtMs: json['deadline_at_ms'] as int,
        remainingMs: json['remaining_ms'] as int,
        effectLabel: json['effect_label'] as String?,
      );
}

class RiskEventRecord {
  const RiskEventRecord({
    required this.eventId,
    required this.riskType,
    required this.riskSide,
    required this.riskLevel,
    required this.startedAtMs,
    required this.durationMs,
    required this.status,
    this.endedAtMs,
    this.beforeLoadDiff,
    this.afterLoadDiff,
    this.interventionAction,
    this.effectLabel,
    this.recoveryTimeMs,
    this.activeRisks = const [],
  });

  final String eventId;
  final String riskType;
  final String riskSide;
  final int riskLevel;
  final int startedAtMs;
  final int? endedAtMs;
  final int durationMs;
  final double? beforeLoadDiff;
  final double? afterLoadDiff;
  final String? interventionAction;
  final String? effectLabel;
  final int? recoveryTimeMs;
  final List<RiskState> activeRisks;
  final String status;

  bool get hasLoadDiffComparison =>
      beforeLoadDiff != null && afterLoadDiff != null;

  double? get loadDiffImprovementRatio {
    final before = beforeLoadDiff;
    final after = afterLoadDiff;
    if (before == null || after == null || before <= 0) {
      return null;
    }
    return (before - after) / before;
  }

  factory RiskEventRecord.fromJson(Map<String, dynamic> json) =>
      RiskEventRecord(
        eventId: json['event_id'] as String,
        riskType: json['risk_type'] as String,
        riskSide: json['risk_side'] as String,
        riskLevel: json['risk_level'] as int,
        startedAtMs: json['started_at_ms'] as int,
        endedAtMs: json['ended_at_ms'] as int?,
        durationMs: json['duration_ms'] as int,
        beforeLoadDiff: (json['before_load_diff'] as num?)?.toDouble(),
        afterLoadDiff: (json['after_load_diff'] as num?)?.toDouble(),
        interventionAction: json['intervention_action'] as String?,
        effectLabel: json['effect_label'] as String?,
        recoveryTimeMs: json['recovery_time_ms'] as int?,
        activeRisks: (json['active_risks'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .map(RiskState.fromJson)
                .toList(growable: false) ??
            const [],
        status: json['status'] as String,
      );
}

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CalibrationStatus {
  const CalibrationStatus({
    required this.baselineReady,
    required this.sampleCount,
    required this.requiredSamples,
    this.resetAtMs,
    this.statusReason = 'waiting_for_data',
  });

  final bool baselineReady;
  final int sampleCount;
  final int requiredSamples;
  final int? resetAtMs;
  final String statusReason;

  double get progress => requiredSamples <= 0
      ? 0.0
      : (sampleCount / requiredSamples).clamp(0, 1).toDouble();

  factory CalibrationStatus.fromJson(Map<String, dynamic> json) =>
      CalibrationStatus(
        baselineReady: json['baseline_ready'] as bool,
        sampleCount: json['sample_count'] as int,
        requiredSamples: json['required_samples'] as int,
        resetAtMs: json['reset_at_ms'] as int?,
        statusReason: json['status_reason'] as String? ?? 'waiting_for_data',
      );
}

class FootGuardApiClient {
  FootGuardApiClient({required String baseUrl, http.Client? client})
      : baseUrl = baseUrl.replaceFirst(RegExp(r'/$'), ''),
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  int _serverClockOffsetMs = 0;
  bool _hasServerClockOffset = false;

  int get serverNowMs =>
      DateTime.now().millisecondsSinceEpoch +
      (_hasServerClockOffset ? _serverClockOffsetMs : 0);

  bool get hasServerClockOffset => _hasServerClockOffset;

  Future<dynamic> _decode(http.Response response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('HTTP ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<bool> health() async {
    final requestedAtMs = DateTime.now().millisecondsSinceEpoch;
    final response = await _client
        .get(Uri.parse('$baseUrl/health'))
        .timeout(const Duration(seconds: 5));
    final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
    final body = await _decode(response) as Map<String, dynamic>;
    final serverTimeMs = body['server_time_ms'];
    if (serverTimeMs is int) {
      final localMidpointMs =
          requestedAtMs + ((receivedAtMs - requestedAtMs) ~/ 2);
      _serverClockOffsetMs = serverTimeMs - localMidpointMs;
      _hasServerClockOffset = true;
    }
    return body['status'] == 'ok';
  }

  Future<int> serverTimeMs({bool refresh = false}) async {
    if (refresh || !_hasServerClockOffset) {
      await health();
    }
    return serverNowMs;
  }

  Future<void> uploadFrames(
    List<FootFrame> frames, {
    bool offlineReplay = false,
  }) async {
    final response = await _client
        .post(
          Uri.parse(
            '$baseUrl/api/v1/sensor/${offlineReplay ? 'offline-sync' : 'batch'}',
          ),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'app_received_at_ms': serverNowMs,
            'frames': frames.map((frame) => frame.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 5));
    await _decode(response);
  }

  Future<void> uploadOfflineInterventions(
    List<OfflineIntervention> records,
  ) async {
    if (records.isEmpty) return;
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/sensor/offline-interventions'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'records': records.map((item) => item.toJson()).toList(),
          }),
        )
        .timeout(const Duration(seconds: 8));
    await _decode(response);
  }

  Future<RealtimeSnapshot> realtime() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/v1/realtime'))
        .timeout(const Duration(seconds: 5));
    return RealtimeSnapshot.fromJson(
        await _decode(response) as Map<String, dynamic>);
  }

  Future<List<RiskEventRecord>> events({int limit = 50}) async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/v1/events?limit=$limit'))
        .timeout(const Duration(seconds: 5));
    final body = await _decode(response) as List<dynamic>;
    return body
        .map((event) => RiskEventRecord.fromJson(event as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<CalibrationStatus> calibrationStatus() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/v1/calibration/status'))
        .timeout(const Duration(seconds: 5));
    return CalibrationStatus.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  Future<CalibrationStatus> resetCalibration() async {
    final response = await _client
        .post(Uri.parse('$baseUrl/api/v1/calibration/reset'))
        .timeout(const Duration(seconds: 5));
    return CalibrationStatus.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  Future<DeviceCommand?> pendingCommand({String? target}) async {
    final query = target == null ? '' : '?target=$target';
    final response = await _client
        .get(Uri.parse('$baseUrl/api/v1/command/pending$query'))
        .timeout(const Duration(seconds: 5));
    final body = await _decode(response) as Map<String, dynamic>;
    return body['command'] == null
        ? null
        : DeviceCommand.fromJson(body['command'] as Map<String, dynamic>);
  }

  Future<void> acknowledgeMotor(DeviceCommand command, String deviceId) async {
    final now = serverNowMs;
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/ack'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'command_id': command.commandId,
            'device_id': deviceId,
            'status': 'executed',
            'ack_at_ms': now,
            'executed_at_ms': now,
            'error_code': 'none',
          }),
        )
        .timeout(const Duration(seconds: 5));
    await _decode(response);
  }

  Future<void> acknowledgeDevice(DeviceAck ack) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/ack'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(ack.toJson()),
        )
        .timeout(const Duration(seconds: 5));
    await _decode(response);
  }

  Future<AiAdvice> aiAdvice({
    required RiskState risk,
    List<RiskState> activeRisks = const [],
    required double? loadDiff,
    required double? temperatureDeltaMaxC,
    required bool baselineReady,
    required bool pressureAvailable,
    required bool temperatureAvailable,
    required bool leftConnected,
    required bool rightConnected,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/ai/advice'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'risk': risk.toJson(),
            'active_risks': activeRisks.map((item) => item.toJson()).toList(),
            'load_diff': loadDiff,
            'temperature_delta_max_c': temperatureDeltaMaxC,
            'baseline_ready': baselineReady,
            'pressure_available': pressureAvailable,
            'temperature_available': temperatureAvailable,
            'left_connected': leftConnected,
            'right_connected': rightConnected,
          }),
        )
        .timeout(const Duration(seconds: 35));
    return AiAdvice.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  Future<AiQuestionAnswer> aiQuestion({
    required String questionKey,
    required RiskState risk,
    List<RiskState> activeRisks = const [],
    required double? loadDiff,
    required double? temperatureDeltaMaxC,
    required bool baselineReady,
    bool pressureAvailable = true,
    bool temperatureAvailable = true,
    bool leftConnected = true,
    bool rightConnected = true,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/ai/question'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'question_key': questionKey,
            'risk': risk.toJson(),
            'active_risks': activeRisks.map((item) => item.toJson()).toList(),
            'load_diff': loadDiff,
            'temperature_delta_max_c': temperatureDeltaMaxC,
            'baseline_ready': baselineReady,
            'pressure_available': pressureAvailable,
            'temperature_available': temperatureAvailable,
            'left_connected': leftConnected,
            'right_connected': rightConnected,
          }),
        )
        .timeout(const Duration(seconds: 35));
    return AiQuestionAnswer.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  Future<AiChatAnswer> aiChat({
    required String question,
    required RiskState risk,
    List<RiskState> activeRisks = const [],
    required double? loadDiff,
    required double? temperatureDeltaMaxC,
    required bool baselineReady,
    required bool pressureAvailable,
    required bool temperatureAvailable,
    required int validTemperaturePairs,
    required String motionState,
    required bool leftConnected,
    required bool rightConnected,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/v1/ai/chat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'protocol_version': 1,
            'question': question,
            'risk': risk.toJson(),
            'active_risks': activeRisks.map((item) => item.toJson()).toList(),
            'load_diff': loadDiff,
            'temperature_delta_max_c': temperatureDeltaMaxC,
            'baseline_ready': baselineReady,
            'pressure_available': pressureAvailable,
            'temperature_available': temperatureAvailable,
            'left_connected': leftConnected,
            'right_connected': rightConnected,
            'valid_temperature_pairs': validTemperaturePairs,
            'motion_state': motionState,
          }),
        )
        .timeout(const Duration(seconds: 35));
    return AiChatAnswer.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  Future<SessionAdvice> sessionAdvice() async {
    final response = await _client
        .post(Uri.parse('$baseUrl/api/v1/ai/session-advice'))
        .timeout(const Duration(seconds: 35));
    return SessionAdvice.fromJson(
      await _decode(response) as Map<String, dynamic>,
    );
  }

  void close() => _client.close();
}
