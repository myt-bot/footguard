import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/risk_state.dart';

class RiskBanner extends StatelessWidget {
  const RiskBanner({
    super.key,
    required this.risk,
    this.activeRisks = const [],
    this.baselineReady = true,
    this.pressureAvailable = true,
    this.recoveryObservation,
    this.backendOnline = true,
  });

  final RiskState risk;
  final List<RiskState> activeRisks;
  final bool baselineReady;
  final bool pressureAvailable;
  final RecoveryObservation? recoveryObservation;
  final bool backendOnline;

  @override
  Widget build(BuildContext context) {
    final displayedRisks = activeRisks.isEmpty ? [risk] : activeRisks;
    final pressureRisks =
        displayedRisks.where((item) => item.isPressure).toList(growable: false)
          ..sort((a, b) {
            final level = b.riskLevel.compareTo(a.riskLevel);
            return level != 0 ? level : b.durationMs.compareTo(a.durationMs);
          });
    final temperatureRisks = displayedRisks
        .where((item) => item.isTemperature)
        .toList(growable: false);
    final primary = pressureRisks.isNotEmpty
        ? pressureRisks.first
        : risk.isIncomplete
            ? risk
            : const RiskState(
                riskType: 'normal',
                riskSide: 'none',
                riskLevel: 0,
                durationMs: 0,
              );
    final multiplePressureRisks = pressureRisks.length > 1;
    final (color, icon, title) = !baselineReady && risk.isNormal
        ? (const Color(0xFF39758C), Icons.tune_rounded, '本次穿戴基线学习中')
        : !pressureAvailable && risk.isNormal
            ? (const Color(0xFFC77822), Icons.sensors_off_rounded, '未检测到有效承重')
            : switch (primary.riskType) {
                'normal' => (
                    const Color(0xFF1A9B78),
                    Icons.verified_rounded,
                    '双足状态正常',
                  ),
                'left_load_bias' => (
                    const Color(0xFFF08A24),
                    Icons.keyboard_double_arrow_left,
                    '双足负载分配异常',
                  ),
                'right_load_bias' => (
                    const Color(0xFFF08A24),
                    Icons.keyboard_double_arrow_right,
                    '双足负载分配异常',
                  ),
                'forefoot_high' => (
                    const Color(0xFFDE5D52),
                    Icons.warning_amber_rounded,
                    _riskLabel(primary),
                  ),
                'medial_load_concentration' || 'lateral_load_concentration' => (
                    const Color(0xFFDE5D52),
                    Icons.warning_amber_rounded,
                    _riskLabel(primary),
                  ),
                _ => (
                    primary.isIncomplete
                        ? const Color(0xFF718096)
                        : const Color(0xFFDE5D52),
                    primary.isIncomplete
                        ? Icons.sensors_off_rounded
                        : Icons.warning_amber_rounded,
                    primary.isIncomplete ? '双足数据不完整' : _riskLabel(primary),
                  ),
              };
    final resolvedTitle = multiplePressureRisks ? '多项压力风险' : title;
    final observation = recoveryObservation;
    final observing = observation?.status == 'observing';
    final seconds =
        observation == null ? 0 : (observation.remainingMs / 1000).ceil();
    final progress = observation == null
        ? 0.0
        : observing
            ? (1 - observation.remainingMs / 15000).clamp(0.0, 1.0)
            : 1.0;
    final result = switch (observation?.effectLabel) {
      'effective' => '压力分配已改善',
      'partial' => '部分压力指标改善',
      'ineffective' => '压力分配仍未改善',
      'worsened' => '压力异常偏离增加',
      _ => '数据不足',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: color,
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resolvedTitle,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      !baselineReady && risk.isNormal
                          ? '热力图继续显示，压力风险与马达暂未启用'
                          : !pressureAvailable && risk.isNormal
                              ? '压力风险已暂停；请确认已穿戴并检查压力采集连接'
                              : primary.isNormal
                                  ? '当前未发现需要减负的持续异常'
                                  : '${_stateLabel(primary.riskLevel)} · '
                                      '持续 ${(primary.durationMs / 1000).toStringAsFixed(1)} 秒',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (multiplePressureRisks) ...[
            const SizedBox(height: 10),
            const Text(
              '当前检测到',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: pressureRisks
                  .map(
                    (item) => Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text(_riskLabel(item)),
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
          if (observation != null) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  observing ? Icons.timer_outlined : Icons.fact_check_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    observing
                        ? (!backendOnline &&
                                !observation.eventId.startsWith('local_evt_')
                            ? '后端断开，压力重新分配观察已暂停'
                            : '提醒后的压力重新分配观察：$seconds 秒')
                        : '观察结果：$result',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            if (!observing && observation.componentFeedback.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: observation.componentFeedback
                    .where((item) => item.pressureIntervention)
                    .map(
                      (item) => Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${_componentLabel(item)}：${_componentEffect(item.effectLabel)}',
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ],
          if (temperatureRisks.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.device_thermostat_rounded,
                  size: 18,
                  color: Color(0xFFD9534F),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    temperatureRisks.map(_riskLabel).join('、'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            const Text(
              '温度趋势独立观察，不计入15秒压力改善结果。',
              style: TextStyle(fontSize: 11, color: Color(0xFF806119)),
            ),
          ],
        ],
      ),
    );
  }

  static String _stateLabel(int level) => switch (level) {
        >= 3 => '持续未改善',
        2 => '需要减负',
        1 => '趋势观察中',
        _ => '正常',
      };

  static String _riskLabel(RiskState item) =>
      riskDisplayLabel(item.riskType, item.riskSide);

  static String _componentLabel(RiskComponentFeedbackRecord item) =>
      switch (item.riskType) {
        'left_load_bias' => '左侧负载',
        'right_load_bias' => '右侧负载',
        'forefoot_high' => item.riskSide == 'both'
            ? '双脚前掌'
            : item.riskSide == 'left'
                ? '左脚前掌'
                : '右脚前掌',
        'medial_load_concentration' =>
          '${item.riskSide == 'left' ? '左脚' : '右脚'}内侧',
        'lateral_load_concentration' =>
          '${item.riskSide == 'left' ? '左脚' : '右脚'}外侧',
        _ => '压力指标',
      };

  static String _componentEffect(String value) => switch (value) {
        'effective' => '改善',
        'partial' => '部分改善',
        'ineffective' => '未改善',
        'worsened' => '偏离增加',
        _ => '数据不足',
      };
}
