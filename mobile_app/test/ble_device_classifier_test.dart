import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/services/ble_device_classifier.dart';

void main() {
  test('classifies the official left advertisement name', () {
    final device = BleDeviceClassifier.classify(
      remoteId: 'AA:BB:CC:DD:EE:01',
      advertisedName: 'FootGuard-L',
      rssi: -48,
    );
    expect(device, isNotNull);
    expect(device!.side, FootSide.left);
    expect(device.sideName, 'left');
    expect(device.name, 'FootGuard-L');
  });

  test('classifies the official right advertisement name', () {
    final device = BleDeviceClassifier.classify(
      remoteId: 'AA:BB:CC:DD:EE:02',
      advertisedName: 'FootGuard-R',
      rssi: -52,
    );
    expect(device, isNotNull);
    expect(device!.side, FootSide.right);
    expect(device.sideName, 'right');
  });

  test('ignores unknown names and empty remote identifiers', () {
    expect(
      BleDeviceClassifier.classify(
        remoteId: 'AA:BB',
        advertisedName: 'OtherDevice',
        rssi: -60,
      ),
      isNull,
    );
    expect(
      BleDeviceClassifier.classify(
        remoteId: ' ',
        advertisedName: 'FootGuard-L',
        rssi: -60,
      ),
      isNull,
    );
  });

  test('scan snapshot reports whether both sides were found', () {
    const left = BleScanDevice(
      remoteId: 'left-id',
      name: 'FootGuard-L',
      side: FootSide.left,
      rssi: -45,
    );
    const right = BleScanDevice(
      remoteId: 'right-id',
      name: 'FootGuard-R',
      side: FootSide.right,
      rssi: -47,
    );
    expect(
        const BleScanSnapshot(isScanning: true, left: left).bothFound, isFalse);
    expect(
      const BleScanSnapshot(isScanning: true, left: left, right: right)
          .bothFound,
      isTrue,
    );
  });
}
