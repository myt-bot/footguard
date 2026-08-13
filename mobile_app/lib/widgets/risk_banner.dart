import 'package:flutter/material.dart';

import '../models/risk_state.dart';

class RiskBanner extends StatelessWidget {
  const RiskBanner({
    super.key,
    required this.risk,
    this.activeRisks = const [],
    this.baselineReady = true,
    this.pressureAvailable = true,
  });

  final RiskState risk;
  final List<RiskState> activeRisks;
  final bool baselineReady;
  final bool pressureAvailable;

  @override
  Widget build(BuildContext context) {
    final displayedRisks = activeRisks.isEmpty ? [risk] : activeRisks;
    final (color, icon, title) = !baselineReady && risk.isNormal
        ? (const Color(0xFF39758C), Icons.tune_rounded, '本次穿戴基线学习中')
        : !pressureAvailable && risk.isNormal
            ? (const Color(0xFFC77822), Icons.sensors_off_rounded, '未检测到有效承重')
            : switch (risk.riskType) {
                'normal' => (
                    const Color(0xFF1A9B78),
                    Icons.verified_rounded,
                    '双足状态正常'
                  ),
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
                _ => (
                    const Color(0xFF718096),
                    Icons.sensors_off_rounded,
                    '双足数据不完整'
                  ),
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
                Text(!baselineReady && risk.isNormal
                    ? '热力图继续显示，压力风险与马达暂未启用'
                    : !pressureAvailable && risk.isNormal
                        ? '压力风险已暂停；请确认已穿戴并检查压力采集连接'
                        : displayedRisks
                            .map((item) =>
                                '${_riskLabel(item)} · 等级 ${item.riskLevel} · '
                                '${(item.durationMs / 1000).toStringAsFixed(1)} 秒')
                            .join('\n')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _riskLabel(RiskState item) => switch (item.riskType) {
        'left_load_bias' => '左偏',
        'right_load_bias' => '右偏',
        'forefoot_high' => item.riskSide == 'both'
            ? '双脚前掌高载'
            : item.riskSide == 'left'
                ? '左脚前掌高载'
                : '右脚前掌高载',
        'temperature_asymmetry' =>
          item.riskSide == 'left' ? '左脚同区温度较高' : '右脚同区温度较高',
        'normal' => '当前正常',
        _ => '数据不完整',
      };
}
