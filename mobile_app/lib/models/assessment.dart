class TemperatureDailyRecord {
  const TemperatureDailyRecord({
    required this.recordDate,
    required this.side,
    required this.zone,
    required this.rawDeltaC,
    required this.correctedDeltaC,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.validZoneCount,
    required this.source,
    required this.loadState,
    required this.motionState,
    required this.quality,
    this.demoSessionId,
  });

  final String recordDate;
  final String side;
  final String zone;
  final double rawDeltaC;
  final double correctedDeltaC;
  final int startedAtMs;
  final int endedAtMs;
  final int validZoneCount;
  final String source;
  final String loadState;
  final String motionState;
  final String quality;
  final String? demoSessionId;

  bool get isDemo => source == 'demo';

  factory TemperatureDailyRecord.fromJson(Map<String, dynamic> json) =>
      TemperatureDailyRecord(
        recordDate: json['record_date'] as String? ?? '',
        side: json['side'] as String? ?? 'unknown',
        zone: json['zone'] as String? ?? 'unknown',
        rawDeltaC: (json['raw_delta_c'] as num?)?.toDouble() ?? 0,
        correctedDeltaC: (json['corrected_delta_c'] as num?)?.toDouble() ?? 0,
        startedAtMs: json['started_at_ms'] as int? ?? 0,
        endedAtMs: json['ended_at_ms'] as int? ?? 0,
        validZoneCount: json['valid_zone_count'] as int? ?? 0,
        source: json['source'] as String? ?? 'device_observation',
        loadState: json['load_state'] as String? ?? 'unknown',
        motionState: json['motion_state'] as String? ?? 'unknown',
        quality: json['quality'] as String? ?? 'unknown',
        demoSessionId: json['demo_session_id'] as String?,
      );
}

class TemperatureEvidence {
  const TemperatureEvidence({
    this.realDays = 0,
    this.realConsecutiveDays = 0,
    this.demoDays = 0,
    this.status = 'no_data',
    this.records = const [],
  });

  final int realDays;
  final int realConsecutiveDays;
  final int demoDays;
  final String status;
  final List<TemperatureDailyRecord> records;

  factory TemperatureEvidence.fromJson(Map<String, dynamic> json) =>
      TemperatureEvidence(
        realDays: json['real_days'] as int? ?? 0,
        realConsecutiveDays: json['real_consecutive_days'] as int? ?? 0,
        demoDays: json['demo_days'] as int? ?? 0,
        status: json['status'] as String? ?? 'no_data',
        records: (json['records'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(TemperatureDailyRecord.fromJson)
            .toList(growable: false),
      );
}

class MonitoringRating {
  const MonitoringRating({
    this.rating = 'insufficient_data',
    this.level = 0,
    this.label = '数据不足',
    this.trend = 'unavailable',
    this.trendLabel = '暂无可比较的上一次会话',
    this.evidence = const [],
    this.dataQuality = const [],
    this.sessionId,
    this.previousSessionId,
    this.isDemoOnly = false,
  });

  final String rating;
  final int level;
  final String label;
  final String trend;
  final String trendLabel;
  final List<String> evidence;
  final List<String> dataQuality;
  final String? sessionId;
  final String? previousSessionId;
  final bool isDemoOnly;

  factory MonitoringRating.fromJson(Map<String, dynamic> json) =>
      MonitoringRating(
        rating: json['rating'] as String? ?? 'insufficient_data',
        level: json['level'] as int? ?? 0,
        label: json['label'] as String? ?? '数据不足',
        trend: json['trend'] as String? ?? 'unavailable',
        trendLabel: json['trend_label'] as String? ?? '暂无可比较的上一次会话',
        evidence: (json['evidence'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        dataQuality: (json['data_quality'] as List<dynamic>? ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        sessionId: json['session_id'] as String?,
        previousSessionId: json['previous_session_id'] as String?,
        isDemoOnly: json['is_demo_only'] as bool? ?? false,
      );
}

class HealthProfile {
  const HealthProfile({
    this.ulcerOrAmputation = 'unknown',
    this.sensoryOrCirculationIssue = 'unknown',
    this.completeness = 'incomplete',
  });

  final String ulcerOrAmputation;
  final String sensoryOrCirculationIssue;
  final String completeness;

  factory HealthProfile.fromJson(Map<String, dynamic> json) => HealthProfile(
        ulcerOrAmputation: json['ulcer_or_amputation'] as String? ?? 'unknown',
        sensoryOrCirculationIssue:
            json['sensory_or_circulation_issue'] as String? ?? 'unknown',
        completeness: json['completeness'] as String? ?? 'incomplete',
      );

  Map<String, dynamic> toJson() => {
        'ulcer_or_amputation': ulcerOrAmputation,
        'sensory_or_circulation_issue': sensoryOrCirculationIssue,
      };
}

class GlucoseReading {
  const GlucoseReading({
    required this.value,
    required this.unit,
    required this.context,
    required this.measuredAtMs,
    this.note,
    this.readingId,
  });

  final double value;
  final String unit;
  final String context;
  final int measuredAtMs;
  final String? note;
  final String? readingId;

  factory GlucoseReading.fromJson(Map<String, dynamic> json) => GlucoseReading(
        readingId: json['reading_id'] as String?,
        value: (json['value'] as num?)?.toDouble() ?? 0,
        unit: json['unit'] as String? ?? 'mmol/L',
        context: json['context'] as String? ?? 'random',
        measuredAtMs: json['measured_at_ms'] as int? ?? 0,
        note: json['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'value': value,
        'unit': unit,
        'context': context,
        'measured_at_ms': measuredAtMs,
        'note': note,
      };
}

class AssessmentSummary {
  const AssessmentSummary({
    required this.rating,
    this.previousRating,
    this.temperature = const TemperatureEvidence(),
    this.healthProfile = const HealthProfile(),
    this.glucoseReadings = const [],
  });

  final MonitoringRating rating;
  final MonitoringRating? previousRating;
  final TemperatureEvidence temperature;
  final HealthProfile healthProfile;
  final List<GlucoseReading> glucoseReadings;

  factory AssessmentSummary.fromJson(Map<String, dynamic> json) =>
      AssessmentSummary(
        rating: MonitoringRating.fromJson(
          json['rating'] as Map<String, dynamic>? ?? const {},
        ),
        previousRating: json['previous_rating'] == null
            ? null
            : MonitoringRating.fromJson(
                json['previous_rating'] as Map<String, dynamic>,
              ),
        temperature: TemperatureEvidence.fromJson(
          json['temperature'] as Map<String, dynamic>? ?? const {},
        ),
        healthProfile: HealthProfile.fromJson(
          json['health_profile'] as Map<String, dynamic>? ?? const {},
        ),
        glucoseReadings:
            (json['glucose_readings'] as List<dynamic>? ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(GlucoseReading.fromJson)
                .toList(growable: false),
      );
}

class TemperatureDemoState {
  const TemperatureDemoState({
    this.active = false,
    this.demoSessionId,
    this.seedDate,
    this.currentDate,
    this.status = 'inactive',
  });

  final bool active;
  final String? demoSessionId;
  final String? seedDate;
  final String? currentDate;
  final String status;

  factory TemperatureDemoState.fromJson(Map<String, dynamic> json) =>
      TemperatureDemoState(
        active: json['active'] as bool? ?? false,
        demoSessionId: json['demo_session_id'] as String?,
        seedDate: json['seed_date'] as String?,
        currentDate: json['current_date'] as String?,
        status: json['status'] as String? ?? 'inactive',
      );
}
