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
import '../models/session_advice.dart';
import '../models/offline_intervention.dart';
import 'frame_pairing_service.dart';
import 'ble_command_bridge.dart';
import 'local_risk_engine.dart';
import 'offline_monitoring_store.dart';

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
  final LocalRiskEngine _localRiskEngine = LocalRiskEngine();
  final OfflineMonitoringStore _offlineStore = OfflineMonitoringStore();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<List<FootFrame>> _pendingUploadPairs = [];
  final List<OfflineIntervention> _pendingOfflineInterventions = [];
  Timer? _refreshTimer;
  Timer? _recoveryTimer;
  bool _uploading = false;
  bool _requiresOfflineReplay = false;
  int _syncFailureCount = 0;
  DateTime? _nextSyncAttemptAt;
  bool _localBaselinePersisted = false;
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
  DateTime? _lastSessionAdviceAt;
  LocalRiskResult? _localResult;
  String? _lastNoticeSignature;
  String? _pendingLocalEventId;
  OfflineIntervention? _activeOfflineIntervention;
  int _noticeSequence = 0;

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
  String? _syncWarning;
  String? get errorMessage => _sourceError ?? _backendError;
  String? get syncWarningMessage => _syncWarning;
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
  SessionAdvice? sessionAdvice;
  bool sessionAdviceLoading = false;
  RecoveryObservation? recoveryObservation;
  String? riskNoticeMessage;
  String aiAdviceStatus = '当前规则引擎未识别到需要解释的风险';
  String aiQuestionStatus = '请选择一个常见问题';
  String aiChatStatus = '可询问当前状态、设备检查或日常观察建议';

  bool get aiAdviceLoading => _aiAdviceLoading;
  bool get aiQuestionLoading => _aiQuestionLoading;
  bool get aiChatLoading => _aiChatLoading;
  bool get calibrationResetting => _calibrationResetting;
  int get noticeSequence => _noticeSequence;
  int get offlinePairCount => _pendingUploadPairs.length;
  String get ruleVersion => LocalRiskEngine.ruleVersion;

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
    final savedPairs = await _offlineStore.loadPairs();
    _pendingUploadPairs.addAll(savedPairs);
    _pendingOfflineInterventions.addAll(
      await _offlineStore.loadInterventions(),
    );
    _requiresOfflineReplay = savedPairs.isNotEmpty;
    _localRiskEngine.restoreBaseline(await _offlineStore.loadBaseline());
    _localBaselinePersisted = _localRiskEngine.baselineReady;
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
        if (value.startsWith('设备返回executed') &&
            value.contains('已保存为离线干预') &&
            _pendingLocalEventId != null) {
          final now = DateTime.now().millisecondsSinceEpoch;
          recoveryObservation = RecoveryObservation(
            eventId: _pendingLocalEventId!,
            status: 'observing',
            startedAtMs: now,
            deadlineAtMs: now + 15000,
            remainingMs: 15000,
          );
          _pendingLocalEventId = null;
        } else if (value.contains('已保存为离线干预') &&
            _activeOfflineIntervention != null) {
          _activeOfflineIntervention!.effectLabel = 'unknown';
          _activeOfflineIntervention!.recoveryTimeMs = 0;
          _pendingLocalEventId = null;
          unawaited(
            _offlineStore.saveInterventions(_pendingOfflineInterventions),
          );
        }
        notifyListeners();
      }));
      _subscriptions.add(commandBridge!.localAcknowledgements.listen((ack) {
        final intervention = _activeOfflineIntervention;
        if (intervention == null ||
            intervention.command.commandId != ack.commandId) {
          return;
        }
        intervention.acknowledgements.add(ack);
        unawaited(
          _offlineStore.saveInterventions(_pendingOfflineInterventions),
        );
      }));
    }
    await refreshBackend();
    _updateSessionAdviceIfNeeded();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => refreshBackend());
    _recoveryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tickRecoveryObservation();
      if (!_disposed) notifyListeners();
    });
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
      _localResult = _localRiskEngine.evaluate(pair);
      if (!_localResult!.baselineReady) {
        _localBaselinePersisted = false;
      } else if (!_localBaselinePersisted) {
        _localBaselinePersisted = true;
        unawaited(
          _offlineStore.saveBaseline(_localRiskEngine.exportBaseline()),
        );
      }
      if (_usingLocalMonitoringFallback) {
        _applyLocalResult(_localResult!);
      }
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
    if (_pendingUploadPairs.length > OfflineMonitoringStore.maxPairs) {
      _pendingUploadPairs.removeAt(0);
    }
    unawaited(_offlineStore.savePairs(_pendingUploadPairs));
    if (!_uploading) {
      unawaited(_drainUploadQueue());
    }
  }

  bool get _syncRetryReady =>
      _nextSyncAttemptAt == null ||
      !DateTime.now().isBefore(_nextSyncAttemptAt!);

  bool get _usingLocalMonitoringFallback =>
      source.shouldUploadToBackend &&
      _localResult != null &&
      _bothFeetConnected &&
      (!backendOnline || _syncWarning != null);

  void _recordSyncFailure(Object error) {
    _syncFailureCount += 1;
    const retryDelays = [2, 5, 10, 20, 30];
    final delayIndex = _syncFailureCount > retryDelays.length
        ? retryDelays.length - 1
        : _syncFailureCount - 1;
    final retrySeconds = retryDelays[delayIndex];
    _nextSyncAttemptAt = DateTime.now().add(Duration(seconds: retrySeconds));
    _syncWarning = '后端在线，但离线数据补传失败；将在 $retrySeconds 秒后重试'
        '（待补传 ${_pendingUploadPairs.length} 对，'
        '${_pendingOfflineInterventions.length} 条干预记录）：$error';
  }

  void _clearSyncFailureIfIdle() {
    if (_pendingUploadPairs.isNotEmpty ||
        _pendingOfflineInterventions.any((item) {
          final expectedAcks = item.command.target == 'both' ? 2 : 1;
          return item.acknowledgements.length >= expectedAcks &&
              item.effectLabel != null;
        })) {
      return;
    }
    _syncFailureCount = 0;
    _nextSyncAttemptAt = null;
    _syncWarning = null;
  }

  Future<void> _drainUploadQueue() async {
    if (_uploading || !_syncRetryReady) {
      return;
    }
    _uploading = true;
    try {
      while (_pendingUploadPairs.isNotEmpty) {
        final take =
            _pendingUploadPairs.length > 100 ? 100 : _pendingUploadPairs.length;
        final queuedPairs = _pendingUploadPairs.sublist(0, take);
        final batch = [
          for (final pair in queuedPairs) ...pair,
        ];
        try {
          await api.uploadFrames(
            batch,
            offlineReplay: _requiresOfflineReplay,
          );
          _pendingUploadPairs.removeRange(0, take);
          await _offlineStore.savePairs(_pendingUploadPairs);
          _syncFailureCount = 0;
          _nextSyncAttemptAt = null;
        } catch (error) {
          _requiresOfflineReplay = true;
          _recordSyncFailure(error);
          break;
        }
      }
      if (_pendingUploadPairs.isEmpty) {
        _requiresOfflineReplay = false;
        _clearSyncFailureIfIdle();
      }
    } finally {
      _uploading = false;
      notifyListeners();
    }
  }

  Future<void> refreshBackend() async {
    if (_refreshing) return;
    _refreshing = true;
    _tickRecoveryObservation();
    try {
      backendOnline = await api.health();
      if (_pendingUploadPairs.isNotEmpty && !_uploading) {
        await _drainUploadQueue();
      }
      await _syncOfflineInterventions();
      final snapshot = await api.realtime();
      final backendIsFrameSource = !source.shouldUploadToBackend;
      if (backendIsFrameSource) {
        left = snapshot.left ?? left;
        right = snapshot.right ?? right;
      }
      if (backendIsFrameSource || _bothFeetConnected) {
        if (_usingLocalMonitoringFallback) {
          motorCommand = null;
          regionalAnalysis = null;
          _applyLocalResult(_localResult!);
        } else {
          loadBias = snapshot.loadBias;
          loadDiff = snapshot.loadDiff;
          syncErrorMs = snapshot.syncErrorMs;
          motionState = snapshot.motionState;
          leftMotionState = snapshot.leftMotionState;
          rightMotionState = snapshot.rightMotionState;
          risk = snapshot.risk;
          activeRisks = snapshot.activeRisks;
          regionalAnalysis = snapshot.regionalAnalysis;
          recoveryObservation = snapshot.recoveryObservation;
          _updateRiskNotice();
        }
        if (!_usingLocalMonitoringFallback) {
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
                emptyTemperatureReferenceReady: analysis.temperatureOffsetStatus
                    .any((item) => item != 'unstable' && item != 'raw_invalid'),
                temperatureRiskEnabled: analysis.temperatureRiskEnabled,
                temperatureOffsetChannels: analysis.temperatureOffsetChannels,
                temperatureUntrustedChannels:
                    analysis.temperatureUntrustedChannels,
                temperatureRiskReason: analysis.temperatureRiskReason,
              );
            }
          }
          final backendResetAt = calibrationStatus?.resetAtMs;
          if (backendResetAt != null &&
              (_localRiskEngine.baselineCreatedAtMs ?? 0) < backendResetAt) {
            _localRiskEngine.reset();
            _localResult = null;
            _localBaselinePersisted = false;
            await _offlineStore.clearBaseline();
          }
        }
        _updateAiAdviceIfNeeded();
        _updateSessionAdviceIfNeeded();
      } else {
        _resetBilateralState();
      }
      if (_usingLocalMonitoringFallback) {
        motorStatus = commandBridge?.status ?? '数据补传异常，本地风险闭环运行中';
      } else if (commandBridge != null ||
          backendIsFrameSource ||
          _bothFeetConnected) {
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
      motorCommand = null;
      final local = _localResult;
      if (source.shouldUploadToBackend && local != null && _bothFeetConnected) {
        regionalAnalysis = null;
        _applyLocalResult(local);
        motorStatus = commandBridge?.status ?? '后端离线，本地风险闭环运行中';
      } else {
        risk = const RiskState.incomplete();
        activeRisks = const [];
        regionalAnalysis = null;
        loadBias = null;
        loadDiff = null;
        syncErrorMs = null;
        motorStatus = '双足数据不完整，暂停马达提醒';
      }
      _backendError = source.shouldUploadToBackend
          ? '后端离线：本地规则、BLE 马达与离线缓存继续运行（待补传 ${_pendingUploadPairs.length} 对）'
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

  Future<void> _syncOfflineInterventions() async {
    if (!_syncRetryReady) return;
    final ready = _pendingOfflineInterventions.where((item) {
      final expectedAcks = item.command.target == 'both' ? 2 : 1;
      return item.acknowledgements.length >= expectedAcks &&
          item.effectLabel != null;
    }).toList();
    if (ready.isEmpty) return;
    try {
      await api.uploadOfflineInterventions(ready);
      final syncedIds = ready.map((item) => item.command.commandId).toSet();
      _pendingOfflineInterventions.removeWhere(
        (item) => syncedIds.contains(item.command.commandId),
      );
      await _offlineStore.saveInterventions(_pendingOfflineInterventions);
      _syncFailureCount = 0;
      _nextSyncAttemptAt = null;
      _clearSyncFailureIfIdle();
    } catch (error) {
      _recordSyncFailure(error);
    }
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

  void _updateSessionAdviceIfNeeded({bool force = false}) {
    final now = DateTime.now();
    if (sessionAdviceLoading ||
        (!force &&
            _lastSessionAdviceAt != null &&
            now.difference(_lastSessionAdviceAt!) <
                const Duration(seconds: 30))) {
      return;
    }
    _lastSessionAdviceAt = now;
    sessionAdviceLoading = true;
    unawaited(_requestSessionAdvice());
  }

  Future<void> _requestSessionAdvice() async {
    try {
      sessionAdvice = await api.sessionAdvice();
    } catch (_) {
      // Keep the most recent completed session advice visible while offline.
    } finally {
      sessionAdviceLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void refreshSessionAdvice() => _updateSessionAdviceIfNeeded(force: true);

  Future<void> restartWearingCalibration() async {
    if (_calibrationResetting) return;
    _calibrationResetting = true;
    notifyListeners();
    _localRiskEngine.reset();
    _localResult = null;
    _localBaselinePersisted = false;
    await _offlineStore.clearBaseline();
    try {
      if (backendOnline) {
        calibrationStatus = await api.resetCalibration();
      } else {
        calibrationStatus = const CalibrationStatus(
          baselineReady: false,
          sampleCount: 0,
          requiredSamples: LocalRiskEngine.requiredSamples,
          statusReason: 'waiting_for_data',
        );
      }
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
      backendOnline = false;
      calibrationStatus = const CalibrationStatus(
        baselineReady: false,
        sampleCount: 0,
        requiredSamples: LocalRiskEngine.requiredSamples,
        statusReason: 'waiting_for_data',
      );
      _backendError = '后端离线，已开始 App 本地穿戴标定：$error';
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

  void _applyLocalResult(LocalRiskResult result) {
    risk = result.risk;
    activeRisks = result.activeRisks;
    loadBias = result.loadBias;
    loadDiff = result.loadDiff;
    syncErrorMs = left == null || right == null
        ? null
        : (left!.timestampMs - right!.timestampMs).abs();
    calibrationStatus = CalibrationStatus(
      baselineReady: result.baselineReady,
      sampleCount: result.baselineSamples,
      requiredSamples: LocalRiskEngine.requiredSamples,
      statusReason: result.baselineReady ? 'ready' : 'waiting_for_data',
      emptyTemperatureReferenceReady: result.temperatureOffsetStatus
          .any((item) => item != 'unstable' && item != 'raw_invalid'),
      temperatureRiskEnabled: result.temperatureRiskEnabled,
      temperatureOffsetChannels: [
        for (var index = 0;
            index < result.temperatureOffsetStatus.length;
            index += 1)
          if (result.temperatureOffsetStatus[index] == 'assembly_offset') index,
      ],
      temperatureUntrustedChannels: [
        for (var index = 0;
            index < result.temperatureOffsetStatus.length;
            index += 1)
          if (result.temperatureOffsetStatus[index] == 'unstable' ||
              result.temperatureOffsetStatus[index] == 'raw_invalid')
            index,
      ],
      temperatureRiskReason: result.temperatureRiskReason,
    );
    _updateRiskNotice();
    if (result.motorTarget != null &&
        result.motorPattern != null &&
        commandBridge != null &&
        !commandBridge!.hasActiveCommand) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final eventId = 'local_evt_$now';
      final command = DeviceCommand(
        commandId: 'cmd_local_$now',
        target: result.motorTarget!,
        pattern: result.motorPattern!,
        durationMs: result.motorPattern == 'long'
            ? 1500
            : result.motorPattern == 'double'
                ? 800
                : 500,
        expireAtMs: now + 30000,
        reasonCode: result.risk.riskType,
      );
      _pendingLocalEventId = eventId;
      _activeOfflineIntervention = OfflineIntervention(
        eventId: eventId,
        command: command,
        risk: result.risk,
        activeRisks: List<RiskState>.of(result.activeRisks),
        startedAtMs: now - result.risk.durationMs,
        beforeLoadDiff: result.loadDiff,
      );
      _pendingOfflineInterventions.add(_activeOfflineIntervention!);
      unawaited(
        _offlineStore.saveInterventions(_pendingOfflineInterventions),
      );
      motorCommand = command;
      unawaited(commandBridge!.submitLocal(command));
    }
  }

  void _updateRiskNotice() {
    if (activeRisks.isEmpty) {
      _lastNoticeSignature = null;
      return;
    }
    final signature = activeRisks
        .map((item) => '${item.riskType}:${item.riskSide}:${item.riskLevel}')
        .join('|');
    if (_lastNoticeSignature == signature) return;
    _lastNoticeSignature = signature;
    riskNoticeMessage = activeRisks.map(_riskNoticeLabel).join('；');
    _noticeSequence += 1;
  }

  void _tickRecoveryObservation() {
    final observation = recoveryObservation;
    if (observation == null || observation.status != 'observing') return;
    if (!backendOnline && !observation.eventId.startsWith('local_evt_')) {
      return;
    }
    final remaining = observation.deadlineAtMs -
        (backendOnline
            ? api.serverNowMs
            : DateTime.now().millisecondsSinceEpoch);
    recoveryObservation = RecoveryObservation(
      eventId: observation.eventId,
      status: remaining > 0 ? 'observing' : 'completed',
      startedAtMs: observation.startedAtMs,
      deadlineAtMs: observation.deadlineAtMs,
      remainingMs: remaining > 0 ? remaining : 0,
      effectLabel: remaining > 0
          ? null
          : (activeRisks.isEmpty ? 'effective' : 'ineffective'),
    );
    if (remaining <= 0) {
      final intervention = _activeOfflineIntervention;
      if (intervention != null && intervention.effectLabel == null) {
        intervention.afterLoadDiff = _localResult?.loadDiff;
        intervention.effectLabel =
            activeRisks.isEmpty ? 'effective' : 'ineffective';
        intervention.recoveryTimeMs = 15000;
        unawaited(
          _offlineStore.saveInterventions(_pendingOfflineInterventions),
        );
      }
      riskNoticeMessage = activeRisks.isEmpty
          ? '15 秒干预观察完成：风险已恢复'
          : '15 秒干预观察完成：风险仍持续，请调整姿势并复查';
      _noticeSequence += 1;
    }
  }

  static String _riskNoticeLabel(RiskState item) => switch (item.riskType) {
        'left_load_bias' => '检测到持续左偏（等级 ${item.riskLevel}）',
        'right_load_bias' => '检测到持续右偏（等级 ${item.riskLevel}）',
        'forefoot_high' =>
          '${item.riskSide == 'left' ? '左脚' : '右脚'}前掌持续高载（等级 ${item.riskLevel}）',
        'temperature_asymmetry' =>
          '${item.riskSide == 'left' ? '左脚' : '右脚'}同区温度较高（等级 ${item.riskLevel}）',
        _ => '检测到持续风险（等级 ${item.riskLevel}）',
      };

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
    _recoveryTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    source.dispose();
    commandBridge?.dispose();
    api.close();
    super.dispose();
  }
}
