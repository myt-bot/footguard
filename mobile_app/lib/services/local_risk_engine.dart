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
    this.motorTarget,
    this.motorPattern,
  });

  final RiskState risk;
  final List<RiskState> activeRisks;
  final bool baselineReady;
  final int baselineSamples;
  final double? loadBias;
  final double? loadDiff;
  final String? motorTarget;
  final String? motorPattern;
}

class LocalRiskEngine {
  static const ruleVersion = 'local-rules-v1';
  static const requiredSamples = 40;
  static const _contactFloor = 0.01;
  static const _minimumFootLoad = 0.08;

  final List<double> _loadRatios = [];
  final List<double> _leftForefootRatios = [];
  final List<double> _rightForefootRatios = [];
  final List<List<double?>> _temperatureDeltas = [];
  final Map<String, int> _signalStartedAt = {};
  final Set<String> _latchedSignals = {};
  String? _lastMotorSignature;
  double? _baselineLoadRatio;
  double? _baselineLeftForefoot;
  double? _baselineRightForefoot;
  List<double?> _baselineTemperature = List.filled(4, null);
  String? _leftDeviceId;
  String? _rightDeviceId;
  int? _createdAtMs;

  bool get baselineReady => _baselineLoadRatio != null;
  int get baselineSamples => baselineReady
      ? math.max(requiredSamples, _loadRatios.length)
      : _loadRatios.length;
  int? get baselineCreatedAtMs => _createdAtMs;

  void reset() {
    _loadRatios.clear();
    _leftForefootRatios.clear();
    _rightForefootRatios.clear();
    _temperatureDeltas.clear();
    _signalStartedAt.clear();
    _latchedSignals.clear();
    _lastMotorSignature = null;
    _baselineLoadRatio = null;
    _baselineLeftForefoot = null;
    _baselineRightForefoot = null;
    _baselineTemperature = List.filled(4, null);
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
    final leftTotal = _validTotal(left);
    final rightTotal = _validTotal(right);
    final contact = _hasContact(left) && _hasContact(right);
    final pressureAvailable =
        _validCount(left, 6, false) >= 4 && _validCount(right, 6, false) >= 4;
    final loadRatio = math.log((leftTotal + 1e-6) / (rightTotal + 1e-6));
    final leftForefoot = _forefootRatio(left);
    final rightForefoot = _forefootRatio(right);

    if (!baselineReady &&
        left.pressureChannelsValid &&
        right.pressureChannelsValid &&
        contact &&
        _stationary(left) &&
        _stationary(right)) {
      _loadRatios.add(loadRatio);
      _leftForefootRatios.add(leftForefoot);
      _rightForefootRatios.add(rightForefoot);
      _temperatureDeltas.add(_temperatureDelta(left, right));
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
        } else if (_loadRatios.length >= 60) {
          _loadRatios.removeAt(0);
          _leftForefootRatios.removeAt(0);
          _rightForefootRatios.removeAt(0);
          _temperatureDeltas.removeAt(0);
        }
      }
    }

    if (!baselineReady || !pressureAvailable || !contact) {
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
      );
    }

    final candidates =
        <String, ({String type, String side, bool enter, bool stay})>{};
    final adjustedBias = loadRatio - _baselineLoadRatio!;
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
    final temperature = _temperatureDelta(left, right);
    for (var index = 0; index < 4; index += 1) {
      final current = temperature[index];
      final baseline = _baselineTemperature[index];
      if (current == null || baseline == null) continue;
      final corrected = current - baseline;
      candidates['temperature_$index'] = (
        type: 'temperature_asymmetry',
        side: current >= 0 ? 'left' : 'right',
        enter: corrected.abs() >= 2.5 && current.abs() >= 1.0,
        stay: corrected.abs() >= 2.0 && current.abs() >= 1.0,
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
        final attention = temperatureRisk ? 3000 : 2000;
        if (duration >= attention) {
          final warning = temperatureRisk ? 6000 : 4000;
          final persistent = temperatureRisk ? 10000 : 7000;
          active.add(RiskState(
            riskType: signal.type,
            riskSide: signal.side,
            riskLevel: duration < warning ? 1 : (duration < persistent ? 2 : 3),
            durationMs: duration,
          ));
        }
      } else {
        _latchedSignals.remove(key);
        _signalStartedAt.remove(key);
      }
    }

    active.sort((a, b) => b.riskLevel.compareTo(a.riskLevel));
    final primary = active.isEmpty
        ? const RiskState(
            riskType: 'normal', riskSide: 'none', riskLevel: 0, durationMs: 0)
        : active.first;
    String? target;
    String? pattern;
    final motorRisks = active.where((item) => item.riskLevel >= 2).toList();
    if (motorRisks.isNotEmpty) {
      final sides = motorRisks.map((item) => item.riskSide).toSet();
      target =
          sides.length > 1 || sides.contains('both') ? 'both' : sides.first;
      pattern = motorRisks.any((item) => item.riskType == 'forefoot_high')
          ? 'long'
          : motorRisks.any((item) => item.riskType.contains('load_bias'))
              ? 'double'
              : 'short';
      final signature = motorRisks
          .map((item) => '${item.riskType}:${item.riskSide}:${item.riskLevel}')
          .join('|');
      if (_lastMotorSignature == signature) {
        target = null;
        pattern = null;
      } else {
        _lastMotorSignature = signature;
      }
    } else {
      _lastMotorSignature = null;
    }
    return LocalRiskResult(
      risk: primary,
      activeRisks: active,
      baselineReady: true,
      baselineSamples: baselineSamples,
      loadBias: adjustedBias,
      loadDiff: (leftTotal - rightTotal).abs(),
      motorTarget: target,
      motorPattern: pattern,
    );
  }

  static int _validCount(FootFrame frame, int count, bool temperature) =>
      List.generate(
              count,
              (index) => temperature
                  ? frame.temperatureChannelValid(index)
                  : frame.pressureChannelValid(index))
          .where((value) => value)
          .length;

  static double _validTotal(FootFrame frame) => List.generate(
        6,
        (index) =>
            frame.pressureChannelValid(index) ? frame.pressure[index] : 0.0,
      ).fold(0.0, (sum, value) => sum + value);

  static bool _hasContact(FootFrame frame) =>
      _validTotal(frame) >= _minimumFootLoad &&
      List.generate(
                  6,
                  (index) =>
                      frame.pressureChannelValid(index) &&
                      frame.pressure[index] >= _contactFloor)
              .where((value) => value)
              .length >=
          2;

  static double _forefootRatio(FootFrame frame) {
    final total = _validTotal(frame);
    if (total <= 1e-9) return 0;
    return List.generate(
            4,
            (index) => frame.pressureChannelValid(index)
                ? frame.pressure[index]
                : 0.0).fold(0.0, (sum, value) => sum + value) /
        total;
  }

  static bool _forefootSupported(FootFrame frame) =>
      List.generate(
                  4,
                  (index) =>
                      frame.pressureChannelValid(index) &&
                      frame.pressure[index] >= _contactFloor)
              .where((value) => value)
              .length >=
          2 &&
      List.generate(2, (index) => frame.pressureChannelValid(index + 4))
          .any((value) => value);

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
    final gyroMaximum = [frame.imu.gx, frame.imu.gy, frame.imu.gz]
        .map((value) => value.abs())
        .reduce(math.max);
    return (acceleration - 9.80665).abs() <= 3.0 && gyroMaximum <= 12.0;
  }
}
