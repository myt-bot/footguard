import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/ble_scan_device.dart';
import 'ble_device_classifier.dart';
import 'ble_gatt.dart';

class BleScannerException implements Exception {
  const BleScannerException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BleScannerException($code): $message';
}

class BleScannerService {
  BleScannerService({this.scanTimeout = const Duration(seconds: 8)});

  final Duration scanTimeout;
  final _snapshots = StreamController<BleScanSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();

  StreamSubscription<List<ScanResult>>? _resultsSubscription;
  StreamSubscription<bool>? _scanningSubscription;
  BleScanSnapshot _current = const BleScanSnapshot.empty();
  bool _disposed = false;

  Stream<BleScanSnapshot> get snapshots => _snapshots.stream;
  Stream<String?> get errors => _errors.stream;
  BleScanSnapshot get current => _current;

  Future<void> startScan() async {
    _ensureActive();
    if (!await FlutterBluePlus.isSupported) {
      throw const BleScannerException(
        'not_supported',
        '当前设备不支持Bluetooth Low Energy',
      );
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      throw const BleScannerException(
        'bluetooth_off',
        '请打开手机蓝牙并允许“附近的设备”权限',
      );
    }

    FlutterBluePlus.setOperationQueueMode(OperationQueueMode.perDevice);
    await stopScan(clearResults: true);

    _resultsSubscription = FlutterBluePlus.onScanResults.listen(
      _handleResults,
      onError: (Object error) => _emitError('BLE扫描失败：$error'),
    );
    _scanningSubscription = FlutterBluePlus.isScanning.listen((isScanning) {
      _emit(_current.copyWith(isScanning: isScanning));
      if (!isScanning && !_current.bothFound) {
        _emitError('扫描结束：尚未同时发现FootGuard-L和FootGuard-R');
      }
    });

    _emit(const BleScanSnapshot(isScanning: true));
    _emitError(null);
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(FootGuardGatt.serviceUuid)],
        timeout: scanTimeout,
      );
    } catch (error) {
      _emit(const BleScanSnapshot.empty());
      throw BleScannerException('scan_failed', 'BLE扫描启动失败：$error');
    }
  }

  void _handleResults(List<ScanResult> results) {
    var left = _current.left;
    var right = _current.right;
    for (final result in results) {
      final found = BleDeviceClassifier.classify(
        remoteId: result.device.remoteId.str,
        advertisedName: result.advertisementData.advName,
        rssi: result.rssi,
      );
      if (found?.side == FootSide.left) {
        left = found;
      } else if (found?.side == FootSide.right) {
        right = found;
      }
    }
    _emit(BleScanSnapshot(
      isScanning: _current.isScanning,
      left: left,
      right: right,
    ));
    if (_current.bothFound) {
      _emitError(null);
      FlutterBluePlus.stopScan();
    }
  }

  Future<void> stopScan({bool clearResults = false}) async {
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    await _resultsSubscription?.cancel();
    await _scanningSubscription?.cancel();
    _resultsSubscription = null;
    _scanningSubscription = null;
    _emit(clearResults
        ? const BleScanSnapshot.empty()
        : BleScanSnapshot(
            isScanning: false,
            left: _current.left,
            right: _current.right,
          ));
  }

  void _emit(BleScanSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  void _emitError(String? message) {
    if (!_disposed) {
      _errors.add(message);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('BleScannerService has been disposed');
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await stopScan();
    _disposed = true;
    await _snapshots.close();
    await _errors.close();
  }
}
