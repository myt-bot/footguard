import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/ble_scan_device.dart';
import '../models/foot_frame.dart';
import '../services/ble_scanner_service.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.backendUrl,
    this.scanner,
  });

  final String backendUrl;
  final BleScannerService? scanner;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final BleScannerService _scanner;
  late final bool _ownsScanner;
  late final Future<RealtimeSnapshot> _backendSnapshot;
  StreamSubscription<BleScanSnapshot>? _snapshotSubscription;
  StreamSubscription<String?>? _errorSubscription;
  BleScanSnapshot _scan = const BleScanSnapshot.empty();
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _ownsScanner = widget.scanner == null;
    _scanner = widget.scanner ?? BleScannerService();
    _scan = _scanner.current;
    _snapshotSubscription = _scanner.snapshots.listen((snapshot) {
      if (mounted) {
        setState(() => _scan = snapshot);
      }
    });
    _errorSubscription = _scanner.errors.listen((message) {
      if (mounted) {
        setState(() => _scanError = message);
      }
    });
    final api = FootGuardApiClient(baseUrl: widget.backendUrl);
    _backendSnapshot = api.realtime().whenComplete(api.close);
  }

  Future<void> _startScan() async {
    setState(() => _scanError = null);
    try {
      await _scanner.startScan();
    } on BleScannerException catch (error) {
      if (mounted) {
        setState(() => _scanError = error.message);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _scanError = '无法启动BLE扫描：$error');
      }
    }
  }

  Future<void> _stopScan() => _scanner.stopScan();

  @override
  void dispose() {
    _snapshotSubscription?.cancel();
    _errorSubscription?.cancel();
    if (_ownsScanner) {
      unawaited(_scanner.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '双足设备',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 12),
        _ScanControlCard(
          snapshot: _scan,
          error: _scanError,
          onStart: _startScan,
          onStop: _stopScan,
        ),
        const SizedBox(height: 12),
        _BleDeviceCard(
          title: '左脚BLE设备',
          expectedName: 'FootGuard-L',
          device: _scan.left,
        ),
        const SizedBox(height: 10),
        _BleDeviceCard(
          title: '右脚BLE设备',
          expectedName: 'FootGuard-R',
          device: _scan.right,
        ),
        const SizedBox(height: 20),
        Text(
          '后端最近数据',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<RealtimeSnapshot>(
          future: _backendSnapshot,
          builder: (context, snapshot) {
            final data = snapshot.data;
            return Column(
              children: [
                _BackendDeviceCard(side: '左脚', frame: data?.left),
                const SizedBox(height: 10),
                _BackendDeviceCard(side: '右脚', frame: data?.right),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ScanControlCard extends StatelessWidget {
  const _ScanControlCard({
    required this.snapshot,
    required this.error,
    required this.onStart,
    required this.onStop,
  });

  final BleScanSnapshot snapshot;
  final String? error;
  final Future<void> Function() onStart;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final status = snapshot.isScanning
        ? '正在搜索FootGuard设备…'
        : snapshot.bothFound
            ? '左右脚设备均已发现'
            : '尚未开始扫描';
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bluetooth_searching_rounded,
                  color: Color(0xFF147D73),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '真实BLE扫描',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(status, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                if (snapshot.isScanning)
                  const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                style: const TextStyle(
                  color: Color(0xFFB54A42),
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 13),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: snapshot.isScanning ? null : onStart,
                    icon: const Icon(Icons.radar_rounded),
                    label: const Text('开始扫描'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: snapshot.isScanning ? onStop : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('停止扫描'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BleDeviceCard extends StatelessWidget {
  const _BleDeviceCard({
    required this.title,
    required this.expectedName,
    required this.device,
  });

  final String title;
  final String expectedName;
  final BleScanDevice? device;

  @override
  Widget build(BuildContext context) {
    final found = device != null;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  found ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color:
                      found ? const Color(0xFF147D73) : const Color(0xFF718096),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Chip(label: Text(found ? '已发现' : '未发现')),
              ],
            ),
            const Divider(),
            Text('广播名称：${device?.name ?? expectedName}'),
            Text('remoteId：${device?.remoteId ?? '--'}'),
            Text('信号强度：${device == null ? '--' : '${device!.rssi} dBm'}'),
            const SizedBox(height: 6),
            Text(
              found ? '已发现，尚未建立GATT连接' : '等待扫描结果',
              style: const TextStyle(
                color: Color(0xFF718096),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackendDeviceCard extends StatelessWidget {
  const _BackendDeviceCard({required this.side, required this.frame});

  final String side;
  final FootFrame? frame;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.cloud_outlined, color: Color(0xFF147D73)),
                  const SizedBox(width: 8),
                  Text(
                    side,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Chip(label: Text(frame == null ? '无数据' : '在线')),
                ],
              ),
              const Divider(),
              Text('device_id：${frame?.deviceId ?? '--'}'),
              Text('电量：${frame?.battery ?? '--'}%'),
              Text('协议：${frame?.protocolVersion ?? '--'}'),
              Text('数据源：${frame?.source ?? '--'}'),
            ],
          ),
        ),
      );
}
