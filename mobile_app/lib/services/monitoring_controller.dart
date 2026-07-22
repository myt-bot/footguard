import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/foot_data_source.dart';
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
  final List<FootFrame> _uploadQueue = [];
  Timer? _refreshTimer;
  bool _uploading = false;
  bool _refreshing = false;

  FootFrame? left;
  FootFrame? right;
  FootConnectionSnapshot connections =
      const FootConnectionSnapshot.disconnected();
  RiskState risk = const RiskState.incomplete();
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
  RegionalAnalysis? regionalAnalysis;

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
    }
    if (value.right != FootConnectionStatus.connected) {
      right = null;
    }
    if (!_bothFeetConnected) {
      _resetBilateralState();
    }
    notifyListeners();
  }

  void _resetBilateralState() {
    risk = const RiskState.incomplete();
    loadBias = null;
    loadDiff = null;
    syncErrorMs = null;
    regionalAnalysis = null;
    if (commandBridge == null) {
      motorCommand = null;
      motorStatus = '双足数据不完整，暂停马达提醒';
    }
  }

  void _onFrame(FootFrame frame) {
    if (frame.side == 'left') {
      left = frame;
    } else {
      right = frame;
    }
    lastUpdated = DateTime.now();
    final pair = _pairing.add(frame);
    if (pair != null && source.shouldUploadToBackend) {
      _enqueuePair(pair);
    }
    notifyListeners();
  }

  void _enqueuePair(List<FootFrame> pair) {
    _uploadQueue.addAll(pair);
    if (!_uploading) {
      _drainUploadQueue();
    }
  }

  Future<void> _drainUploadQueue() async {
    if (_uploading) {
      return;
    }
    _uploading = true;
    try {
      while (_uploadQueue.isNotEmpty) {
        final takeCount = _uploadQueue.length > 20 ? 20 : _uploadQueue.length;
        final batch = List<FootFrame>.of(_uploadQueue.take(takeCount));
        _uploadQueue.removeRange(0, takeCount);
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
        risk = snapshot.risk;
        regionalAnalysis = snapshot.regionalAnalysis;
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
      _backendError = '后端不可用：$error';
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  Future<void> executeMotorCommand() async {
    final command = motorCommand;
    if (command == null) return;
    if (command.expired) {
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

  @override
  void dispose() {
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
