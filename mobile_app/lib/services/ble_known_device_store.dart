import 'package:shared_preferences/shared_preferences.dart';

import '../models/ble_scan_device.dart';

abstract interface class BleKnownDeviceStore {
  Future<BleScanDevice?> load(FootSide side);

  Future<void> save(BleScanDevice device);

  Future<void> remove(FootSide side);
}

class SharedPreferencesBleKnownDeviceStore implements BleKnownDeviceStore {
  const SharedPreferencesBleKnownDeviceStore();

  static String _key(FootSide side) =>
      'ble.known_device.${side == FootSide.left ? 'left' : 'right'}';

  @override
  Future<BleScanDevice?> load(FootSide side) async {
    final preferences = await SharedPreferences.getInstance();
    final remoteId = preferences.getString(_key(side))?.trim();
    if (remoteId == null || remoteId.isEmpty) {
      return null;
    }
    return BleScanDevice(
      remoteId: remoteId,
      name: side == FootSide.left ? 'FootGuard-L' : 'FootGuard-R',
      side: side,
      rssi: 0,
    );
  }

  @override
  Future<void> save(BleScanDevice device) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key(device.side), device.remoteId);
  }

  @override
  Future<void> remove(FootSide side) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(side));
  }
}
