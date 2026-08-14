import 'dart:math' as math;

import '../models/foot_frame.dart';
import '../models/risk_state.dart';

class LocalRiskResult {
  const LocalRiskResult({
    required this.risk,
    required this.activeRisks,
    required this.baselineReady,
    required this.baselineSamples,
    required this.loadBias,
    required this.loadDiff,
    required this.calibrationStage,
    this.motionState = 'unavailable',
    this.motorTarget,
    this.motorPattern,
    this.temperatureOffsetStatus = const [
      'unstable',
      'unstable',
      'unstable',
      'unstable',
    ],
    this.temperatureRiskEnabled = false,
    this.temperatureRiskReason = 'baseline_not_ready',
  });

  final RiskState risk;
  final List<RiskState> activeRisks;
  final bool baselineReady;
  final int baselineSamples;
  final double? loadBias;
  final double? loadDiff;
  final String calibrationStage;
  final String motionState;
  final String? motorTarget;
  final String? motorPattern;
  final List<String> temperatureOffsetStatus;
  final bool temperatureRiskEnabled;
  final String temperatureRiskReason;
}

class LocalRiskEngine {
  static const ruleVersion = 'local-rules-v6-low-load-baseline';
  static const requiredSamples = 40;
  static const emptyRequiredSamples = 60;
  static const emptyWarmupMs = 15000;
  static const calibrationSampleIntervalMs = 200;
  static const _baselineContactFloor = 0.005;
  static const _baselineMinimumFootLoad = 0.04;
  static const _baselineMinimumActiveChannels = 3;
  static const _runtimeContactFloor = 0.01;
  static const _runtimeMinimumCombinedLoad = 0.08;
  static const _runtimeMinimumActiveChannels = 2;
  static const _pressureAttentionMs = 5000;
  static const _pressureWarningMs = 10000;
  static const _pressurePersistentMs = 20000;
  static const _temperatureAttentionMs = 8000;
  static const _temperatureWarningMs = 15000;
  static const _temperaturePersistentMs = 30000;
  static const _episodeClearMs = 5000;

  final List<double> _loadRatios = [];
  final List<double> _leftForefootRatios = [];
  final List<double> _rightForefootRatios = [];
  final List<List<double?>> _temperatureDeltas = [];
  final Map<String, int> _signalStartedAt = {};
  final Set<String> _latchedSignals = {};
  String? _lastMotorSignature;
  int? _motorClearStartedAt;
  double? _baselineLoadRatio;
  double? _baselineLeftForefoot;
  double? _baselineRightForefoot;
  List<double?> _baselineTemperature = List.filled(4, null);
  final List<List<double?>> _emptyTemperatureDeltas = [];
  int? _emptyStartedAtMs;
  int? _lastEmptySampleAtMs;
  int? _lastBaselineSampleAtMs;
  bool _wearingSeen = false;
  bool _emptyTemperatureReferenceReady = false;
  List<double> _emptyTemperature = List.filled(4, 0.0);
  List<double> _emptyTemperatureMad = List.filled(4, 0.0);
  List<double> _emptyTemperatureSlope = List.filled(4, 0.0);
  List<String> _temperatureOffsetStatus = List.filled(4, 'unstable');
  List<double> _wearingTemperatureMad = List.filled(4, 0.0);
  String? _leftDeviceId;
  String? _rightDeviceId;
  int? _createdAtMs;

  bool get baselineReady => _baselineLoadRatio != null;
  int get baselineSamples => baselineReady
      ? math.max(requiredSamples, _loadRatios.length)
      : _loadRatios.length;
  int? get baselineCreatedAtMs => _createdAtMs;
  String get calibrationStage {
    if (baselineReady) return 'complete';
    if (_wearingSeen) return 'standing_baseline';
    if (_emptyTemperatureReferenceReady) return 'put_on';
    return 'empty_reference';
  }

  void reset() {
    _loadRatios.clear();
    _leftForefootRatios.clear();
    _rightForefootRatios.clear();
    _temperatureDeltas.clear();
    _signalStartedAt.clear();
    _latchedSignals.clear();
    _lastMotorSignature = null;
    _motorClearStartedAt = null;
    _baselineLoadRatio = null;
    _baselineLeftForefoot = null;
    _baselineRightForefoot = null;
    _baselineTemperature = List.filled(4, null);
    _emptyTemperatureDeltas.clear();
    _emptyStartedAtMs = null;
    _lastEmptySampleAtMs = null;
    _lastBaselineSampleAtMs = null;
    _wearingSeen = false;
    _emptyTemperatureReferenceReady = false;
    _emptyTemperature = List.filled(4, 0.0);
    _emptyTemperatureMad = List.filled(4, 0.0);
    _emptyTemperatureSlope = List.filled(4, 0.0);
    _temperatureOffsetStatus = List.filled(4, 'unstable');
    _wearingTemperatureMad = List.filled(4, 0.0);
    _leftDeviceId = null;
    _rightDeviceId = null;
    _createdAtMs = null;
  }

  Map<String, dynamic> exportBaseline() => {
        'rule_version': ruleVersion,
        'ready': baselineReady,
        'sample_count': baselineSamples,
        'load_ratio': _baselineLoadRatio,
        'left_forefoot': _baselineLeftForefoot,
        'right_forefoot': _baselineRightForefoot,
        'temperature_delta': _baselineTemperature,
        'empty_temperature_delta': _emptyTemperature,
        'empty_temperature_mad': _emptyTemperatureMad,
        'empty_temperature_slope': _emptyTemperatureSlope,
        'temperature_offset_status': _temperatureOffsetStatus,
        'wearing_temperature_mad': _wearingTemperatureMad,
        'left_device_id': _leftDeviceId,
        'right_device_id': _rightDeviceId,
        'created_at_ms': _createdAtMs,
      };

  void restoreBaseline(Map<String, dynamic>? value) {
    if (value == null ||
        value['rule_version'] != ruleVersion ||
        value['ready'] != true) {
      return;
    }
    _baselineLoadRatio = (value['load_ratio'] as num?)?.toDouble();
    _baselineLeftForefoot = (value['left_forefoot'] as num?)?.toDouble();
    _baselineRightForefoot = (value['right_forefoot'] as num?)?.toDouble();
    _leftDeviceId = value['left_device_id'] as String?;
    _rightDeviceId = value['right_device_id'] as String?;
    _createdAtMs = value['created_at_ms'] as int?;
    final temperatures = value['temperature_delta'];
    if (temperatures is List && temperatures.length == 4) {
      _baselineTemperature = temperatures
          .map((item) => (item as num?)?.toDouble())
          .toList(growable: false);
    }
    for (final item in [
      (
        'empty_temperature_delta',
        (List<double> target, num value, int index) =>
            target[index] = value.toDouble(),
      ),
      (
        'empty_temperature_mad',
        (List<double> target, num value, int index) =>
            target[index] = value.toDouble(),
      ),
      (
        'empty_temperature_slope',
        (List<double> target, num value, int index) =>
            target[index] = value.toDouble(),
      ),
      (
        'wearing_temperature_mad',
        (List<double> target, num value, int index) =>
            target[index] = value.toDouble(),
      ),
    ]) {
      final raw = value[item.$1];
      if (raw is List && raw.length == 4) {
        final target = List<double>.filled(4, 0.0);
        for (var index = 0; index < 4; index += 1) {
          if (raw[index] is num) item.$2(target, raw[index] as num, index);
        }
        switch (item.$1) {
          case 'empty_temperature_delta':
            _emptyTemperature = target;
          case 'empty_temperature_mad':
            _emptyTemperatureMad = target;
          case 'empty_temperature_slope':
            _emptyTemperatureSlope = target;
          case 'wearing_temperature_mad':
            _wearingTemperatureMad = target;
        }
      }
    }
    final statuses = value['temperature_offset_status'];
    if (statuses is List && statuses.length == 4) {
      _temperatureOffsetStatus =
          statuses.map((item) => item.toString()).toList(growable: false);
      _emptyTemperatureReferenceReady = _temperatureOffsetStatus.any(
        (item) => item != 'unstable' && item != 'raw_invalid',
      );
    }
  }

  LocalRiskResult evaluate(List<FootFrame> pair) {
    final left = pair.firstWhere((frame) => frame.side == 'left');
    final right = pair.firstWhere((frame) => frame.side == 'right');
    if (baselineReady &&
        (_leftDeviceId != null || _rightDeviceId != null) &&
        (_leftDeviceId != left.deviceId || _rightDeviceId != right.deviceId)) {
      reset();
    }
    final timestamp = math.max(left.timestampMs, right.timestampMs);
    final motionState =
        _stationary(left) && _stationary(right) ? 'stationary' : 'moving';
    final leftTotal = _validTotal(left);
    final rightTotal = _validTotal(right);
    final baselineContact =
        _hasBaselineContact(left) && _hasBaselineContact(right);
    final runtimeContact =
        leftTotal + rightTotal >= _runtimeMinimumCombinedLoad &&
            (_hasRuntimeContact(left) || _hasRuntimeContact(right));
    final pressureAvailable =
        _validCount(left, 6, false) >= 4 && _validCount(right, 6, false) >= 4;
    final loadRatio = math.log((leftTotal + 1e-6) / (rightTotal + 1e-6));
    final leftForefoot = _forefootRatio(left);
    final rightForefoot = _forefootRatio(right);

    if (!_emptyTemperatureReferenceReady && !_wearingSeen && !baselineContact) {
      _emptyStartedAtMs ??= timestamp;
      if (timestamp - _emptyStartedAtMs! >= emptyWarmupMs &&
          _calibrationSampleDue(timestamp, _lastEmptySampleAtMs)) {
        _emptyTemperatureDeltas.add(_temperatureDelta(left, right));
        _lastEmptySampleAtMs = timestamp;
        if (_emptyTemperatureDeltas.length >= emptyRequiredSamples) {
          _finishEmptyTemperatureReference();
        }
      }
    }
    if (baselineContact) {
      _wearingSeen = true;
    }

    if (!baselineReady &&
        left.pressureChannelsValid &&
        right.pressureChannelsValid &&
        baselineContact &&
        _stationary(left) &&
        _stationary(right) &&
        _calibrationSampleDue(timestamp, _lastBaselineSampleAtMs)) {
      _loadRatios.add(loadRatio);
      _leftForefootRatios.add(leftForefoot);
      _rightForefootRatios.add(rightForefoot);
      _temperatureDeltas.add(_temperatureDelta(left, right));
      _lastBaselineSampleAtMs = timestamp;
      if (_loadRatios.length >= requiredSamples) {
        if (_mad(_loadRatios) <= 0.12 &&
            _mad(_leftForefootRatios) <= 0.08 &&
            _mad(_rightForefootRatios) <= 0.08) {
          _baselineLoadRatio = _median(_loadRatios);
          _baselineLeftForefoot = _median(_leftForefootRatios);
          _baselineRightForefoot = _median(_rightForefootRatios);
          _leftDeviceId = left.deviceId;
          _rightDeviceId = right.deviceId;
          _createdAtMs = timestamp;
          _baselineTemperature = List.generate(4, (index) {
            final values = _temperatureDeltas
                .map((row) => row[index])
                .whereType<double>()
                .toList();
            return values.isEmpty ? null : _median(values);
          }, growable: false);
          _wearingTemperatureMad = List.generate(4, (index) {
            final values = _temperatureDeltas
                .map((row) => row[index])
                .whereType<double>()
                .toList();
            return values.isEmpty ? 0.0 : _mad(values);
          }, growable: false);
        } else if (_loadRatios.length >= 60) {
          _loadRatios.removeAt(0);
          _leftForefootRatios.removeAt(0);
          _rightForefootRatios.removeAt(0);
          _temperatureDeltas.removeAt(0);
        }
      }
    }

    if (!baselineReady) {
      _signalStartedAt.clear();
      _latchedSignals.clear();
      _lastMotorSignature = null;
      return LocalRiskResult(
        risk: const RiskState(
          riskType: 'normal',
          riskSide: 'none',
          riskLevel: 0,
          durationMs: 0,
        ),
        activeRisks: const [],
        baselineReady: baselineReady,
        baselineSamples: baselineSamples,
        loadBias: baselineReady ? loadRatio - _baselineLoadRatio! : null,
        loadDiff: (leftTotal - rightTotal).abs(),
        calibrationStage: calibrationStage,
        motionState: motionState,
        temperatureOffsetStatus: List.unmodifiable(_temperatureOffsetStatus),
        temperatureRiskEnabled: false,
        temperatureRiskReason: 'baseline_not_ready',
      );
    }

    final candidates =
        <String, ({String type, String side, bool enter, bool stay})>{};
    final temperature = _temperatureDelta(left, right);
    final validTemperatureZones = [
      for (var index = 0; index < 4; index += 1)
        if (temperature[index] != null &&
            _baselineTemperature[index] != null &&
            _temperatureOffsetStatus[index] != 'unstable' &&
            _temperatureOffsetStatus[index] != 'raw_invalid')
          index,
    ];
    for (var index = 0; index < 4; index += 1) {
      final current = temperature[index];
      final baseline = _baselineTemperature[index];
      final status = _temperatureOffsetStatus[index];
      if (current == null ||
          baseline == null ||
          status == 'unstable' ||
          status == 'raw_invalid') {
        continue;
      }
      final corrected = current - baseline;
      final enterThreshold = math.max(2.5, 3 * _wearingTemperatureMad[index]);
      final stayThreshold = math.max(2.0, 2 * _wearingTemperatureMad[index]);
      final absoluteEnter = status == 'normal_offset' && current.abs() >= 2.5;
      final absoluteStay = status == 'normal_offset' && current.abs() >= 2.0;
      final relativeEvidence = corrected.abs() >= stayThreshold;
      candidates['temperature_$index'] = (
        type: 'temperature_asymmetry',
        side: (relativeEvidence ? corrected : current) >= 0 ? 'left' : 'right',
        enter: validTemperatureZones.length >= 2 &&
            (corrected.abs() >= enterThreshold || absoluteEnter),
        stay: validTemperatureZones.length >= 2 &&
            (corrected.abs() >= stayThreshold || absoluteStay),
      );
    }
    final adjustedBias = loadRatio - _baselineLoadRatio!;
    if (pressureAvailable && runtimeContact) {
      candidates['bias'] = (
        type: adjustedBias >= 0 ? 'left_load_bias' : 'right_load_bias',
        side: adjustedBias >= 0 ? 'left' : 'right',
        enter: adjustedBias.abs() >= 0.405,
        stay: adjustedBias.abs() >= 0.323,
      );
      final leftDelta = leftForefoot - _baselineLeftForefoot!;
      final rightDelta = rightForefoot - _baselineRightForefoot!;
      candidates['forefoot_left'] = (
        type: 'forefoot_high',
        side: 'left',
        enter: leftDelta >= 0.08 && _forefootSupported(left),
        stay: leftDelta >= 0.05 && _forefootSupported(left),
      );
      candidates['forefoot_right'] = (
        type: 'forefoot_high',
        side: 'right',
        enter: rightDelta >= 0.08 && _forefootSupported(right),
        stay: rightDelta >= 0.05 && _forefootSupported(right),
      );
    }

    final active = <RiskState>[];
    for (final entry in candidates.entries) {
      final key = entry.key;
      final signal = entry.value;
      final isLatched = _latchedSignals.contains(key);
      if ((isLatched && signal.stay) || (!isLatched && signal.enter)) {
        _latchedSignals.add(key);
        _signalStartedAt.putIfAbsent(key, () => timestamp);
        final duration = math.max(0, timestamp - _signalStartedAt[key]!);
        final temperatureRisk = signal.type == 'temperature_asymmetry';
        final attention =
            temperatureRisk ? _temperatureAttentionMs : _pressureAttentionMs;
        if (duration >= attention) {
          final warning =
              temperatureRisk ? _temperatureWarningMs : _pressureWarningMs;
          final persistent = temperatureRisk
              ? _temperaturePersistentMs
              : _pressurePersistentMs;
          active.add(
            RiskState(
              riskType: signal.type,
              riskSide: signal.side,
              riskLevel:
                  duration < warning ? 1 : (duration < persistent ? 2 : 3),
              durationMs: duration,
            ),
          );
        }
      } else {
        _latchedSignals.remove(key);
        _signalStartedAt.remove(key);
      }
    }

    active.sort((a, b) {
      final priority = _riskPriority(b).compareTo(_riskPriority(a));
      return priority != 0 ? priority : b.riskLevel.compareTo(a.riskLevel);
    });
    final primary = active.isEmpty
        ? const RiskState(
            riskType: 'normal',
            riskSide: 'none',
            riskLevel: 0,
            durationMs: 0,
          )
        : active.first;
    String? target;
    String? pattern;
    final motorRisks = motionState == 'stationary'
        ? active.where((item) => item.riskLevel >= 3).toList()
        : <RiskState>[];
    if (motorRisks.isNotEmpty) {
      final sides = motorRisks.map((item) => item.riskSide).toSet();
      target =
          sides.length > 1 || sides.contains('both') ? 'both' : sides.first;
      pattern = 'long';
      final signature = motorRisks
          .map((item) => '${item.riskType}:${item.riskSide}')
          .join('|');
      _motorClearStartedAt = null;
      if (_lastMotorSignature != null) {
        target = null;
        pattern = null;
      } else {
        _lastMotorSignature = signature;
      }
    } else {
      _motorClearStartedAt ??= timestamp;
      if (timestamp - _motorClearStartedAt! >= _episodeClearMs) {
        _lastMotorSignature = null;
        _motorClearStartedAt = null;
      }
    }
    return LocalRiskResult(
      risk: primary,
      activeRisks: active,
      baselineReady: true,
      baselineSamples: baselineSamples,
      loadBias: adjustedBias,
      loadDiff: (leftTotal - rightTotal).abs(),
      calibrationStage: calibrationStage,
      motionState: motionState,
      motorTarget: target,
      motorPattern: pattern,
      temperatureOffsetStatus: List.unmodifiable(_temperatureOffsetStatus),
      temperatureRiskEnabled: validTemperatureZones.length >= 2,
      temperatureRiskReason: validTemperatureZones.length >= 2
          ? 'ready'
          : 'fewer_than_two_trusted_channels',
    );
  }

  static int _riskPriority(RiskState risk) => risk.isPressure
      ? pressureRiskPriority(risk.riskType)
      : risk.isTemperature
          ? 0
          : -1;

  bool _calibrationSampleDue(int timestampMs, int? lastSampleAtMs) =>
      lastSampleAtMs == null ||
      timestampMs - lastSampleAtMs >= calibrationSampleIntervalMs;

  void _finishEmptyTemperatureReference() {
    _emptyTemperature = List.generate(4, (index) {
      final values = _emptyTemperatureDeltas
          .map((row) => row[index])
          .whereType<double>()
          .toList();
      return values.isEmpty ? 0.0 : _median(values);
    }, growable: false);
    _emptyTemperatureMad = List.generate(4, (index) {
      final values = _emptyTemperatureDeltas
          .map((row) => row[index])
          .whereType<double>()
          .toList();
      return values.isEmpty ? 0.0 : _mad(values);
    }, growable: false);
    _emptyTemperatureSlope = List.generate(4, (index) {
      final values = _emptyTemperatureDeltas
          .map((row) => row[index])
          .whereType<double>()
          .toList();
      return values.length < requiredSamples
          ? 0.0
          : (values.last - values.first) / 12.0;
    }, growable: false);
    _temperatureOffsetStatus = List.generate(4, (index) {
      final values = _emptyTemperatureDeltas
          .map((row) => row[index])
          .whereType<double>()
          .toList();
      if (values.length < requiredSamples) return 'raw_invalid';
      final stable = _emptyTemperatureMad[index] <= 0.6 &&
          _emptyTemperatureSlope[index].abs() <= 0.05;
      if (!stable) return 'unstable';
      return _emptyTemperature[index].abs() >= 2.2
          ? 'assembly_offset'
          : 'normal_offset';
    }, growable: false);
    _emptyTemperatureReferenceReady = true;
  }

  static int _validCount(FootFrame frame, int count, bool temperature) =>
      List.generate(
        count,
        (index) => temperature
            ? frame.temperatureChannelValid(index)
            : frame.pressureChannelValid(index),
      ).where((value) => value).length;

  static double _validTotal(FootFrame frame) => List.generate(
        6,
        (index) =>
            frame.pressureChannelValid(index) ? frame.pressure[index] : 0.0,
      ).fold(0.0, (sum, value) => sum + value);

  static bool _hasBaselineContact(FootFrame frame) =>
      _validTotal(frame) >= _baselineMinimumFootLoad &&
      _activePressureChannels(frame, _baselineContactFloor) >=
          _baselineMinimumActiveChannels;

  static bool _hasRuntimeContact(FootFrame frame) =>
      _activePressureChannels(frame, _runtimeContactFloor) >=
      _runtimeMinimumActiveChannels;

  static int _activePressureChannels(FootFrame frame, double floor) =>
      List.generate(
        6,
        (index) =>
            frame.pressureChannelValid(index) && frame.pressure[index] >= floor,
      ).where((value) => value).length;

  static double _forefootRatio(FootFrame frame) {
    final total = _validTotal(frame);
    if (total <= 1e-9) return 0;
    return List.generate(
          4,
          (index) =>
              frame.pressureChannelValid(index) ? frame.pressure[index] : 0.0,
        ).fold(0.0, (sum, value) => sum + value) /
        total;
  }

  static bool _forefootSupported(FootFrame frame) =>
      List.generate(
            4,
            (index) =>
                frame.pressureChannelValid(index) &&
                frame.pressure[index] >= _runtimeContactFloor,
          ).where((value) => value).length >=
          2 &&
      List.generate(
        2,
        (index) => frame.pressureChannelValid(index + 4),
      ).any((value) => value);

  static List<double?> _temperatureDelta(FootFrame left, FootFrame right) =>
      List.generate(4, (index) {
        if (!left.temperatureChannelValid(index) ||
            !right.temperatureChannelValid(index)) {
          return null;
        }
        return left.temperature[index] - right.temperature[index];
      }, growable: false);

  static double _median(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  static double _mad(List<double> values) {
    final middle = _median(values);
    return _median(values.map((value) => (value - middle).abs()).toList());
  }

  static bool _stationary(FootFrame frame) {
    if (frame.qualityFlags & 0x400 != 0) return true;
    final acceleration = math.sqrt(
      frame.imu.ax * frame.imu.ax +
          frame.imu.ay * frame.imu.ay +
          frame.imu.az * frame.imu.az,
    );
    final gyroMaximum = [
      frame.imu.gx,
      frame.imu.gy,
      frame.imu.gz,
    ].map((value) => value.abs()).reduce(math.max);
    return (acceleration - 9.80665).abs() <= 3.0 && gyroMaximum <= 12.0;
  }
}
