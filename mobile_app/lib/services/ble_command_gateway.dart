import 'dart:async';

import '../models/ble_connection_state.dart';
import '../models/device_ack.dart';
import '../models/device_command.dart';

abstract interface class BleCommandGateway {
  Stream<DeviceAck> get acknowledgements;

  BleConnectionsSnapshot get current;

  Future<void> sendCommand(DeviceCommand command);
}
