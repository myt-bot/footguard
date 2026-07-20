class FootGuardGatt {
  FootGuardGatt._();

  static const serviceUuid = '7d2f0000-5a6b-4c7d-8e9f-102030405060';
  static const sensorDataUuid = '7d2f0001-5a6b-4c7d-8e9f-102030405060';
  static const deviceStatusUuid = '7d2f0002-5a6b-4c7d-8e9f-102030405060';
  static const deviceCommandUuid = '7d2f0003-5a6b-4c7d-8e9f-102030405060';
  static const timeSyncUuid = '7d2f0004-5a6b-4c7d-8e9f-102030405060';
  static const ackEventUuid = '7d2f0005-5a6b-4c7d-8e9f-102030405060';

  static const preferredMtu = 247;
  static const minimumSensorMtu = 63;
}
