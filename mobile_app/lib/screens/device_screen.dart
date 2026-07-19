import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/foot_frame.dart';

class DeviceScreen extends StatelessWidget {
  const DeviceScreen({super.key, required this.backendUrl});
  final String backendUrl;

  @override
  Widget build(BuildContext context) {
    final api = FootGuardApiClient(baseUrl: backendUrl);
    return FutureBuilder<RealtimeSnapshot>(
      future: api.realtime().whenComplete(api.close),
      builder: (context, snapshot) {
        final data = snapshot.data;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('双足设备',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            _DeviceCard(side: '左脚', frame: data?.left),
            const SizedBox(height: 10),
            _DeviceCard(side: '右脚', frame: data?.right),
            const SizedBox(height: 18),
            const Card(
              elevation: 0,
              child: ListTile(
                leading: Icon(Icons.bluetooth_searching_rounded),
                title: Text('真实 BLE 接入'),
                subtitle: Text('扫描、双设备独立连接、60 字节解析和马达写入接口已在下一阶段预留'),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.side, required this.frame});
  final String side;
  final FootFrame? frame;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.memory_rounded, color: Color(0xFF147D73)),
              const SizedBox(width: 8),
              Text(side,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const Spacer(),
              Chip(label: Text(frame == null ? '未连接' : '在线')),
            ]),
            const Divider(),
            Text('device_id：${frame?.deviceId ?? '--'}'),
            Text('电量：${frame?.battery ?? '--'}%'),
            Text('协议：${frame?.protocolVersion ?? '--'}'),
            Text('数据源：${frame?.source ?? '--'}'),
          ]),
        ),
      );
}
