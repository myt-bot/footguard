import 'package:flutter/material.dart';

import '../data/api_client.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.backendUrl,
    this.apiClient,
  });

  final String backendUrl;
  final FootGuardApiClient? apiClient;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

enum _HistoryFilter { all, active, finished }

class _HistoryScreenState extends State<HistoryScreen> {
  late final FootGuardApiClient api =
      widget.apiClient ?? FootGuardApiClient(baseUrl: widget.backendUrl);
  late Future<List<RiskEventRecord>> events = api.events();
  _HistoryFilter filter = _HistoryFilter.all;

  @override
  void dispose() {
    api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<RiskEventRecord>>(
        future: events,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _Message(
                icon: Icons.cloud_off,
                text: '无法读取历史事件\n${snapshot.error}',
                onRetry: _reload);
          }
          final data = snapshot.data ?? const [];
          if (data.isEmpty) {
            return _Message(
                icon: Icons.event_available, text: '暂无风险事件', onRetry: _reload);
          }

          final filtered = data.where((event) {
            return switch (filter) {
              _HistoryFilter.all => true,
              _HistoryFilter.active => event.status == 'active',
              _HistoryFilter.finished => event.status != 'active',
            };
          }).toList(growable: false);
          final highRiskCount =
              data.where((event) => event.riskLevel >= 2).length;
          final improvedCount = data.where((event) {
            if (event.effectLabel != null) {
              return event.effectLabel == 'effective' ||
                  event.effectLabel == 'partial';
            }
            final ratio = event.loadDiffImprovementRatio;
            return ratio != null && ratio >= 0.2;
          }).length;

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '历史风险记录',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  '查看风险发生、提醒与负载改善结果。记录仅用于辅助监测，不替代医疗诊断。',
                  style: TextStyle(color: Color(0xFF607D7B), height: 1.4),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _SummaryTile(
                        label: '风险事件',
                        value: '${data.length} 条',
                        icon: Icons.event_note_rounded,
                        color: const Color(0xFF147D73),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTile(
                        label: '预警及以上',
                        value: '$highRiskCount 条',
                        icon: Icons.warning_amber_rounded,
                        color: const Color(0xFFE07A36),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTile(
                        label: '负载有改善',
                        value: '$improvedCount 条',
                        icon: Icons.trending_down_rounded,
                        color: const Color(0xFF1A9B78),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    _filterChip(_HistoryFilter.all, '全部'),
                    _filterChip(_HistoryFilter.active, '进行中'),
                    _filterChip(_HistoryFilter.finished, '已结束'),
                  ],
                ),
                const SizedBox(height: 8),
                if (filtered.isEmpty)
                  const _EmptyFilter()
                else
                  for (final event in filtered) ...[
                    _HistoryEventCard(event: event),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        },
      );

  Widget _filterChip(_HistoryFilter value, String label) {
    return FilterChip(
      label: Text(label),
      selected: filter == value,
      onSelected: (_) => setState(() => filter = value),
    );
  }

  Future<void> _reload() async {
    setState(() => events = api.events());
    await events;
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF71807F)),
            ),
          ],
        ),
      );
}

class _HistoryEventCard extends StatelessWidget {
  const _HistoryEventCard({required this.event});

  final RiskEventRecord event;

  @override
  Widget build(BuildContext context) {
    final severityColor = switch (event.riskLevel) {
      >= 3 => const Color(0xFFD54A4A),
      2 => const Color(0xFFE07A36),
      _ => const Color(0xFFC59A2E),
    };
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: severityColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(_riskIcon(event.riskType), color: severityColor),
        ),
        title: Text(
          _riskLabel(event.riskType),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${_sideLabel(event.riskSide)} · ${_formatDate(event.startedAtMs)}',
          ),
        ),
        trailing: _StatusPill(
          label: _statusLabel(event.status),
          active: event.status == 'active',
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _DetailValue(
                  label: '风险等级',
                  value: _levelLabel(event.riskLevel),
                ),
              ),
              Expanded(
                child: _DetailValue(
                  label: '持续时间',
                  value: _formatDuration(event.durationMs),
                ),
              ),
              Expanded(
                child: _DetailValue(
                  label: '结束时间',
                  value: event.endedAtMs == null
                      ? '监测中'
                      : _formatClock(event.endedAtMs!),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _RecoveryPanel(event: event),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '事件编号 ${event.eventId}',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF879291),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? const Color(0xFFD54A4A) : const Color(0xFF147D73);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DetailValue extends StatelessWidget {
  const _DetailValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF71807F)),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      );
}

class _RecoveryPanel extends StatelessWidget {
  const _RecoveryPanel({required this.event});

  final RiskEventRecord event;

  @override
  Widget build(BuildContext context) {
    if (!event.hasLoadDiffComparison) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F5F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          event.status == 'active'
              ? '事件仍在持续，结束后将评估提醒前后的负载变化。'
              : '本次事件没有完整的提醒前后对比数据。',
          style: const TextStyle(color: Color(0xFF60706F)),
        ),
      );
    }

    final before = event.beforeLoadDiff!;
    final after = event.afterLoadDiff!;
    final ratio = event.loadDiffImprovementRatio;
    final improved = ratio != null && ratio >= 0.2;
    final result = _recoveryResult(event.effectLabel, ratio);
    final recordedImprovement = event.effectLabel == 'effective' ||
        event.effectLabel == 'partial';
    final panelImproved =
        event.effectLabel == null ? improved : recordedImprovement;
    final color = panelImproved
        ? const Color(0xFF147D73)
        : const Color(0xFFE07A36);
    final changeDescription = ratio == null
        ? ''
        : ratio >= 0
            ? '（改善 ${(ratio * 100).round()}%）'
            : '（增加 ${(-ratio * 100).round()}%）';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                panelImproved
                    ? Icons.check_circle_outline_rounded
                    : Icons.info_outline_rounded,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 7),
              Text(
                '干预后评估：$result',
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '左右负载差 ${_formatPercent(before)} → '
            '${_formatPercent(after)}'
            '$changeDescription',
          ),
          if (event.recoveryTimeMs != null) ...[
            const SizedBox(height: 5),
            Text('恢复用时 ${_formatDuration(event.recoveryTimeMs!)}'),
          ],
          if (event.interventionAction != null) ...[
            const SizedBox(height: 5),
            Text(
              '干预记录：${_actionLabel(event.interventionAction!)}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF71807F)),
            ),
          ],
          if (event.riskType == 'temperature_asymmetry') ...[
            const SizedBox(height: 5),
            const Text(
              '温差风险中，该数值仅作为姿势与负载恢复的辅助参考。',
              style: TextStyle(fontSize: 12, color: Color(0xFF71807F)),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter();

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          '这个筛选条件下暂无事件',
          style: TextStyle(color: Color(0xFF71807F)),
        ),
      );
}

String _riskLabel(String riskType) => switch (riskType) {
      'left_load_bias' => '左脚负载持续偏高',
      'right_load_bias' => '右脚负载持续偏高',
      'forefoot_high' => '前掌持续高载',
      'temperature_asymmetry' => '同区温差异常',
      _ => riskType,
    };

IconData _riskIcon(String riskType) => switch (riskType) {
      'temperature_asymmetry' => Icons.device_thermostat_rounded,
      'forefoot_high' => Icons.directions_walk_rounded,
      _ => Icons.balance_rounded,
    };

String _recoveryResult(String? effectLabel, double? ratio) {
  if (effectLabel != null) {
    return switch (effectLabel) {
      'effective' => '明显改善',
      'partial' => '部分改善',
      'ineffective' => '未见明显改善',
      _ => '证据不足',
    };
  }
  if (ratio != null && ratio >= 0.5) {
    return '明显改善';
  }
  if (ratio != null && ratio >= 0.2) {
    return '部分改善';
  }
  return '未见明显改善';
}

String _actionLabel(String action) => switch (action) {
      'motor_vibration' => '马达提醒后调整姿势',
      'followed_vibration' => '按震动提醒调整',
      _ => action,
    };

String _sideLabel(String side) => switch (side) {
      'left' => '左脚',
      'right' => '右脚',
      'both' => '双脚',
      _ => '未指定侧',
    };

String _levelLabel(int level) => switch (level) {
      >= 3 => '3级 · 持续风险',
      2 => '2级 · 预警',
      1 => '1级 · 关注',
      _ => '0级 · 正常',
    };

String _statusLabel(String status) => switch (status) {
      'active' => '进行中',
      'resolved' => '已恢复',
      'interrupted' => '数据中断',
      _ => status,
    };

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _formatDate(int timestampMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
  return '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)} '
      '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
}

String _formatClock(int timestampMs) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();
  return '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';
}

String _formatDuration(int durationMs) {
  final seconds = durationMs / 1000;
  if (seconds < 60) {
    return '${seconds.toStringAsFixed(1)} 秒';
  }
  final minutes = seconds ~/ 60;
  final remainingSeconds = (seconds % 60).round();
  return '$minutes分$remainingSeconds秒';
}

String _formatPercent(double value) => '${(value * 100).toStringAsFixed(1)}%';

class _Message extends StatelessWidget {
  const _Message(
      {required this.icon, required this.text, required this.onRetry});
  final IconData icon;
  final String text;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 52, color: const Color(0xFF78909C)),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重新加载')),
        ]),
      );
}
