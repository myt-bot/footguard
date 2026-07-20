import '../models/ble_scan_device.dart';

class BleDeviceClassifier {
  BleDeviceClassifier._();

  static const leftName = 'FootGuard-L';
  static const rightName = 'FootGuard-R';

  static FootSide? sideFromName(String name) => switch (name.trim()) {
        leftName => FootSide.left,
        rightName => FootSide.right,
        _ => null,
      };

  static BleScanDevice? classify({
    required String remoteId,
    required String advertisedName,
    required int rssi,
  }) {
    final side = sideFromName(advertisedName);
    if (side == null || remoteId.trim().isEmpty) {
      return null;
    }
    return BleScanDevice(
      remoteId: remoteId,
      name: advertisedName.trim(),
      side: side,
      rssi: rssi,
    );
  }
}
