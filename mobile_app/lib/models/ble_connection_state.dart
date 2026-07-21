import 'ble_device_status.dart';
import 'ble_scan_device.dart';
import 'foot_frame.dart';

enum BleLinkState {
  disconnected,
  connecting,
  reconnecting,
  discovering,
  ready,
  error,
}

class BleConnectionInfo {
  const BleConnectionInfo({
    required this.side,
    required this.state,
    this.remoteId,
    this.mtu,
    this.deviceStatus,
    this.latestFrame,
    this.receivedFrames = 0,
    this.sensorError,
    this.error,
  });

  const BleConnectionInfo.disconnected(this.side)
      : state = BleLinkState.disconnected,
        remoteId = null,
        mtu = null,
        deviceStatus = null,
        latestFrame = null,
        receivedFrames = 0,
        sensorError = null,
        error = null;

  final FootSide side;
  final BleLinkState state;
  final String? remoteId;
  final int? mtu;
  final BleDeviceStatus? deviceStatus;
  final FootFrame? latestFrame;
  final int receivedFrames;
  final String? sensorError;
  final String? error;

  bool get isReady => state == BleLinkState.ready;

  BleConnectionInfo copyWith({
    BleLinkState? state,
    String? remoteId,
    int? mtu,
    BleDeviceStatus? deviceStatus,
    FootFrame? latestFrame,
    int? receivedFrames,
    String? sensorError,
    String? error,
  }) =>
      BleConnectionInfo(
        side: side,
        state: state ?? this.state,
        remoteId: remoteId ?? this.remoteId,
        mtu: mtu ?? this.mtu,
        deviceStatus: deviceStatus ?? this.deviceStatus,
        latestFrame: latestFrame ?? this.latestFrame,
        receivedFrames: receivedFrames ?? this.receivedFrames,
        sensorError: sensorError,
        error: error ?? this.error,
      );
}

class BleConnectionsSnapshot {
  const BleConnectionsSnapshot({required this.left, required this.right});

  const BleConnectionsSnapshot.disconnected()
      : left = const BleConnectionInfo.disconnected(FootSide.left),
        right = const BleConnectionInfo.disconnected(FootSide.right);

  final BleConnectionInfo left;
  final BleConnectionInfo right;

  BleConnectionInfo forSide(FootSide side) =>
      side == FootSide.left ? left : right;

  BleConnectionsSnapshot replace(BleConnectionInfo value) =>
      value.side == FootSide.left
          ? BleConnectionsSnapshot(left: value, right: right)
          : BleConnectionsSnapshot(left: left, right: value);
}
