import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/services/ble_known_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('stores left and right BLE identities independently', () async {
    const store = SharedPreferencesBleKnownDeviceStore();
    const left = BleScanDevice(
      remoteId: 'AA:BB:CC:DD:EE:01',
      name: 'FootGuard-L',
      side: FootSide.left,
      rssi: -45,
    );
    const right = BleScanDevice(
      remoteId: 'AA:BB:CC:DD:EE:02',
      name: 'FootGuard-R',
      side: FootSide.right,
      rssi: -47,
    );

    await store.save(left);
    await store.save(right);

    expect((await store.load(FootSide.left))?.remoteId, left.remoteId);
    expect((await store.load(FootSide.right))?.remoteId, right.remoteId);
  });

  test('manual removal prevents a saved device from being restored', () async {
    const store = SharedPreferencesBleKnownDeviceStore();
    await store.save(const BleScanDevice(
      remoteId: 'AA:BB:CC:DD:EE:01',
      name: 'FootGuard-L',
      side: FootSide.left,
      rssi: -45,
    ));

    await store.remove(FootSide.left);

    expect(await store.load(FootSide.left), isNull);
  });
}
