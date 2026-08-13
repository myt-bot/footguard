import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/foot_data_source.dart';
import '../models/ai_advice.dart';
import '../models/ai_chat_answer.dart';
import '../models/ai_question_answer.dart';
import '../models/device_command.dart';
import '../models/foot_frame.dart';
import '../models/risk_state.dart';
import '../models/regional_analysis.dart';
import 'frame_pairing_service.dart';
import 'ble_command_bridge.dart';

class MonitoringController extends ChangeNotifier {
  MonitoringController({
    required this.source,
    required this.api,
    this.commandBridge,
  });

  final FootDataSource source;
  final FootGuardApiClient api;
  final BleCommandBridge? commandBridge;
  final FramePairingService _pairing = FramePairingService();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<List<FootFrame>> _pendingUploadPairs = [];
  Timer? _refreshTimer;
  bool _uploading = false;
  bool _refreshing = false;
  bool _disposed = false;
  final Map<String, List<double>> _displayPressureBySide = {};
  bool _aiAdviceLoading = false;
  bool _aiQuestionLoading = false;
  bool _aiChatLoading = false;
  bool _calibrationResetting = false;
  String? _lastAdviceSignature;
  String? _aiQuestionSignature;
  DateTime? _lastAdviceAttemptAt;

  FootFrame? left;
  FootFrame? right;
  FootConnectionSnapshot connections =
      const FootConnectionSnapshot.disconnected();
  RiskState risk = const RiskState.incomplete();
  List<RiskState> activeRisks = const [];
  DeviceCommand? motorCommand;
  bool backendOnline = false;
  String? _sourceError;
  String? _backendError;
  String? get errorMessage => _sourceError ?? _backendError;
  String motorStatus = '暂无马达提醒';
  DateTime? lastUpdated;
  double? loadBias;
  double? loadDiff;
  int? syncErrorMs;
  String motionState = 'unavailable';
  String leftMotionState = 'unavailable';
  String rightMotionState = 'unavailable';
  RegionalAnalysis? regionalAnalysis;
  AiAdvice? aiAdvice;
  AiQuestionAnswer? aiQuestionAnswer;
  AiChatAnswer? aiChatAnswer;
  CalibrationStatus? calibrationStatus;
  String aiAdviceStatus = '当前规则引擎未识别到需要解释的风险';
  String aiQuestionStatus = '请选择一个常见问题';
  String aiChatStatus = '可询问当前状态、设备检查或日常观察建议';

  bool get aiAdviceLoading => _aiAdviceLoading;
  bool get aiQuestionLoading => _aiQuestionLoading;
  bool get aiChatLoading => _aiChatLoading;
  bool get calibrationResetting => _calibrationResetting;

  String get motionStatusLabel => switch (motionState) {
        'stationary' => '静止/稳定',
        'moving' => '运动中',
        _ => '不可用',
      };

  String footMotionStatusLabel(String side) =>
      switch (side == 'left' ? leftMotionState : rightMotionState) {
        'stationary' => '静止',
        'moving' => '运动中',
        _ => '不可用',
      };

  Future<void> start() async {
    _subscriptions.add(source.frames.listen(_onFrame));
    _subscriptions.add(source.connectionState.listen(_onConnections));
    _subscriptions.add(source.errorState.listen((value) {
      _sourceError = value;
      notifyListeners();
    }));
    await source.start();
    if (commandBridge != null) {
      commandBridge!.start();
      _subscriptions.add(commandBridge!.statuses.listen((value) {
        motorStatus = value;
        notifyListeners();
      }));
    }
    await refreshBackend();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => refreshBackend());
  }

  bool get _bothFeetConnected =>
      connections.left == FootConnectionStatus.connected &&
      connections.right == FootConnectionStatus.connected;

  bool get usesRealBleCommands => commandBridge != null;

  void _onConnections(FootConnectionSnapshot value) {
    connections = value;
    if (value.left != FootConnectionStatus.connected) {
      left = null;
      _displayPressureBySide.remove('left');
    }
    if (value.right != FootConnectionStatus.connected) {
      right = null;
      _displayPressureBySide.remove('right');
    }
    if (!_bothFeetConnected) {
      _resetBilateralState();
    }
    notifyListeners();
  }

  void _resetBilateralState() {
    risk = const RiskState.incomplete();
    activeRisks = const [];
    loadBias = null;
    loadDiff = null;
    syncErrorMs = null;
    motionState = 'unavailable';
    leftMotionState = 'unavailable';
    rightMotionState = 'unavailable';
    regionalAnalysis = null;
    _clearAiQuestion();
    if (commandBridge == null) {
      motorCommand = null;
      motorStatus = '双足数据不完整，暂停马达提醒';
    }
  }

  void _onFrame(FootFrame frame) {
    final displayFrame = _frameForDisplay(frame);
    if (frame.side == 'left') {
      left = displayFrame;
    } else {
      right = displayFrame;
    }
    lastUpdated = DateTime.now();
    // Upload the untouched measurement. Display smoothing must never alter
    // calibration, risk decisions, event history or motor commands.
    final pair = _pairing.add(frame);
    if (pair != null && source.shouldUploadToBackend) {
      _enqueuePair(pair);
    }
    notifyListeners();
  }

  FootFrame _frameForDisplay(FootFrame frame) {
    if (frame.pressure.length != 6) {
      return frame;
    }
    final previous = _displayPressureBySide[frame.side];
    final pressure = List<double>.generate(6, (index) {
      final current = frame.pressure[index];
      if (!frame.pressureChannelValid(index)) {
        return current;
      }
      // Release immediately near zero so an unloaded shoe never leaves a red
      // after-image. During contact, a light EMA removes one-frame ADC jitter
      // while retaining a response within roughly 200–400 ms at 5 Hz.
      if (current < 0.006) {
        return 0.0;
      }
      if (previous == null || previous.length != 6) {
        return current;
      }
      return previous[index] * 0.55 + current * 0.45;
    }, growable: false);
    _displayPressureBySide[frame.side] = pressure;
    return FootFrame(
      protocolVersion: frame.protocolVersion,
      sensorLayoutVersion: frame.sensorLayoutVersion,
      deviceId: frame.deviceId,
      side: frame.side,
      syncId: frame.syncId,
      packetSeq: frame.packetSeq,
      timestampMs: frame.timestampMs,
      pressure: pressure,
      temperature: frame.temperature,
      imu: frame.imu,
      battery: frame.battery,
      qualityFlags: frame.qualityFlags,
      source: frame.source,
    );
  }

  void _enqueuePair(List<FootFrame> pair) {
    // Keep a small bounded history. Replacing every pending pair can erase a
    // short movement episode before the backend sees it; an unbounded queue
    // would instead make risk decisions stale when the network is slow.
    _pendingUploadPairs.add(List<FootFrame>.of(pair, growable: false));
    if (_pendingUploadPairs.length > 6) {
      _pendingUploadPairs.removeAt(0);
    }
    if (!_uploading) {
      unawaited(_drainUploadQueue());
    }
  }

  Future<void> _drainUploadQueue() async {
    if (_uploading) {
      return;
    }
    _uploading = true;
    try {
      while (_pendingUploadPairs.isNotEmpty) {
        final queuedPairs = List<List<FootFrame>>.of(_pendingUploadPairs);
        _pendingUploadPairs.clear();
        final batch = [
          for (final pair in queuedPairs) ...pair,
        ];
        try {
          await api.uploadFrames(batch);
          backendOnline = true;
          _backendError = null;
        } catch (error) {
          backendOnline = false;
          _backendError = '数据上传失败：$error';
        }
      }
    } finally {
      _uploading = false;
      notifyListeners();
    }
  }

  Future<void> refreshBackend() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      backendOnline = await api.health();
      final snapshot = await api.realtime();
      final backendIsFrameSource = !source.shouldUploadToBackend;
      if (backendIsFrameSource) {
        left = snapshot.left ?? left;
        right = snapshot.right ?? right;
      }
      if (backendIsFrameSource || _bothFeetConnected) {
        loadBias = snapshot.loadBias;
        loadDiff = snapshot.loadDiff;
        syncErrorMs = snapshot.syncErrorMs;
        motionState = snapshot.motionState;
        leftMotionState = snapshot.leftMotionState;
        rightMotionState = snapshot.rightMotionState;
        risk = snapshot.risk;
        activeRisks = snapshot.activeRisks;
        regionalAnalysis = snapshot.regionalAnalysis;
        try {
          calibrationStatus = await api.calibrationStatus();
        } catch (_) {
          final analysis = regionalAnalysis;
          if (analysis != null) {
            calibrationStatus = CalibrationStatus(
              baselineReady: analysis.baselineReady,
              sampleCount: analysis.baselineSampleCount,
              requiredSamples: analysis.baselineRequiredSamples,
              statusReason:
                  analysis.baselineReady ? 'ready' : 'waiting_for_data',
            );
          }
        }
        _updateAiAdviceIfNeeded();
      } else {
        _resetBilateralState();
      }
      if (commandBridge != null || backendIsFrameSource || _bothFeetConnected) {
        motorCommand = await api.pendingCommand();
        if (motorCommand != null) {
          if (commandBridge != null) {
            await commandBridge!.submit(motorCommand!);
            motorStatus = commandBridge!.status;
          } else {
            motorStatus =
                '${motorCommand!.target} · ${motorCommand!.pattern} · ${motorCommand!.durationMs} ms';
          }
        } else if (commandBridge != null) {
          motorStatus = commandBridge!.status;
        } else if (!motorStatus.startsWith('已执行')) {
          motorStatus = '暂无马达提醒';
        }
      }
      _backendError = null;
    } catch (error) {
      backendOnline = false;
      risk = const RiskState.incomplete();
      activeRisks = const [];
      regionalAnalysis = null;
      loadBias = null;
      loadDiff = null;
      syncErrorMs = null;
      motorCommand = null;
      motorStatus = '后端离线，风险闭环与马达提醒已暂停';
      _backendError = source.shouldUploadToBackend
          ? '后端离线：本地 BLE 压力图继续显示，风险判断与马达提醒已暂停'
          : '后端不可用：$error';
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> executeMotorCommand() async {
    final command = motorCommand;
    if (command == null) return;
    if (command.isExpiredAt(api.serverNowMs)) {
      motorStatus = '命令已过期，未执行马达';
      motorCommand = null;
      notifyListeners();
      return;
    }
    final deviceId = command.target == 'right'
        ? (right?.deviceId ?? 'foot_right_001')
        : (left?.deviceId ?? 'foot_left_001');
    try {
      await api.acknowledgeMotor(command, deviceId);
      motorStatus = '已执行 ${command.target} ${command.pattern} 马达振动';
      motorCommand = null;
    } catch (error) {
      motorStatus = '马达 ACK 失败：$error';
    }
    notifyListeners();
  }

  void _updateAiAdviceIfNeeded() {
    if (_aiQuestionSignature != null &&
        _aiQuestionSignature != _currentMonitoringSignature) {
      _clearAiQuestion();
    }
    final signature = _currentMonitoringSignature;
    final now = DateTime.now();
    final withinCooldown = _lastAdviceSignature == signature &&
        _lastAdviceAttemptAt != null &&
        now.difference(_lastAdviceAttemptAt!) < const Duration(seconds: 30);
    final alreadyExplained =
        _lastAdviceSignature == signature && aiAdvice != null;
    if (_aiAdviceLoading || withinCooldown || alreadyExplained) {
      return;
    }

    _lastAdviceSignature = signature;
    _lastAdviceAttemptAt = now;
    _aiAdviceLoading = true;
    aiAdvice = null;
    aiAdviceStatus = '正在生成辅助解释…';
    unawaited(_requestAiAdvice(signature, risk, regionalAnalysis));
  }

  Future<void> _requestAiAdvice(
    String signature,
    RiskState requestedRisk,
    RegionalAnalysis? requestedAnalysis,
  ) async {
    try {
      final advice = await api.aiAdvice(
        risk: requestedRisk,
        activeRisks: activeRisks,
        loadDiff: loadDiff,
        temperatureDeltaMaxC:
            _maximumTemperatureDelta(requestedAnalysis?.temperatureDeltaC),
        baselineReady: requestedAnalysis?.baselineReady ?? false,
        pressureAvailable: requestedAnalysis?.pressureAvailable ?? false,
        temperatureAvailable: requestedAnalysis?.temperatureAvailable ?? false,
        leftConnected: left != null,
        rightConnected: right != null,
      );
      if (_currentMonitoringSignature == signature) {
        aiAdvice = advice;
        aiAdviceStatus = advice.usedFallback ? '云端暂不可用，已使用本地安全降级解释' : '辅助解释已更新';
      }
    } catch (error) {
      if (_currentMonitoringSignature == signature) {
        aiAdviceStatus = 'AI 辅助解释暂不可用：$error';
      }
    } finally {
      _aiAdviceLoading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> askAiQuestion(String questionKey) async {
    if (_aiQuestionLoading) {
      return;
    }
    final signature = _currentMonitoringSignature;
    _aiQuestionSignature = signature;
    _aiQuestionLoading = true;
    aiQuestionAnswer = null;
    aiQuestionStatus = '正在生成回答…';
    notifyListeners();
    try {
      final answer = await api.aiQuestion(
        questionKey: questionKey,
        risk: risk,
        activeRisks: activeRisks,
        loadDiff: loadDiff,
        temperatureDeltaMaxC:
            _maximumTemperatureDelta(regionalAnalysis?.temperatureDeltaC),
        baselineReady: regionalAnalysis?.baselineReady ?? false,
        pressureAvailable: regionalAnalysis?.pressureAvailable ?? false,
        temperatureAvailable: regionalAnalysis?.temperatureAvailable ?? false,
        leftConnected: left != null,
        rightConnected: right != null,
      );
      if (_currentMonitoringSignature == signature) {
        aiQuestionAnswer = answer;
        aiQuestionStatus = answer.usedFallback ? '云端暂不可用，已使用本地安全回答' : '回答已更新';
      }
    } catch (error) {
      if (_currentMonitoringSignature == signature) {
        aiQuestionStatus = '常见问题暂时无法回答：$error';
      }
    } finally {
      _aiQuestionLoading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> askAiChat(String question) async {
    final trimmed = question.trim();
    if (_aiChatLoading || trimmed.isEmpty || trimmed.length > 120) return;
    _aiChatLoading = true;
    aiChatAnswer = null;
    aiChatStatus = '正在结合当前状态生成回答…';
    notifyListeners();
    try {
      final analysis = regionalAnalysis;
      final validTemperaturePairs = analysis == null
          ? 0
          : List.generate(4, (index) {
              return analysis.leftTemperatureValid[index] &&
                  analysis.rightTemperatureValid[index];
            }).where((valid) => valid).length;
      aiChatAnswer = await api.aiChat(
        question: trimmed,
        risk: risk,
        activeRisks: activeRisks,
        loadDiff: loadDiff,
        temperatureDeltaMaxC:
            _maximumTemperatureDelta(analysis?.temperatureDeltaC),
        baselineReady: analysis?.baselineReady ?? false,
        pressureAvailable: analysis?.pressureAvailable ??
            (left?.pressureChannelsValid == true &&
                right?.pressureChannelsValid == true),
        temperatureAvailable: validTemperaturePairs > 0,
        validTemperaturePairs: validTemperaturePairs,
        motionState: motionState,
        leftConnected: left != null,
        rightConnected: right != null,
      );
      aiChatStatus =
          aiChatAnswer!.usedFallback ? '云端暂不可用，已使用当前状态对应的本地回答' : '回答已更新';
    } catch (error) {
      aiChatStatus = backendOnline ? '自由问答暂时不可用：$error' : '后端离线，自由问答暂时不可用';
    } finally {
      _aiChatLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> restartWearingCalibration() async {
    if (_calibrationResetting) return;
    _calibrationResetting = true;
    notifyListeners();
    try {
      calibrationStatus = await api.resetCalibration();
      risk = const RiskState(
        riskType: 'normal',
        riskSide: 'none',
        riskLevel: 0,
        durationMs: 0,
      );
      regionalAnalysis = null;
      motorCommand = null;
      motorStatus = '基线学习中，压力马达提醒已暂停';
      aiAdvice = null;
      aiQuestionAnswer = null;
      _lastAdviceSignature = null;
      _aiQuestionSignature = null;
      _backendError = null;
    } catch (error) {
      _backendError = '无法开始本次穿戴标定：$error';
      rethrow;
    } finally {
      _calibrationResetting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _clearAiQuestion() {
    aiQuestionAnswer = null;
    aiQuestionStatus = '请选择一个常见问题';
    _aiQuestionSignature = null;
  }

  String get _currentMonitoringSignature => [
        risk.riskType,
        risk.riskSide,
        risk.riskLevel,
        regionalAnalysis?.baselineReady ?? false,
        regionalAnalysis?.pressureAvailable ?? false,
        regionalAnalysis?.temperatureAvailable ?? false,
        left != null,
        right != null,
      ].join('|');

  static double? _maximumTemperatureDelta(List<double?>? values) {
    if (values == null || values.isEmpty) {
      return null;
    }
    var maximum = 0.0;
    for (final value in values) {
      if (value == null) continue;
      final absolute = value.abs();
      if (absolute > maximum) {
        maximum = absolute;
      }
    }
    return maximum;
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    source.dispose();
    commandBridge?.dispose();
    api.close();
    super.dispose();
  }
}
