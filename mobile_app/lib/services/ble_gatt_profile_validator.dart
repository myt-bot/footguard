import 'ble_gatt.dart';

class BleGattProfileException implements Exception {
  const BleGattProfileException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleGattProfileException($code): $message';
}

class BleGattProfileValidator {
  BleGattProfileValidator._();

  static const requiredCharacteristics = {
    FootGuardGatt.sensorDataUuid,
    FootGuardGatt.deviceStatusUuid,
    FootGuardGatt.deviceCommandUuid,
    FootGuardGatt.timeSyncUuid,
    FootGuardGatt.ackEventUuid,
  };

  static void validate({
    required String serviceUuid,
    required Iterable<String> characteristicUuids,
  }) {
    if (serviceUuid.toLowerCase() != FootGuardGatt.serviceUuid) {
      throw BleGattProfileException(
        'service_mismatch',
        'Expected ${FootGuardGatt.serviceUuid}, got $serviceUuid',
      );
    }
    final actual =
        characteristicUuids.map((uuid) => uuid.toLowerCase()).toSet();
    final missing = requiredCharacteristics.difference(actual).toList()..sort();
    if (missing.isNotEmpty) {
      throw BleGattProfileException(
        'missing_characteristics',
        'Missing FootGuard characteristics: ${missing.join(', ')}',
      );
    }
  }
}
