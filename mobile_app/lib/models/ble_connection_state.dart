import 'ble_device_status.dart';
import 'ble_scan_device.dart';

enum BleLinkState {
  disconnected,
  connecting,
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
    this.error,
  });

  const BleConnectionInfo.disconnected(this.side)
      : state = BleLinkState.disconnected,
        remoteId = null,
        mtu = null,
        deviceStatus = null,
        error = null;

  final FootSide side;
  final BleLinkState state;
  final String? remoteId;
  final int? mtu;
  final BleDeviceStatus? deviceStatus;
  final String? error;

  bool get isReady => state == BleLinkState.ready;
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
