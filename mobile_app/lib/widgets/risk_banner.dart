import 'package:flutter/material.dart';

import '../models/risk_state.dart';

class RiskBanner extends StatelessWidget {
  const RiskBanner({super.key, required this.risk});

  final RiskState risk;

  @override
  Widget build(BuildContext context) {
    final (color, icon, title) = switch (risk.riskType) {
      'normal' => (const Color(0xFF1A9B78), Icons.verified_rounded, '双足状态正常'),
      'left_load_bias' => (
          const Color(0xFFF08A24),
          Icons.keyboard_double_arrow_left,
          '检测到持续左偏'
        ),
      'right_load_bias' => (
          const Color(0xFFF08A24),
          Icons.keyboard_double_arrow_right,
          '检测到持续右偏'
        ),
      'forefoot_high' => (
          const Color(0xFFDE5D52),
          Icons.warning_amber_rounded,
          '前掌持续高载'
        ),
      'temperature_asymmetry' => (
          const Color(0xFFD9534F),
          Icons.device_thermostat_rounded,
          '检测到同区异常温差'
        ),
      _ => (const Color(0xFF718096), Icons.sensors_off_rounded, '双足数据不完整'),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          CircleAvatar(
              backgroundColor: color, child: Icon(icon, color: Colors.white)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                    '风险等级 ${risk.riskLevel} · 持续 ${(risk.durationMs / 1000).toStringAsFixed(1)} 秒'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
