import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/offline_intervention.dart';
import '../models/gait_summary.dart';
import '../models/ai_question_answer.dart';
import '../models/session_advice.dart';
import '../services/offline_monitoring_store.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.backendUrl, this.apiClient});

  final String backendUrl;
  final FootGuardApiClient? apiClient;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

enum _HistoryFilter { all, active, finished }

enum _HistoryView { risks, gait }

class _HistoryPayload {
  const _HistoryPayload({
    required this.events,
    required this.advice,
    required this.summary,
    this.cached = false,
  });
  final List<RiskEventRecord> events;
  final SessionAdvice? advice;
  final SessionSummary? summary;
  final bool cached;
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final FootGuardApiClient api =
      widget.apiClient ?? FootGuardApiClient(baseUrl: widget.backendUrl);
  final OfflineMonitoringStore _store = OfflineMonitoringStore();
  late Future<_HistoryPayload> payload;
  _HistoryFilter filter = _HistoryFilter.all;
  _HistoryView view = _HistoryView.risks;
  AiQuestionAnswer? sessionQuestionAnswer;
  bool sessionQuestionLoading = false;
  String sessionQuestionStatus = '请选择一个会话问题';

  @override
  void initState() {
    super.initState();
    payload = _loadInitial();
  }

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
              onRetry: _reload,
            );
          }
          final result = snapshot.data ??
              const _HistoryPayload(events: [], advice: null, summary: null);
          final data = result.events;

          final filtered = data.where((event) {
            return switch (filter) {
              _HistoryFilter.all => true,
              _HistoryFilter.active => event.status == 'active',
              _HistoryFilter.finished => event.status != 'active',
            };
          }).toList(growable: false);
          final improvedCount = data.where(_pressureEventImproved).length;

          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '历史事件与会话建议',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  '汇总站立风险、干预前后变化和完整行走评估。',
                  style: TextStyle(color: Color(0xFF607D7B), height: 1.4),
                ),
                const SizedBox(height: 16),
                _SessionAdvicePanel(
                  advice: result.advice,
                  cached: result.cached,
                  onRefresh: _reload,
                  questionAnswer: sessionQuestionAnswer,
                  questionLoading: sessionQuestionLoading,
                  questionStatus: sessionQuestionStatus,
                  onQuestionSelected: _askSessionQuestion,
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _SummaryTile(
                        label: '风险事件',
                        value: '${result.summary?.eventCount ?? data.length} 条',
                        icon: Icons.event_note_rounded,
                        color: const Color(0xFF147D73),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTile(
                        label: '已执行干预',
                        value:
                            '${result.summary?.motorExecutedCount ?? data.where((event) => event.interventionStartedAtMs != null).length} 次',
                        icon: Icons.warning_amber_rounded,
                        color: const Color(0xFFE07A36),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTile(
                        label: '压力有改善',
                        value: '$improvedCount 条',
                        icon: Icons.trending_down_rounded,
                        color: const Color(0xFF1A9B78),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SegmentedButton<_HistoryView>(
                  segments: const [
                    ButtonSegment(
                      value: _HistoryView.risks,
                      icon: Icon(Icons.warning_amber_rounded),
                      label: Text('风险事件'),
                    ),
                    ButtonSegment(
                      value: _HistoryView.gait,
                      icon: Icon(Icons.directions_walk_rounded),
                      label: Text('步态记录'),
                    ),
                  ],
                  selected: {view},
                  onSelectionChanged: (value) =>
                      setState(() => view = value.first),
                ),
                const SizedBox(height: 12),
                if (view == _HistoryView.risks) ...[
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
                ] else if (result.summary?.latestGaitEpisodes.isEmpty ?? true)
                  const _Message(
                    icon: Icons.directions_walk_rounded,
                    text: '暂无完整行走记录',
                  )
                else ...[
                  _GaitTrendPanel(trend: result.summary!.gaitTrend),
                  const SizedBox(height: 10),
                  for (final episode in result.summary!.latestGaitEpisodes) ...[
                    _GaitEpisodeCard(episode: episode),
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
    SessionAdvice? advice;
    SessionSummary? summary;
    var cached = false;
    try {
      events = await api.events();
      await _store.saveHistoryEvents(
        events.map((item) => item.toJson()).toList(growable: false),
      );
    } catch (_) {
      events = (await _store.loadHistoryEvents())
          .map(RiskEventRecord.fromJson)
          .toList(growable: false);
      cached = events.isNotEmpty;
    }
    final offlineEvents = _eventsFromOfflineInterventions(
      await _store.loadInterventions(),
    );
    final knownIds = events.map((item) => item.eventId).toSet();
    events = [
      ...offlineEvents.where((item) => !knownIds.contains(item.eventId)),
      ...events,
    ]..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    try {
      summary = await api.latestSession();
      await _store.saveSessionSummary(summary.toJson());
    } catch (_) {
      final raw = await _store.loadSessionSummary();
      summary = raw == null ? null : SessionSummary.fromJson(raw);
      cached = cached || summary != null;
    }
    try {
      advice = await api.sessionAdvice();
      await _store.saveSessionAdvice(advice.toJson());
    } catch (_) {
      final raw = await _store.loadSessionAdvice();
      advice = raw == null ? null : SessionAdvice.fromJson(raw);
      advice ??= _localSessionAdvice(events);
      cached = cached || advice != null;
    }
    return _HistoryPayload(
      events: events,
      advice: advice,
      summary: summary,
      cached: cached,
    );
  }

  Future<_HistoryPayload> _loadInitial() async {
    final cached = await _loadCached();
    if (cached.events.isNotEmpty ||
        cached.advice != null ||
        cached.summary != null) {
      unawaited(_refreshAfterCache());
      return cached;
    }
    return _load();
  }

  Future<_HistoryPayload> _loadCached() async {
    final rawEvents = await _store.loadHistoryEvents();
    final events = rawEvents.map(RiskEventRecord.fromJson).toList();
    final knownIds = events.map((item) => item.eventId).toSet();
    events.addAll(
      _eventsFromOfflineInterventions(await _store.loadInterventions())
          .where((item) => !knownIds.contains(item.eventId)),
    );
    events.sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
    final rawAdvice = await _store.loadSessionAdvice();
    final rawSummary = await _store.loadSessionSummary();
    return _HistoryPayload(
      events: events,
      advice: rawAdvice == null
          ? _localSessionAdvice(events)
          : SessionAdvice.fromJson(rawAdvice),
      summary: rawSummary == null ? null : SessionSummary.fromJson(rawSummary),
      cached: true,
    );
  }

  Future<void> _refreshAfterCache() async {
    final refreshed = await _load();
    if (!mounted) return;
    setState(() {
      payload = Future.value(refreshed);
    });
  }

  SessionAdvice? _localSessionAdvice(List<RiskEventRecord> events) {
    if (events.isEmpty) return null;
    final pressureEvents = events.where(
      (event) => event.riskType != 'temperature_asymmetry',
    );
    final recovered = events.where(_pressureEventImproved);
    return SessionAdvice(
      provider: 'local-session-template',
      sessionStatus: 'recent',
      advice: '当前无实时后端数据，以下为最近会话辅助建议：'
          '本地记录 ${pressureEvents.length} 次压力减负事件，'
          '其中 ${recovered.length} 次在观察期内有改善。'
          '建议优先核对反复出现的一侧和前掌区域，并结合皮肤外观、鞋内异物与鞋垫贴合情况观察。'
          '本建议仅用于辅助监测，不替代医疗诊断。',
    );
  }

  Future<void> _reload() async {
    setState(() => payload = _load());
    await payload;
  }

  Future<void> _askSessionQuestion(String questionKey) async {
    setState(() {
      sessionQuestionLoading = true;
      sessionQuestionAnswer = null;
      sessionQuestionStatus = '正在结合最近会话生成回答…';
    });
    try {
      final answer = await api.sessionQuestion(questionKey);
      if (!mounted) return;
      setState(() {
        sessionQuestionAnswer = answer;
        sessionQuestionStatus = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        sessionQuestionStatus = '会话追问暂时不可用：$error';
      });
    } finally {
      if (mounted) setState(() => sessionQuestionLoading = false);
    }
  }
}

class _SessionAdvicePanel extends StatelessWidget {
  const _SessionAdvicePanel({
    required this.advice,
    required this.cached,
    required this.onRefresh,
    required this.questionAnswer,
    required this.questionLoading,
    required this.questionStatus,
    required this.onQuestionSelected,
  });

  final SessionAdvice? advice;
  final bool cached;
  final Future<void> Function() onRefresh;
  final AiQuestionAnswer? questionAnswer;
  final bool questionLoading;
  final String questionStatus;
  final Future<void> Function(String questionKey) onQuestionSelected;

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
                  const Icon(Icons.auto_awesome_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '最近会话 AI 建议',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新会话建议',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              if (advice == null)
                const Text('暂无可用的最近会话建议。')
              else ...[
                Text(
                  cached || advice!.isHistorical
                      ? '当前无实时数据；以下是最近会话，不是当前风险。'
                      : '当前会话综合建议',
                  style: const TextStyle(
                    color: Color(0xFF087F72),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(advice!.advice),
                const SizedBox(height: 6),
                Text(
                  advice!.provider,
                  style:
                      const TextStyle(color: Color(0xFF718096), fontSize: 11),
                ),
              ],
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 12),
              const Text(
                '常见会话问题',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 9),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final question in _sessionQuestions) ...[
                      ActionChip(
                        avatar: Icon(question.icon, size: 17),
                        label: Text(question.label),
                        onPressed: questionLoading
                            ? null
                            : () => onQuestionSelected(question.key),
                      ),
                      const SizedBox(width: 7),
                    ],
                  ],
                ),
              ),
              if (questionLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('正在生成回答…'),
                    ],
                  ),
                )
              else if (questionAnswer != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF7F5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        questionAnswer!.question,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 5),
                      Text(questionAnswer!.answer),
                    ],
                  ),
                )
              else if (questionStatus != '请选择一个会话问题')
                Text(
                  questionStatus,
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

class _SessionQuestionOption {
  const _SessionQuestionOption(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

const _sessionQuestions = [
  _SessionQuestionOption(
    'session_priority',
    '最应关注什么？',
    Icons.priority_high_rounded,
  ),
  _SessionQuestionOption(
    'session_pressure_area',
    '复查哪个区域？',
    Icons.location_searching_rounded,
  ),
  _SessionQuestionOption(
    'session_improvement',
    '改善是否稳定？',
    Icons.trending_down_rounded,
  ),
  _SessionQuestionOption(
    'session_next_test',
    '下一轮怎么测？',
    Icons.directions_walk_rounded,
  ),
  _SessionQuestionOption(
    'session_data_quality',
    '数据可靠吗？',
    Icons.sensors_rounded,
  ),
];

List<RiskEventRecord> _eventsFromOfflineInterventions(
  List<OfflineIntervention> records,
) =>
    records.map((item) {
      final executedAcks = item.acknowledgements
          .where((ack) => ack.status == 'executed')
          .toList(growable: false);
      final interventionAt =
          executedAcks.map((ack) => ack.executedAtMs ?? ack.ackAtMs).fold<int?>(
                null,
                (earliest, value) =>
                    earliest == null || value < earliest ? value : earliest,
              );
      return RiskEventRecord(
        eventId: item.eventId,
        riskType: item.risk.riskType,
        riskSide: item.risk.riskSide,
        riskLevel: item.risk.riskLevel,
        startedAtMs: item.startedAtMs,
        durationMs: item.risk.durationMs,
        status: item.effectLabel == null ? 'active' : 'resolved',
        beforeLoadDiff: item.beforeLoadDiff,
        afterLoadDiff: item.afterLoadDiff,
        interventionAction: executedAcks.isEmpty ? null : 'motor_vibration',
        effectLabel: item.effectLabel,
        recoveryTimeMs: item.recoveryTimeMs,
        activeRisks: item.activeRisks,
        interventionStartedAtMs: interventionAt,
        motorTarget: item.command.target,
        motorPattern: item.command.pattern,
      );
    }).toList(growable: false);

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
                '本次事件期间出现',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            ...event.activeRisks.map(
              (risk) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      _riskIcon(risk.riskType),
                      size: 17,
                      color: severityColor,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${_riskLabel(risk.riskType)} · ${_sideLabel(risk.riskSide)}',
                      ),
                    ),
                    Text(
                      '${_levelLabel(risk.riskLevel)} · ${_formatDuration(risk.durationMs)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF60706F),
                      ),
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
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F5F5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                Text(
                  event.interventionStartedAtMs == null
                      ? '马达：未执行'
                      : '马达：已执行一次${event.motorTarget == null ? '' : '（${_sideLabel(event.motorTarget!)}）'}',
                ),
                if (event.interventionStartedAtMs != null)
                  Text('干预时间：${_formatClock(event.interventionStartedAtMs!)}'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _RecoveryPanel(event: event),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '事件编号 ${event.eventId}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF879291)),
            ),
          ),
        ],
      ),
    );
  }
}

class _GaitTrendPanel extends StatelessWidget {
  const _GaitTrendPanel({required this.trend});

  final GaitTrendSummary trend;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF7F3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '行走趋势证据 ${trend.evidenceEpisodeCount}/3 段 · ${trend.evidenceStepCount} 次落脚',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            if (trend.confirmedIssues.isEmpty)
              Text(
                trend.evidenceEpisodeCount < 3
                    ? '重复趋势证据仍在收集中；单段达到主问题阈值时仍会实时提醒。'
                    : '最近三段未形成同一方向的偏载或前掌反复受压趋势。',
                style: const TextStyle(color: Color(0xFF147D73)),
              )
            else
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: trend.confirmedIssues
                    .map(
                      (issue) => Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(_gaitIssueLabel(issue)),
                      ),
                    )
                    .toList(growable: false),
              ),
          ],
        ),
      );
}

class _GaitEpisodeCard extends StatelessWidget {
  const _GaitEpisodeCard({required this.episode});

  final GaitEpisodeSummary episode;

  @override
  Widget build(BuildContext context) {
    final alertIssues = episode.issues
        .where(
          (issue) => const {
            'walking_load_asymmetry',
            'walking_forefoot_concentration',
          }.contains(issue.issueType),
        )
        .toList(growable: false);
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_walk_rounded),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _formatDate(episode.startedAtMs),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                _StatusPill(
                  label: alertIssues.isEmpty ? '本段正常' : '本段提醒',
                  active: alertIssues.isNotEmpty,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 20,
              runSpacing: 10,
              children: [
                _DetailValue(label: '落脚', value: '${episode.stepCount} 次'),
                _DetailValue(
                  label: '左右落脚',
                  value: '${episode.leftSteps} / ${episode.rightSteps}',
                ),
                _DetailValue(
                  label: '估算步频',
                  value: '${episode.cadenceSpm.toStringAsFixed(0)} 步/分钟',
                ),
                _DetailValue(
                  label: '负荷不对称',
                  value: _formatPercent(episode.loadAsymmetry),
                ),
                _DetailValue(
                  label: '步时变异',
                  value: _formatPercent(episode.stepIntervalCv),
                ),
              ],
            ),
            if (alertIssues.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: alertIssues
                    .map(
                      (issue) => Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(_gaitIssueLabel(issue)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ],
        ),
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
          color: const Color(0xFFF2F5F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '提醒后的压力重新分配观察',
              style: TextStyle(
                color: Color(0xFF147D73),
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            for (final item in feedback)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_riskLabel(item.riskType)} · ${_sideLabel(item.riskSide)}',
                          ),
                        ),
                        Text(
                          _componentEffectLabel(item.effectLabel),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.beforeValue != null && item.afterValue != null
                          ? '${_componentMetricLabel(item)} '
                              '${_formatComponentValue(item, item.beforeValue!)} → '
                              '${_formatComponentValue(item, item.afterValue!)}'
                              '${_componentChangeLabel(item)}'
                          : '有效静止配对数据不足，未计算改善程度',
                      style: const TextStyle(
                        color: Color(0xFF60706F),
                        fontSize: 12,
                      ),
                    ),
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
      _ when event.interventionStartedAtMs == null =>
        '本次未执行马达提醒，因此不评价干预后的改善程度。',
      _ => '本次干预前后没有取得足够的有效静止配对数据，暂不计算改善程度。',
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
      'medial_load_concentration' => '内侧局部负荷集中',
      'lateral_load_concentration' => '外侧局部负荷集中',
      'temperature_asymmetry' => '同区温度趋势异常',
      _ => '区域负荷集中',
    };

String _gaitIssueLabel(GaitIssue issue) {
  final side = issue.side == 'left'
      ? '左脚'
      : issue.side == 'right'
          ? '右脚'
          : '';
  return switch (issue.issueType) {
    'walking_load_asymmetry' => '$side行走负荷偏高',
    'walking_forefoot_concentration' => '$side前掌反复受压',
    _ => '行走工程观察',
  };
}

IconData _riskIcon(String riskType) => switch (riskType) {
      'temperature_asymmetry' => Icons.device_thermostat_rounded,
      'forefoot_high' => Icons.directions_walk_rounded,
      'medial_load_concentration' ||
      'lateral_load_concentration' =>
        Icons.warning_amber_rounded,
      _ => Icons.balance_rounded,
    };

String _recoveryResult(double? ratio) {
  if (ratio != null && ratio < 0) {
    return '偏离增加';
  }
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

bool _pressureEventImproved(RiskEventRecord event) {
  final pressureFeedback = event.componentFeedback
      .where((item) => item.pressureIntervention)
      .toList(growable: false);
  if (pressureFeedback.isNotEmpty) {
    return pressureFeedback.any(
      (item) => const {'effective', 'partial'}.contains(item.effectLabel),
    );
  }
  return event.riskType != 'temperature_asymmetry' &&
      const {'effective', 'partial'}.contains(event.effectLabel);
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
      >= 3 => '持续未改善',
      2 => '需要减负',
      1 => '趋势观察',
      _ => '正常',
    };

String _componentEffectLabel(String value) => switch (value) {
      'effective' => '明显改善',
      'partial' => '部分改善',
      'ineffective' => '未改善',
      'worsened' => '偏离增加',
      _ => '数据不足',
    };

String _componentMetricLabel(RiskComponentFeedbackRecord item) =>
    switch (item.metricCode) {
      'load_asymmetry_excess' => '相对偏载程度',
      String code when code.contains('forefoot_excess') => '前掌超出个人基线',
      String code when code.contains('medial_excess') => '内侧超出个人基线',
      String code when code.contains('lateral_excess') => '外侧超出个人基线',
      _ => '异常偏离程度',
    };

String _formatComponentValue(
  RiskComponentFeedbackRecord item,
  double value,
) =>
    item.metricUnit == 'celsius'
        ? '${value.toStringAsFixed(1)}℃'
        : _formatPercent(value);

String _componentChangeLabel(RiskComponentFeedbackRecord item) {
  final ratio = item.improvementRatio;
  if (ratio == null) return '';
  final value = (ratio.abs() * 100).round();
  return ratio < 0 ? ' · 偏离增加 $value%' : ' · 改善 $value%';
}

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
  const _Message({
    required this.icon,
    required this.text,
    this.onRetry,
  });
  final IconData icon;
  final String text;
  final Future<void> Function()? onRetry;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: const Color(0xFF78909C)),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('重新加载')),
            ],
          ],
        ),
      );
}
