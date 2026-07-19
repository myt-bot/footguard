import 'package:flutter/material.dart';

import '../data/foot_data_source.dart';

class ConnectionStatusCard extends StatelessWidget {
  const ConnectionStatusCard({
    super.key,
    required this.label,
    required this.status,
    required this.battery,
  });

  final String label;
  final FootConnectionStatus status;
  final int? battery;

  @override
  Widget build(BuildContext context) {
    final connected = status == FootConnectionStatus.connected;
    final color = connected ? const Color(0xFF1A9B78) : const Color(0xFF718096);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Row(
          children: [
            Icon(
                connected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
                color: color),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(connected ? '已连接 · ${battery ?? '--'}%' : '未连接',
                      style: TextStyle(color: color, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
