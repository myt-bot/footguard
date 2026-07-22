import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
  runApp(const FootGuardApp());
}
