import 'dart:async';

import '../data/api_client.dart';
import '../models/ble_scan_device.dart';
import '../models/device_ack.dart';
import '../models/device_command.dart';
import 'ble_command_gateway.dart';

class BleCommandBridge {
  BleCommandBridge({required this.api, required this.gateway});

  final FootGuardApiClient api;
  final BleCommandGateway gateway;
  final _statuses = StreamController<String>.broadcast();
  final _completedCommandIds = <String>{};
  final _receivedDeviceIds = <String>{};
  final _receivedAcks = <String, DeviceAck>{};
  StreamSubscription<DeviceAck>? _ackSubscription;
  Timer? _expiryTimer;
  DeviceCommand? _active;
  Set<String> _expectedDeviceIds = const {};
  String status = '暂无真实马达命令';

  Stream<String> get statuses => _statuses.stream;
  bool get hasActiveCommand => _active != null;

  void start() {
    _ackSubscription ??= gateway.acknowledgements.listen(
      (ack) => _handleAck(ack),
      onError: (Object error) => _setStatus('AckEvent接收失败：$error'),
    );
  }

  Future<void> submit(DeviceCommand command) async {
    if (_completedCommandIds.contains(command.commandId) ||
        _active?.commandId == command.commandId ||
        _active != null) {
      return;
    }
    if (command.expired) {
      _completedCommandIds.add(command.commandId);
      _setStatus('命令已过期，未写入BLE设备');
      return;
    }

    final sides = switch (command.target) {
      'left' => const [FootSide.left],
      'right' => const [FootSide.right],
      'both' => const [FootSide.left, FootSide.right],
      _ => const <FootSide>[],
    };
    if (sides.isEmpty) {
      _completedCommandIds.add(command.commandId);
      _setStatus('BLE命令目标无效：${command.target}');
      return;
    }
    final expectedIds = <String>{};
    for (final side in sides) {
      final connection = gateway.current.forSide(side);
      if (!connection.isReady || connection.deviceStatus == null) {
        _setStatus('${_sideLabel(side)}设备未连接，命令暂未下发');
        return;
      }
      expectedIds.add(connection.deviceStatus!.deviceId);
    }

    _active = command;
    _expectedDeviceIds = expectedIds;
    _receivedDeviceIds.clear();
    _receivedAcks.clear();
    _setStatus('正在向${_targetLabel(command.target)}设备下发BLE命令');
    try {
      await gateway.sendCommand(command);
      _setStatus('命令已写入BLE，等待设备AckEvent（尚未确认马达执行）');
      final remaining =
          command.expireAtMs - DateTime.now().millisecondsSinceEpoch + 1000;
      _expiryTimer?.cancel();
      _expiryTimer = Timer(
        Duration(milliseconds: remaining > 1 ? remaining : 1),
        () {
          if (_active?.commandId == command.commandId) {
            _finish(
              command.commandId,
              '等待设备AckEvent超时，不能确认马达执行',
            );
          }
        },
      );
    } catch (error) {
      _finish(command.commandId, 'BLE命令下发失败：$error');
    }
  }

  Future<void> _handleAck(DeviceAck ack) async {
    final command = _active;
    if (command == null ||
        ack.commandId != command.commandId ||
        !_expectedDeviceIds.contains(ack.deviceId) ||
        _receivedDeviceIds.contains(ack.deviceId)) {
      return;
    }
    try {
      await api.acknowledgeDevice(ack);
    } catch (error) {
      _finish(
        command.commandId,
        '收到设备AckEvent，但上传后端失败：$error',
      );
      return;
    }
    _receivedDeviceIds.add(ack.deviceId);
    _receivedAcks[ack.deviceId] = ack;
    if (_receivedDeviceIds.containsAll(_expectedDeviceIds)) {
      final allExecuted = _receivedAcks.values.every(
        (value) => value.status == 'executed',
      );
      final result = allExecuted
          ? '设备返回executed，ACK已上传后端'
          : '设备返回${_receivedAcks.values.map((value) => '${value.status}/${value.errorCode}').join('、')}，ACK已上传后端';
      _finish(command.commandId, result);
    } else {
      _setStatus(
        '已收到${_receivedDeviceIds.length}/${_expectedDeviceIds.length}侧AckEvent，继续等待另一侧',
      );
    }
  }

  void _finish(String commandId, String message) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _completedCommandIds.add(commandId);
    _active = null;
    _expectedDeviceIds = const {};
    _receivedDeviceIds.clear();
    _receivedAcks.clear();
    _setStatus(message);
  }

  void _setStatus(String value) {
    status = value;
    _statuses.add(value);
  }

  static String _sideLabel(FootSide side) =>
      side == FootSide.left ? '左脚' : '右脚';

  static String _targetLabel(String target) => switch (target) {
        'left' => '左脚',
        'right' => '右脚',
        'both' => '左右脚',
        _ => target,
      };

  Future<void> dispose() async {
    _expiryTimer?.cancel();
    await _ackSubscription?.cancel();
    await _statuses.close();
  }
}
