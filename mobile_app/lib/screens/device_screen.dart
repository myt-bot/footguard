import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/ble_connection_state.dart';
import '../models/ble_scan_device.dart';
import '../models/foot_frame.dart';
import '../services/ble_connection_service.dart';
import '../services/ble_scanner_service.dart';

class DeviceScreen extends StatefulWidget {
  const DeviceScreen({
    super.key,
    required this.backendUrl,
    this.scanner,
    this.connectionService,
  });

  final String backendUrl;
  final BleScannerService? scanner;
  final BleConnectionService? connectionService;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  late final BleScannerService _scanner;
  late final bool _ownsScanner;
  late final BleConnectionService _connectionService;
  late final bool _ownsConnectionService;
  late final Future<RealtimeSnapshot> _backendSnapshot;
  StreamSubscription<BleScanSnapshot>? _snapshotSubscription;
  StreamSubscription<String?>? _errorSubscription;
  StreamSubscription<BleConnectionsSnapshot>? _connectionSubscription;
  BleScanSnapshot _scan = const BleScanSnapshot.empty();
  BleConnectionsSnapshot _connections =
      const BleConnectionsSnapshot.disconnected();
  String? _scanError;

  @override
  void initState() {
    super.initState();
    _ownsScanner = widget.scanner == null;
    _scanner = widget.scanner ?? BleScannerService();
    _ownsConnectionService = widget.connectionService == null;
    _connectionService = widget.connectionService ?? BleConnectionService();
    _scan = _scanner.current;
    _connections = _connectionService.current;
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
    _connectionSubscription = _connectionService.snapshots.listen((snapshot) {
      if (mounted) {
        setState(() => _connections = snapshot);
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

  Future<void> _connect(FootSide side) async {
    final device = side == FootSide.left ? _scan.left : _scan.right;
    if (device == null) {
      return;
    }
    if (_scan.isScanning) {
      await _scanner.stopScan();
    }
    try {
      await _connectionService.connect(device);
    } catch (_) {
      // BleConnectionService publishes the user-facing failure state.
    }
  }

  Future<void> _disconnect(FootSide side) =>
      _connectionService.disconnect(side);

  @override
  void dispose() {
    _snapshotSubscription?.cancel();
    _errorSubscription?.cancel();
    _connectionSubscription?.cancel();
    if (_ownsScanner) {
      unawaited(_scanner.dispose());
    }
    if (_ownsConnectionService) {
      unawaited(_connectionService.dispose());
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
          connection: _connections.left,
          onConnect: () => _connect(FootSide.left),
          onDisconnect: () => _disconnect(FootSide.left),
        ),
        const SizedBox(height: 10),
        _BleDeviceCard(
          title: '右脚BLE设备',
          expectedName: 'FootGuard-R',
          device: _scan.right,
          connection: _connections.right,
          onConnect: () => _connect(FootSide.right),
          onDisconnect: () => _disconnect(FootSide.right),
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
    required this.connection,
    required this.onConnect,
    required this.onDisconnect,
  });

  final String title;
  final String expectedName;
  final BleScanDevice? device;
  final BleConnectionInfo connection;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final found = device != null;
    final busy = connection.state == BleLinkState.connecting ||
        connection.state == BleLinkState.reconnecting ||
        connection.state == BleLinkState.discovering;
    final connected = connection.state == BleLinkState.ready;
    final canDisconnect = connection.state != BleLinkState.disconnected;
    final status = connection.deviceStatus;
    final stateLabel = switch (connection.state) {
      BleLinkState.disconnected => found ? '已发现' : '未发现',
      BleLinkState.connecting => '连接中',
      BleLinkState.reconnecting => '自动重连中',
      BleLinkState.discovering => '校验服务',
      BleLinkState.ready => '已连接',
      BleLinkState.error => '连接失败',
    };
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
                  connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  color: connected
                      ? const Color(0xFF147D73)
                      : const Color(0xFF718096),
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
                Chip(label: Text(stateLabel)),
              ],
            ),
            const Divider(),
            Text('广播名称：${device?.name ?? expectedName}'),
            Text('remoteId：${device?.remoteId ?? connection.remoteId ?? '--'}'),
            Text('信号强度：${device == null ? '--' : '${device!.rssi} dBm'}'),
            if (connected && status != null) ...[
              const SizedBox(height: 8),
              Text('MTU：${connection.mtu}'),
              Text('device_id：${status.deviceId}'),
              Text('固件版本：${status.firmwareVersion}'),
              Text('电量：${status.battery}%'),
              Text('设备状态：${status.state}'),
              Text('时间同步：${status.timeSynced ? '已同步' : '未同步'}'),
              const SizedBox(height: 8),
              Text('已接收帧数：${connection.receivedFrames}'),
              Text(
                '最新序号：${connection.latestFrame?.packetSeq ?? '--'}',
              ),
              Text(
                '最新时间戳：${connection.latestFrame?.timestampMs ?? '--'}',
              ),
              Text(
                '实时数据：${connection.latestFrame == null ? '等待SensorData' : '60字节解析正常'}',
              ),
              if (connection.sensorError != null)
                Text(
                  connection.sensorError!,
                  style: const TextStyle(color: Color(0xFFB54A42)),
                ),
            ] else ...[
              const SizedBox(height: 6),
              Text(
                connection.error ?? (found ? '已发现，尚未建立GATT连接' : '等待扫描结果'),
                style: TextStyle(
                  color: connection.state == BleLinkState.error
                      ? const Color(0xFFB54A42)
                      : const Color(0xFF718096),
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: ValueKey('connect_$expectedName'),
                    onPressed: found && !busy && !connected ? onConnect : null,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: Text(
                      busy
                          ? connection.state == BleLinkState.reconnecting
                              ? '自动重连中'
                              : '连接中'
                          : connection.state == BleLinkState.error
                              ? '重新连接'
                              : '连接',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: ValueKey('disconnect_$expectedName'),
                    onPressed: canDisconnect ? onDisconnect : null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('断开'),
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
