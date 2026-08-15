import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/foot_data_source.dart';
import '../models/ai_chat_answer.dart';
import '../models/ai_question_answer.dart';
import '../models/device_command.dart';
import '../models/foot_frame.dart';
import '../models/gait_summary.dart';
import '../models/risk_state.dart';
import '../models/regional_analysis.dart';
import '../models/session_advice.dart';
import '../models/offline_intervention.dart';
import 'frame_pairing_service.dart';
import 'ble_command_bridge.dart';
import 'local_risk_engine.dart';
import 'offline_monitoring_store.dart';
import 'risk_speech_coordinator.dart';

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
  Timer? _uploadKickTimer;
  Timer? _queuePersistTimer;
  bool _uploading = false;
  int _offlineReplayPairsRemaining = 0;
  int _syncFailureCount = 0;
  DateTime? _nextSyncAttemptAt;
  bool _localBaselinePersisted = false;
  bool _refreshing = false;
  bool _disposed = false;
  final Map<String, List<double>> _displayPressureBySide = {};
  bool _aiQuestionLoading = false;
  bool _aiChatLoading = false;
  bool _calibrationResetting = false;
  DateTime? _lastSessionAdviceAt;
  LocalRiskResult? _localResult;
  final RiskSpeechCoordinator _riskSpeechCoordinator = RiskSpeechCoordinator();
  String? _announcedGaitEpisodeId;
  String? _pendingLocalEventId;
  OfflineIntervention? _activeOfflineIntervention;
  int _noticeSequence = 0;
  int _gaitNoticeSequence = 0;
  int? _handledBackendResetAtMs;

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
  GaitSummary gait = const GaitSummary.insufficient();
  RegionalAnalysis? regionalAnalysis;
  AiQuestionAnswer? aiQuestionAnswer;
  AiChatAnswer? aiChatAnswer;
  CalibrationStatus? calibrationStatus;
  SessionAdvice? sessionAdvice;
  bool sessionAdviceLoading = false;
  RecoveryObservation? recoveryObservation;
  String? riskNoticeMessage;
  String? gaitNoticeMessage;
  String aiQuestionStatus = '请选择一个常见问题';
  String aiChatStatus = '可询问当前状态、设备检查或日常观察建议';
  String calibrationStage = 'empty_reference';

  static const _calibrationStageOrder = {
    'empty_reference': 0,
    'put_on': 1,
    'standing_baseline': 2,
    'complete': 3,
  };

  bool get aiQuestionLoading => _aiQuestionLoading;
  bool get aiChatLoading => _aiChatLoading;
  bool get calibrationResetting => _calibrationResetting;
  int get noticeSequence => _noticeSequence;
  int get gaitNoticeSequence => _gaitNoticeSequence;
  int get offlinePairCount => _pendingUploadPairs.length;
  String get ruleVersion => LocalRiskEngine.ruleVersion;
  bool get bothFeetConnected => _bothFeetConnected;

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

  String get gaitStatusLabel => switch (gait.state) {
        'stationary' => '静止',
        'walking' => '行走中',
        _ => '数据不足',
      };

  String get gaitStepLabel {
    final episode = gait.lastCompletedEpisode;
    if (gait.state == 'walking') {
      return '${gait.stepCount}（左 ${gait.leftSteps} / 右 ${gait.rightSteps}）';
    }
    return episode == null
        ? '--'
        : '${episode.stepCount}（左 ${episode.leftSteps} / 右 ${episode.rightSteps}）';
  }

  String get gaitCadenceLabel {
    final cadence = gait.state == 'walking'
        ? gait.cadenceSpm
        : gait.lastCompletedEpisode?.cadenceSpm;
    return cadence == null ? '--' : '${cadence.toStringAsFixed(0)} 步/分钟';
  }

  Future<void> start() async {
    final savedPairs = await _offlineStore.loadPairs();
    _pendingUploadPairs.addAll(savedPairs);
    _offlineReplayPairsRemaining = savedPairs.length;
    _pendingOfflineInterventions.addAll(
      await _offlineStore.loadInterventions(),
    );
    _localRiskEngine.restoreBaseline(await _offlineStore.loadBaseline());
    _localBaselinePersisted = _localRiskEngine.baselineReady;
    _subscriptions.add(source.frames.listen(_onFrame));
    _subscriptions.add(source.connectionState.listen(_onConnections));
    _subscriptions.add(
      source.errorState.listen((value) {
        _sourceError = value;
        notifyListeners();
      }),
    );
    await source.start();
    if (commandBridge != null) {
      commandBridge!.start();
      _subscriptions.add(
        commandBridge!.statuses.listen((value) {
          motorStatus = value;
          if (value.startsWith('设备返回executed') &&
              value.contains('设备执行记录已保存') &&
              _pendingLocalEventId != null) {
            final pressureIntervention =
                _activeOfflineIntervention?.activeRisks.any(
                      (item) => item.isPressure,
                    ) ??
                    false;
            if (pressureIntervention) {
              final now = DateTime.now().millisecondsSinceEpoch;
              recoveryObservation = RecoveryObservation(
                eventId: _pendingLocalEventId!,
                status: 'observing',
                startedAtMs: now,
                deadlineAtMs: now + 15000,
                remainingMs: 15000,
              );
            } else {
              _activeOfflineIntervention?.effectLabel = 'unknown';
              _activeOfflineIntervention?.recoveryTimeMs = 0;
              unawaited(
                _offlineStore.saveInterventions(_pendingOfflineInterventions),
              );
            }
            _pendingLocalEventId = null;
          } else if (value.contains('设备执行记录已保存') &&
              _activeOfflineIntervention != null) {
            _activeOfflineIntervention!.effectLabel = 'unknown';
            _activeOfflineIntervention!.recoveryTimeMs = 0;
            _pendingLocalEventId = null;
            unawaited(
              _offlineStore.saveInterventions(_pendingOfflineInterventions),
            );
          }
          notifyListeners();
        }),
      );
      _subscriptions.add(
        commandBridge!.localAcknowledgements.listen((ack) {
          final intervention = _activeOfflineIntervention;
          if (intervention == null ||
              intervention.command.commandId != ack.commandId) {
            return;
          }
          intervention.acknowledgements.add(ack);
          unawaited(
            _offlineStore.saveInterventions(_pendingOfflineInterventions),
          );
        }),
      );
    }
    await refreshBackend();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => refreshBackend(),
    );
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
    gait = const GaitSummary.insufficient();
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
      final localStage = _localResult!.calibrationStage;
      _advanceCalibrationStage(
        backendOnline && localStage == 'complete'
            ? 'standing_baseline'
            : localStage,
      );
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
      if (_offlineReplayPairsRemaining > 0) {
        _offlineReplayPairsRemaining -= 1;
      }
    }
    _scheduleQueuePersistence();
    _scheduleUpload();
  }

  void _scheduleQueuePersistence() {
    _queuePersistTimer?.cancel();
    _queuePersistTimer = Timer(const Duration(milliseconds: 500), () {
      final snapshot = _pendingUploadPairs
          .map((pair) => List<FootFrame>.of(pair, growable: false))
          .toList(growable: false);
      unawaited(_offlineStore.savePairs(snapshot));
    });
  }

  void _scheduleUpload([Duration delay = const Duration(milliseconds: 100)]) {
    if (_uploading || _pendingUploadPairs.isEmpty || _uploadKickTimer != null) {
      return;
    }
    _uploadKickTimer = Timer(delay, () {
      _uploadKickTimer = null;
      unawaited(_drainUploadQueue());
    });
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
    _uploadKickTimer?.cancel();
    _uploadKickTimer = null;
    if (_pendingUploadPairs.isEmpty) return;
    _uploading = true;
    try {
      final replaying = _offlineReplayPairsRemaining > 0;
      final available = replaying
          ? math.min(_offlineReplayPairsRemaining, _pendingUploadPairs.length)
          : _pendingUploadPairs.length;
      final take = math.min(available, 100);
      final queuedPairs = _pendingUploadPairs.sublist(0, take);
      final batch = [for (final pair in queuedPairs) ...pair];
      try {
        await api.uploadFrames(batch, offlineReplay: replaying);
        _pendingUploadPairs.removeRange(0, take);
        if (replaying) {
          _offlineReplayPairsRemaining =
              math.max(0, _offlineReplayPairsRemaining - take);
        }
        _scheduleQueuePersistence();
        _syncFailureCount = 0;
        _nextSyncAttemptAt = null;
      } catch (error) {
        _recordSyncFailure(error);
      }
      if (_pendingUploadPairs.isEmpty) {
        _offlineReplayPairsRemaining = 0;
        _clearSyncFailureIfIdle();
      }
    } finally {
      _uploading = false;
      if (_pendingUploadPairs.isNotEmpty && _syncRetryReady) {
        _scheduleUpload();
      }
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
          gait = snapshot.gait;
          _updateGaitNotice();
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
              _handledBackendResetAtMs != backendResetAt &&
              (_localRiskEngine.baselineCreatedAtMs ?? 0) < backendResetAt) {
            _localRiskEngine.reset();
            _localResult = null;
            _localBaselinePersisted = false;
            await _offlineStore.clearBaseline();
          }
          if (backendResetAt != null) {
            _handledBackendResetAtMs = backendResetAt;
          }
          if (calibrationStatus?.baselineReady == true) {
            _advanceCalibrationStage('complete');
          } else if (calibrationStatus?.emptyTemperatureReferenceReady ==
              true) {
            _advanceCalibrationStage('put_on');
          }
        }
      } else {
        _resetBilateralState();
      }
      if (_usingLocalMonitoringFallback) {
        motorStatus = commandBridge?.status ?? '本地风险监测运行中，暂无马达提醒';
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
        motorStatus = commandBridge?.status ?? '本地风险监测运行中，暂无马达提醒';
      } else {
        risk = const RiskState.incomplete();
        activeRisks = const [];
        regionalAnalysis = null;
        loadBias = null;
        loadDiff = null;
        syncErrorMs = null;
        motorStatus = '双足数据不完整，暂停马达提醒';
      }
      _backendError =
          source.shouldUploadToBackend ? '后端暂不可用，实时监测已切换为本地规则' : '后端不可用：$error';
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
      motorStatus = '马达确认失败：$error';
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

  Future<void> askAiQuestion(String questionKey) async {
    if (_aiQuestionLoading) {
      return;
    }
    final signature = _currentMonitoringSignature;
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
        temperatureDeltaMaxC: _maximumTemperatureDelta(
          regionalAnalysis?.temperatureDeltaC,
        ),
        baselineReady: regionalAnalysis?.baselineReady ?? false,
        pressureAvailable: regionalAnalysis?.pressureAvailable ?? false,
        temperatureAvailable: regionalAnalysis?.temperatureAvailable ?? false,
        leftConnected: left != null,
        rightConnected: right != null,
        gait: gait,
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
        temperatureDeltaMaxC: _maximumTemperatureDelta(
          analysis?.temperatureDeltaC,
        ),
        baselineReady: analysis?.baselineReady ?? false,
        pressureAvailable: analysis?.pressureAvailable ??
            (left?.pressureChannelsValid == true &&
                right?.pressureChannelsValid == true),
        temperatureAvailable: validTemperaturePairs > 0,
        validTemperaturePairs: validTemperaturePairs,
        motionState: motionState,
        leftConnected: left != null,
        rightConnected: right != null,
        gait: gait,
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
      await _offlineStore.saveSessionAdvice(sessionAdvice!.toJson());
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
    calibrationStage = 'empty_reference';
    _riskSpeechCoordinator.reset();
    _announcedGaitEpisodeId = null;
    gaitNoticeMessage = null;
    _calibrationResetting = true;
    notifyListeners();
    _localRiskEngine.reset();
    _localResult = null;
    _localBaselinePersisted = false;
    await _offlineStore.clearBaseline();
    try {
      if (backendOnline) {
        calibrationStatus = await api.resetCalibration();
        _handledBackendResetAtMs = calibrationStatus?.resetAtMs;
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
      aiQuestionAnswer = null;
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
  }

  void _applyLocalResult(LocalRiskResult result) {
    risk = result.risk;
    activeRisks = result.activeRisks;
    loadBias = result.loadBias;
    loadDiff = result.loadDiff;
    motionState = result.motionState;
    leftMotionState = result.motionState;
    rightMotionState = result.motionState;
    gait = const GaitSummary.insufficient();
    syncErrorMs = left == null || right == null
        ? null
        : (left!.timestampMs - right!.timestampMs).abs();
    calibrationStatus = CalibrationStatus(
      baselineReady: result.baselineReady,
      sampleCount: result.baselineSamples,
      requiredSamples: LocalRiskEngine.requiredSamples,
      statusReason: result.baselineReady ? 'ready' : 'waiting_for_data',
      emptyTemperatureReferenceReady: result.temperatureOffsetStatus.any(
        (item) => item != 'unstable' && item != 'raw_invalid',
      ),
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
    _advanceCalibrationStage(result.calibrationStage);
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
      unawaited(_offlineStore.saveInterventions(_pendingOfflineInterventions));
      motorCommand = command;
      unawaited(commandBridge!.submitLocal(command));
    }
  }

  void _advanceCalibrationStage(String next) {
    final currentRank = _calibrationStageOrder[calibrationStage] ?? -1;
    final nextRank = _calibrationStageOrder[next] ?? -1;
    if (nextRank > currentRank) calibrationStage = next;
  }

  void _updateRiskNotice() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final actionable = activeRisks
        .where(
          (item) =>
              item.riskLevel >= 2 &&
              (!item.isPressure || motionState != 'moving'),
        )
        .toList(growable: false);
    final newlyActionable = _riskSpeechCoordinator.takeNew(actionable, now);
    if (newlyActionable.isEmpty) return;
    riskNoticeMessage = newlyActionable.map(riskVoiceMessage).join('；');
    _noticeSequence += 1;
  }

  void _updateGaitNotice() {
    final episode = gait.lastCompletedEpisode;
    final confirmed = gait.confirmedIssues;
    if (episode == null ||
        confirmed.isEmpty ||
        episode.episodeId == _announcedGaitEpisodeId) {
      return;
    }
    _announcedGaitEpisodeId = episode.episodeId;
    gaitNoticeMessage =
        '连续三段行走均检测到${confirmed.map(_gaitIssueVoiceLabel).join('、')}，请停下检查鞋内异物、鞋垫贴合和足部皮肤。';
    _gaitNoticeSequence += 1;
  }

  static String _gaitIssueVoiceLabel(GaitIssue issue) {
    final side = issue.side == 'left'
        ? '左脚'
        : issue.side == 'right'
            ? '右脚'
            : '';
    return switch (issue.issueType) {
      'walking_load_asymmetry' => '$side行走负荷持续偏高',
      'walking_forefoot_concentration' => '$side前掌反复受压',
      'walking_medial_concentration' => '$side内侧反复受压',
      'walking_lateral_concentration' => '$side外侧反复受压',
      'step_timing_instability' => '步时波动较大',
      _ => '行走负荷趋势异常',
    };
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
    final componentResults = remaining > 0
        ? observation.componentFeedback
        : _localRecoveryComponents(observation);
    final pressureEffects = componentResults
        .where((item) => item.pressureIntervention)
        .map((item) => item.effectLabel)
        .toList(growable: false);
    final localEffect =
        pressureEffects.isEmpty || pressureEffects.contains('unknown')
            ? (activeRisks.isEmpty ? 'effective' : 'ineffective')
            : pressureEffects.every((item) => item == 'effective')
                ? 'effective'
                : pressureEffects.any(
                    (item) => item == 'effective' || item == 'partial',
                  )
                    ? 'partial'
                    : pressureEffects.any((item) => item == 'worsened')
                        ? 'worsened'
                        : 'ineffective';
    recoveryObservation = RecoveryObservation(
      eventId: observation.eventId,
      status: remaining > 0 ? 'observing' : 'completed',
      startedAtMs: observation.startedAtMs,
      deadlineAtMs: observation.deadlineAtMs,
      remainingMs: remaining > 0 ? remaining : 0,
      effectLabel: remaining > 0 ? null : localEffect,
      componentFeedback: componentResults,
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
    }
  }

  List<RiskComponentFeedbackRecord> _localRecoveryComponents(
    RecoveryObservation observation,
  ) {
    if (!observation.eventId.startsWith('local_evt_')) {
      return observation.componentFeedback;
    }
    final original = _activeOfflineIntervention?.activeRisks ?? const [];
    return original.map((item) {
      final remains = activeRisks.any(
        (current) =>
            current.riskType == item.riskType &&
            current.riskSide == item.riskSide &&
            current.riskLevel >= 2,
      );
      return RiskComponentFeedbackRecord(
        riskType: item.riskType,
        riskSide: item.riskSide,
        effectLabel: item.riskType == 'temperature_asymmetry'
            ? 'observation_only'
            : remains
                ? 'ineffective'
                : 'effective',
        pressureIntervention: item.riskType != 'temperature_asymmetry',
      );
    }).toList(growable: false);
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
    _recoveryTimer?.cancel();
    _uploadKickTimer?.cancel();
    _queuePersistTimer?.cancel();
    final pendingSnapshot = _pendingUploadPairs
        .map((pair) => List<FootFrame>.of(pair, growable: false))
        .toList(growable: false);
    unawaited(_offlineStore.savePairs(pendingSnapshot));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    source.dispose();
    commandBridge?.dispose();
    api.close();
    super.dispose();
  }
}
