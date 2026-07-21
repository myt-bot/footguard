import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/ble_connection_state.dart';
import '../models/ble_scan_device.dart';
import 'ble_control_codec.dart';
import 'ble_frame_parser.dart';
import 'ble_gatt.dart';
import 'ble_gatt_profile_validator.dart';

class BleConnectionException implements Exception {
  const BleConnectionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleConnectionException($code): $message';
}

class BleConnectionService {
  BleConnectionService({BleControlCodec? codec, BleFrameParser? frameParser})
      : _codec = codec ?? const BleControlCodec(),
        _frameParser = frameParser ?? const BleFrameParser();

  final BleControlCodec _codec;
  final BleFrameParser _frameParser;
  final _snapshots = StreamController<BleConnectionsSnapshot>.broadcast();
  final _devices = <FootSide, BluetoothDevice>{};
  final _connectionSubscriptions =
      <FootSide, StreamSubscription<BluetoothConnectionState>>{};
  final _sensorSubscriptions = <FootSide, StreamSubscription<List<int>>>{};
  final _characteristics = <FootSide, Map<String, BluetoothCharacteristic>>{};

  BleConnectionsSnapshot _current = const BleConnectionsSnapshot.disconnected();
  bool _disposed = false;

  Stream<BleConnectionsSnapshot> get snapshots => _snapshots.stream;
  BleConnectionsSnapshot get current => _current;

  Future<void> connect(BleScanDevice scanned) async {
    _ensureActive();
    final side = scanned.side;
    await disconnect(side);
    _emit(BleConnectionInfo(
      side: side,
      state: BleLinkState.connecting,
      remoteId: scanned.remoteId,
    ));

    final device = BluetoothDevice.fromId(scanned.remoteId);
    _devices[side] = device;
    _connectionSubscriptions[side] = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected &&
          _current.forSide(side).state != BleLinkState.error) {
        _characteristics.remove(side);
        _emit(BleConnectionInfo.disconnected(side));
      }
    });

    try {
      if (device.isDisconnected) {
        await device.connect(
          license: License.nonprofit,
          mtu: null,
        );
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
        var syncId = unixTimeMs & 0xFFFFFFFF;
        if (syncId == 0) {
          syncId = 1;
        }
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
    } catch (error) {
      final message = error is BleConnectionException
          ? error.message
          : 'BLE连接或服务发现失败：$error';
      _emit(BleConnectionInfo(
        side: side,
        state: BleLinkState.error,
        remoteId: scanned.remoteId,
        error: message,
      ));
      await device.disconnect();
      rethrow;
    }
  }

  BluetoothCharacteristic? characteristic(
    FootSide side,
    String uuid,
  ) =>
      _characteristics[side]?[uuid.toLowerCase()];

  Future<void> disconnect(FootSide side) async {
    await _sensorSubscriptions.remove(side)?.cancel();
    await _connectionSubscriptions.remove(side)?.cancel();
    _characteristics.remove(side);
    final device = _devices.remove(side);
    if (device != null && device.isConnected) {
      await device.disconnect();
    }
    _emit(BleConnectionInfo.disconnected(side));
  }

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
    await disconnect(FootSide.left);
    await disconnect(FootSide.right);
    _disposed = true;
    await _snapshots.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
