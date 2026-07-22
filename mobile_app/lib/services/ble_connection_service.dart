import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/ble_connection_state.dart';
import '../models/ble_scan_device.dart';
import '../models/device_ack.dart';
import '../models/device_command.dart';
import 'ble_command_gateway.dart';
import 'ble_control_codec.dart';
import 'ble_frame_parser.dart';
import 'ble_gatt.dart';
import 'ble_gatt_profile_validator.dart';
import 'ble_known_device_store.dart';
import 'ble_reconnect_policy.dart';

class BleConnectionException implements Exception {
  const BleConnectionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleConnectionException($code): $message';
}

class BleConnectionService implements BleCommandGateway {
  BleConnectionService({
    BleControlCodec? codec,
    BleFrameParser? frameParser,
    BleKnownDeviceStore? knownDeviceStore,
    BleReconnectPolicy reconnectPolicy = const BleReconnectPolicy(),
  })  : _codec = codec ?? const BleControlCodec(),
        _frameParser = frameParser ?? const BleFrameParser(),
        _knownDeviceStore =
            knownDeviceStore ?? const SharedPreferencesBleKnownDeviceStore(),
        _reconnectPolicy = reconnectPolicy {
    unawaited(_restoreKnownDevices());
  }

  final BleControlCodec _codec;
  final BleFrameParser _frameParser;
  final BleKnownDeviceStore _knownDeviceStore;
  final BleReconnectPolicy _reconnectPolicy;
  final _snapshots = StreamController<BleConnectionsSnapshot>.broadcast();
  final _acknowledgements = StreamController<DeviceAck>.broadcast();
  final _devices = <FootSide, BluetoothDevice>{};
  final _connectionSubscriptions =
      <FootSide, StreamSubscription<BluetoothConnectionState>>{};
  final _sensorSubscriptions = <FootSide, StreamSubscription<List<int>>>{};
  final _ackSubscriptions = <FootSide, StreamSubscription<List<int>>>{};
  final _characteristics = <FootSide, Map<String, BluetoothCharacteristic>>{};
  final _knownDevices = <FootSide, BleScanDevice>{};
  final _autoReconnectSides = <FootSide>{};
  final _connectInProgress = <FootSide>{};
  final _disconnectHandling = <FootSide>{};
  final _reconnectAttempts = <FootSide, int>{};
  final _reconnectTimers = <FootSide, Timer>{};

  int? _sessionSyncId;
  BleConnectionsSnapshot _current = const BleConnectionsSnapshot.disconnected();
  bool _disposed = false;

  Stream<BleConnectionsSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<DeviceAck> get acknowledgements => _acknowledgements.stream;
  @override
  BleConnectionsSnapshot get current => _current;

  Future<void> connect(BleScanDevice scanned) async {
    _ensureActive();
    final side = scanned.side;
    _knownDevices[side] = scanned;
    _autoReconnectSides.add(side);
    _reconnectAttempts[side] = 0;
    try {
      await _knownDeviceStore.save(scanned);
    } catch (_) {
      // The current connection can still proceed when persistence is unavailable.
    }
    await _connect(scanned, isReconnect: false);
  }

  Future<void> _connect(
    BleScanDevice scanned, {
    required bool isReconnect,
  }) async {
    final side = scanned.side;
    if (_connectInProgress.contains(side)) {
      return;
    }
    _connectInProgress.add(side);
    _reconnectTimers.remove(side)?.cancel();
    await _clearTransport(side);
    _emit(BleConnectionInfo(
      side: side,
      state: isReconnect ? BleLinkState.reconnecting : BleLinkState.connecting,
      remoteId: scanned.remoteId,
      error: isReconnect ? '正在自动重连${_sideLabel(side)}设备' : null,
    ));

    final device = BluetoothDevice.fromId(scanned.remoteId);
    _devices[side] = device;
    _connectionSubscriptions[side] = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          !_connectInProgress.contains(side) &&
          _autoReconnectSides.contains(side)) {
        unawaited(_handleUnexpectedDisconnect(side));
      }
    });

    try {
      if (device.isDisconnected) {
        await device.connect(
          license: License.nonprofit,
          mtu: null,
        );
      }
      if (!_autoReconnectSides.contains(side)) {
        await _clearTransport(side);
        return;
      }

      _emit(BleConnectionInfo(
        side: side,
        state: BleLinkState.discovering,
        remoteId: scanned.remoteId,
      ));

      final mtu = await device.requestMtu(FootGuardGatt.preferredMtu);
      if (mtu < FootGuardGatt.minimumSensorMtu) {
        throw BleConnectionException(
          'mtu_too_small',
          '协商MTU为$mtu，SensorData至少需要${FootGuardGatt.minimumSensorMtu}',
        );
      }

      final services = await device.discoverServices();
      final footService = services
          .where(
            (service) =>
                service.uuid.str.toLowerCase() == FootGuardGatt.serviceUuid,
          )
          .firstOrNull;
      if (footService == null) {
        throw const BleConnectionException(
          'service_not_found',
          '设备未提供FootGuard GATT服务',
        );
      }

      BleGattProfileValidator.validate(
        serviceUuid: footService.uuid.str,
        characteristicUuids: footService.characteristics.map(
          (characteristic) => characteristic.uuid.str,
        ),
      );
      final characteristics = {
        for (final characteristic in footService.characteristics)
          characteristic.uuid.str.toLowerCase(): characteristic,
      };
      _characteristics[side] = characteristics;

      final statusCharacteristic =
          characteristics[FootGuardGatt.deviceStatusUuid]!;
      final statusBytes = await statusCharacteristic.read();
      final expectedSide = side == FootSide.left ? 'left' : 'right';
      var status = _codec.decodeDeviceStatus(
        statusBytes,
        expectedSide: expectedSide,
      );

      if (!status.timeSynced) {
        final unixTimeMs = DateTime.now().millisecondsSinceEpoch;
        final syncId = _sharedSessionSyncId();
        final payload = _codec.encodeTimeSync(
          syncId: syncId,
          unixTimeMs: unixTimeMs,
        );
        await characteristics[FootGuardGatt.timeSyncUuid]!.write(
          payload,
          withoutResponse: false,
        );

        final refreshedStatusBytes = await statusCharacteristic.read();
        status = _codec.decodeDeviceStatus(
          refreshedStatusBytes,
          expectedSide: expectedSide,
        );
        if (!status.timeSynced || status.syncId != syncId) {
          throw const BleConnectionException(
            'time_sync_failed',
            'TimeSync写入后设备未确认时间同步',
          );
        }
      }
      if (!_autoReconnectSides.contains(side)) {
        await _clearTransport(side);
        return;
      }

      final ackCharacteristic = characteristics[FootGuardGatt.ackEventUuid]!;
      await _ackSubscriptions.remove(side)?.cancel();
      _ackSubscriptions[side] = ackCharacteristic.onValueReceived.listen(
        (bytes) => _handleAckEvent(
          side: side,
          deviceId: status.deviceId,
          bytes: bytes,
        ),
        onError: (Object error) => _handleAckError(side, error),
      );
      await ackCharacteristic.setNotifyValue(true);

      _emit(BleConnectionInfo(
        side: side,
        state: BleLinkState.ready,
        remoteId: scanned.remoteId,
        mtu: mtu,
        deviceStatus: status,
      ));

      final sensorCharacteristic =
          characteristics[FootGuardGatt.sensorDataUuid]!;
      await _sensorSubscriptions.remove(side)?.cancel();
      _sensorSubscriptions[side] = sensorCharacteristic.onValueReceived.listen(
        (bytes) => _handleSensorData(
          side: side,
          deviceId: status.deviceId,
          bytes: bytes,
        ),
        onError: (Object error) => _handleSensorError(side, error),
      );
      await sensorCharacteristic.setNotifyValue(true);
      _reconnectAttempts[side] = 0;
    } catch (error) {
      if (!_autoReconnectSides.contains(side)) {
        await _clearTransport(side);
        return;
      }
      final message = error is BleConnectionException
          ? error.message
          : 'BLE连接或服务发现失败：$error';
      await _clearTransport(side);
      if (_autoReconnectSides.contains(side)) {
        _scheduleReconnect(side, reason: message);
      } else {
        _emit(BleConnectionInfo(
          side: side,
          state: BleLinkState.error,
          remoteId: scanned.remoteId,
          error: message,
        ));
      }
      if (!isReconnect) {
        rethrow;
      }
    } finally {
      _connectInProgress.remove(side);
    }
  }

  BluetoothCharacteristic? characteristic(
    FootSide side,
    String uuid,
  ) =>
      _characteristics[side]?[uuid.toLowerCase()];

  @override
  Future<void> sendCommand(DeviceCommand command) async {
    _ensureActive();
    if (command.expired) {
      throw const BleConnectionException(
        'command_expired',
        '命令已经过期，未写入设备',
      );
    }
    final sides = switch (command.target) {
      'left' => const [FootSide.left],
      'right' => const [FootSide.right],
      'both' => const [FootSide.left, FootSide.right],
      _ => throw const BleConnectionException(
          'invalid_target',
          '命令目标必须是left、right或both',
        ),
    };
    final payload = _codec.encodeDeviceCommand(command);
    final writes = <Future<void>>[];
    for (final side in sides) {
      final connection = _current.forSide(side);
      final characteristic =
          _characteristics[side]?[FootGuardGatt.deviceCommandUuid];
      if (!connection.isReady ||
          connection.deviceStatus == null ||
          characteristic == null) {
        throw BleConnectionException(
          'device_not_ready',
          '${_sideLabel(side)}设备尚未完成BLE连接',
        );
      }
      if (!connection.deviceStatus!.timeSynced) {
        throw BleConnectionException(
          'time_unsynced',
          '${_sideLabel(side)}设备尚未完成时间同步',
        );
      }
      final mtu = connection.mtu ?? FootGuardGatt.preferredMtu;
      if (payload.length > mtu - 3) {
        throw BleConnectionException(
          'command_too_large',
          'DeviceCommand为${payload.length}字节，超过MTU ${mtu - 3}字节载荷',
        );
      }
      writes.add(characteristic.write(payload, withoutResponse: false));
    }
    await Future.wait(writes);
  }

  Future<void> disconnect(FootSide side) async {
    _autoReconnectSides.remove(side);
    _knownDevices.remove(side);
    _reconnectAttempts.remove(side);
    _reconnectTimers.remove(side)?.cancel();
    try {
      await _knownDeviceStore.remove(side);
    } catch (_) {
      // Manual disconnect still takes effect when persistence is unavailable.
    }
    await _clearTransport(side);
    _emit(BleConnectionInfo.disconnected(side));
  }

  Future<void> _clearTransport(FootSide side) async {
    await _sensorSubscriptions.remove(side)?.cancel();
    await _ackSubscriptions.remove(side)?.cancel();
    await _connectionSubscriptions.remove(side)?.cancel();
    _characteristics.remove(side);
    final device = _devices.remove(side);
    if (device != null && device.isConnected) {
      await device.disconnect();
    }
  }

  Future<void> _restoreKnownDevices() async {
    for (final side in FootSide.values) {
      try {
        final known = await _knownDeviceStore.load(side);
        if (_disposed || known == null) {
          continue;
        }
        _knownDevices[side] = known;
        _autoReconnectSides.add(side);
        _reconnectAttempts[side] = 0;
        _scheduleReconnect(side, immediate: true, reason: '正在恢复上次连接');
      } catch (_) {
        // Start normally when no saved device is available.
      }
    }
  }

  Future<void> _handleUnexpectedDisconnect(FootSide side) async {
    if (_disposed ||
        !_autoReconnectSides.contains(side) ||
        _disconnectHandling.contains(side)) {
      return;
    }
    _disconnectHandling.add(side);
    try {
      await _clearTransport(side);
      _scheduleReconnect(side, reason: '${_sideLabel(side)}设备连接已中断');
    } finally {
      _disconnectHandling.remove(side);
    }
  }

  void _scheduleReconnect(
    FootSide side, {
    bool immediate = false,
    String? reason,
  }) {
    if (_disposed || !_autoReconnectSides.contains(side)) {
      return;
    }
    final known = _knownDevices[side];
    if (known == null) {
      return;
    }
    _reconnectTimers.remove(side)?.cancel();
    final attempt = (_reconnectAttempts[side] ?? 0) + 1;
    _reconnectAttempts[side] = attempt;
    final delay =
        immediate ? Duration.zero : _reconnectPolicy.delayForAttempt(attempt);
    final delayText =
        delay == Duration.zero ? '立即重连' : '${delay.inSeconds}秒后重连';
    _emit(BleConnectionInfo(
      side: side,
      state: BleLinkState.reconnecting,
      remoteId: known.remoteId,
      error: '${reason ?? '连接失败'}，$delayText（第$attempt次）',
    ));
    _reconnectTimers[side] = Timer(
      delay,
      () => unawaited(_connect(known, isReconnect: true)),
    );
  }

  int _sharedSessionSyncId() {
    final existing = _sessionSyncId;
    if (existing != null) return existing;
    var created = DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF;
    if (created == 0) created = 1;
    _sessionSyncId = created;
    return created;
  }

  static String _sideLabel(FootSide side) =>
      side == FootSide.left ? '左脚' : '右脚';

  void _handleSensorData({
    required FootSide side,
    required String deviceId,
    required List<int> bytes,
  }) {
    try {
      final expectedSide = side == FootSide.left ? 'left' : 'right';
      final frame = _frameParser.parse(
        bytes,
        deviceId: deviceId,
        expectedSide: expectedSide,
      );
      final current = _current.forSide(side);
      _emit(current.copyWith(
        latestFrame: frame,
        receivedFrames: current.receivedFrames + 1,
      ));
    } catch (error) {
      _handleSensorError(side, error);
    }
  }

  void _handleSensorError(FootSide side, Object error) {
    final current = _current.forSide(side);
    _emit(current.copyWith(sensorError: 'SensorData解析失败：$error'));
  }

  void _handleAckEvent({
    required FootSide side,
    required String deviceId,
    required List<int> bytes,
  }) {
    try {
      final ack = _codec.decodeAckEvent(
        bytes,
        expectedDeviceId: deviceId,
      );
      _acknowledgements.add(ack);
    } catch (error) {
      _handleAckError(side, error);
    }
  }

  void _handleAckError(FootSide side, Object error) {
    final current = _current.forSide(side);
    _emit(current.copyWith(error: 'AckEvent解析失败：$error'));
  }

  void _emit(BleConnectionInfo value) {
    if (_disposed) {
      return;
    }
    _current = _current.replace(value);
    _snapshots.add(_current);
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('BleConnectionService has been disposed');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _autoReconnectSides.clear();
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    await _clearTransport(FootSide.left);
    await _clearTransport(FootSide.right);
    await _acknowledgements.close();
    await _snapshots.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
