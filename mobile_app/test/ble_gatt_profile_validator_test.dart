import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ble_connection_state.dart';
import 'package:footguard/models/ble_scan_device.dart';
import 'package:footguard/services/ble_gatt.dart';
import 'package:footguard/services/ble_gatt_profile_validator.dart';

Matcher _profileError(String code) => isA<BleGattProfileException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  test('accepts the complete FootGuard GATT profile', () {
    expect(
      () => BleGattProfileValidator.validate(
        serviceUuid: FootGuardGatt.serviceUuid,
        characteristicUuids: BleGattProfileValidator.requiredCharacteristics,
      ),
      returnsNormally,
    );
  });

  test('rejects the wrong service UUID', () {
    expect(
      () => BleGattProfileValidator.validate(
        serviceUuid: '0000180f-0000-1000-8000-00805f9b34fb',
        characteristicUuids: BleGattProfileValidator.requiredCharacteristics,
      ),
      throwsA(_profileError('service_mismatch')),
    );
  });

  test('rejects a profile with a missing characteristic', () {
    final incomplete = BleGattProfileValidator.requiredCharacteristics
        .where((uuid) => uuid != FootGuardGatt.ackEventUuid);
    expect(
      () => BleGattProfileValidator.validate(
        serviceUuid: FootGuardGatt.serviceUuid,
        characteristicUuids: incomplete,
      ),
      throwsA(_profileError('missing_characteristics')),
    );
  });

  test('connection snapshot tracks left and right independently', () {
    const leftReady = BleConnectionInfo(
      side: FootSide.left,
      state: BleLinkState.ready,
      remoteId: 'left-id',
      mtu: 247,
    );
    final snapshot = const BleConnectionsSnapshot.disconnected().replace(
      leftReady,
    );
    expect(snapshot.left.isReady, isTrue);
    expect(snapshot.left.mtu, 247);
    expect(snapshot.right.state, BleLinkState.disconnected);
  });
}
