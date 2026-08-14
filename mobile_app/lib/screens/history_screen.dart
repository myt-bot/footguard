import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/session_advice.dart';
import '../services/offline_monitoring_store.dart';
import '../widgets/session_analysis_view.dart';

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

enum _HistoryView { analysis, events }

class _HistoryPayload {
  const _HistoryPayload({
    required this.events,
    required this.points,
    required this.advice,
    this.cached = false,
  });
  final List<RiskEventRecord> events;
  final List<AnalyticsFramePoint> points;
  final SessionAdvice? advice;
  final bool cached;
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final FootGuardApiClient api =
      widget.apiClient ?? FootGuardApiClient(baseUrl: widget.backendUrl);
  final OfflineMonitoringStore _store = OfflineMonitoringStore();
  late Future<_HistoryPayload> payload = _load();
  _HistoryFilter filter = _HistoryFilter.all;
  _HistoryView view = _HistoryView.analysis;

  @override
  void dispose() {
    api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_HistoryPayload>(
        future: payload,
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
          final result = snapshot.data ??
              const _HistoryPayload(events: [], points: [], advice: null);
          final data = result.events;

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
            if (!_isLoadBiasRisk(event.riskType)) {
              return false;
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
                  '会话分析与风险记录',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  '查看压力、温度、提醒与负载改善结果。记录仅用于辅助监测，不替代医疗诊断。',
                  style: TextStyle(color: Color(0xFF607D7B), height: 1.4),
                ),
                const SizedBox(height: 16),
                SegmentedButton<_HistoryView>(
                  segments: const [
                    ButtonSegment(
                        value: _HistoryView.analysis,
                        label: Text('会话分析'),
                        icon: Icon(Icons.insights_outlined)),
                    ButtonSegment(
                        value: _HistoryView.events,
                        label: Text('风险事件'),
                        icon: Icon(Icons.history_rounded)),
                  ],
                  selected: {view},
                  onSelectionChanged: (selected) =>
                      setState(() => view = selected.first),
                ),
                const SizedBox(height: 14),
                if (view == _HistoryView.analysis)
                  SessionAnalysisView(
                    points: result.points,
                    events: data,
                    advice: result.advice,
                    cached: result.cached,
                  )
                else ...[
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
                          label: '需要减负事件',
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

  Future<_HistoryPayload> _load() async {
    List<RiskEventRecord> events = const [];
    List<AnalyticsFramePoint> points = const [];
    SessionAdvice? advice;
    Object? primaryError;
    try {
      events = await api.events();
    } catch (error) {
      primaryError = error;
    }
    var cached = false;
    try {
      points = await api.analyticsTimeseries();
      await _store.saveAnalytics(
          points.map((item) => item.toJson()).toList(growable: false));
    } catch (_) {
      points = (await _store.loadAnalytics())
          .map(AnalyticsFramePoint.fromJson)
          .toList(growable: false);
      if (points.isEmpty) {
        final pairs = await _store.loadPairs();
        points = pairs
            .expand((pair) => pair)
            .map(AnalyticsFramePoint.fromFootFrame)
            .toList(growable: false);
      }
      cached = points.isNotEmpty;
    }
    try {
      advice = await api.sessionAdvice();
      await _store.saveSessionAdvice(advice.toJson());
    } catch (_) {
      final raw = await _store.loadSessionAdvice();
      advice = raw == null ? null : SessionAdvice.fromJson(raw);
      advice ??= _localSessionAdvice(events, points);
      cached = cached || advice != null;
    }
    if (primaryError != null && points.isEmpty && advice == null) {
      throw primaryError;
    }
    return _HistoryPayload(
        events: events, points: points, advice: advice, cached: cached);
  }

  SessionAdvice? _localSessionAdvice(
    List<RiskEventRecord> events,
    List<AnalyticsFramePoint> points,
  ) {
    if (events.isEmpty && points.isEmpty) return null;
    final pressureEvents = events.where(
      (event) => event.riskType != 'temperature_asymmetry',
    );
    final recovered = events.where(
      (event) => const {'effective', 'partial'}.contains(event.effectLabel),
    );
    final left = points.where((point) => point.side == 'left').toList();
    final right = points.where((point) => point.side == 'right').toList();
    double averageLoad(List<AnalyticsFramePoint> rows) => rows.isEmpty
        ? 0
        : rows.fold<double>(0, (sum, row) => sum + row.totalPressure) /
            rows.length;
    final leftLoad = averageLoad(left);
    final rightLoad = averageLoad(right);
    final loadNote = leftLoad <= 0 && rightLoad <= 0
        ? '本地缓存中没有足够的承重数据。'
        : '最近缓存的左右平均载荷比约为 '
            '${leftLoad.toStringAsFixed(2)}:${rightLoad.toStringAsFixed(2)}。';
    return SessionAdvice(
      provider: 'local-session-template',
      sessionStatus: 'recent',
      advice: '当前无实时后端数据，以下为最近会话辅助建议：'
          '$loadNote本地记录 ${pressureEvents.length} 次压力减负事件，'
          '其中 ${recovered.length} 次在观察期内有改善。'
          '建议优先核对反复出现的一侧和前掌区域，并结合皮肤外观、鞋内异物与鞋垫贴合情况观察。'
          '本建议仅用于辅助监测，不替代医疗诊断。',
    );
  }

  Future<void> _reload() async {
    setState(() => payload = _load());
    await payload;
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
          event.activeRisks.length > 1 ? '组合风险事件' : _riskLabel(event.riskType),
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
          if (event.activeRisks.length > 1) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '本次同时存在',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            ...event.activeRisks.map(
              (risk) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(_riskIcon(risk.riskType),
                        size: 17, color: severityColor),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${_riskLabel(risk.riskType)} · ${_sideLabel(risk.riskSide)}',
                      ),
                    ),
                    Text(
                      '${_levelLabel(risk.riskLevel)} · ${_formatDuration(risk.durationMs)}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF60706F)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: _DetailValue(
                  label: '事件状态',
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
    final color = active ? const Color(0xFFD54A4A) : const Color(0xFF147D73);
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
    final componentFeedback = event.componentFeedback
        .where((item) => item.pressureIntervention)
        .toList(growable: false);
    if (componentFeedback.isNotEmpty) {
      return _ComponentRecoveryPanel(feedback: componentFeedback);
    }
    if (!_isLoadBiasRisk(event.riskType)) {
      return _NonLoadBiasRecoveryPanel(event: event);
    }
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
    final result = _recoveryResult(ratio);
    final panelImproved = improved;
    final color =
        panelImproved ? const Color(0xFF147D73) : const Color(0xFFE07A36);
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
        ],
      ),
    );
  }
}

class _ComponentRecoveryPanel extends StatelessWidget {
  const _ComponentRecoveryPanel({required this.feedback});

  final List<RiskComponentFeedbackRecord> feedback;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF7F3),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('提醒后的压力重新分配观察',
                style: TextStyle(
                    color: Color(0xFF147D73), fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            for (final item in feedback)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(
                            '${_riskLabel(item.riskType)} · ${_sideLabel(item.riskSide)}')),
                    Text(_componentEffectLabel(item.effectLabel),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (item.improvementRatio != null) ...[
                      const SizedBox(width: 6),
                      Text('${(item.improvementRatio! * 100).round()}%'),
                    ],
                  ],
                ),
              ),
          ],
        ),
      );
}

class _NonLoadBiasRecoveryPanel extends StatelessWidget {
  const _NonLoadBiasRecoveryPanel({required this.event});

  final RiskEventRecord event;

  @override
  Widget build(BuildContext context) {
    final isActive = event.status == 'active';
    final description = switch (event.riskType) {
      'temperature_asymmetry' => '温差事件不能用左右负载差判定干预效果；本页仅记录事件是否解除和恢复用时。',
      'forefoot_high' => '当前版本尚未保存提醒前后的前掌区域变化量，因此不宣称干预后改善。',
      _ => '本次事件没有可用于评估干预效果的同类指标。',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F5F5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isActive ? '事件仍在持续' : '事件已解除',
            style: const TextStyle(
              color: Color(0xFF147D73),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(fontSize: 12, color: Color(0xFF60706F)),
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
      'left_load_bias' => '左侧负载持续偏高',
      'right_load_bias' => '右侧负载持续偏高',
      'forefoot_high' => '前掌负荷持续集中',
      'temperature_asymmetry' => '同区温度趋势异常',
      _ => riskType,
    };

IconData _riskIcon(String riskType) => switch (riskType) {
      'temperature_asymmetry' => Icons.device_thermostat_rounded,
      'forefoot_high' => Icons.directions_walk_rounded,
      _ => Icons.balance_rounded,
    };

String _recoveryResult(double? ratio) {
  if (ratio != null && ratio >= 0.5) {
    return '明显改善';
  }
  if (ratio != null && ratio >= 0.2) {
    return '部分改善';
  }
  return '未见明显改善';
}

bool _isLoadBiasRisk(String riskType) =>
    riskType == 'left_load_bias' || riskType == 'right_load_bias';

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
      >= 3 => '持续未改善',
      2 => '需要减负',
      1 => '趋势观察',
      _ => '正常',
    };

String _componentEffectLabel(String value) => switch (value) {
      'effective' => '明显改善',
      'partial' => '部分改善',
      'ineffective' => '未改善',
      _ => '数据不足',
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
