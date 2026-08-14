import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/api_client.dart';
import '../data/backend_foot_data_source.dart';
import '../data/ble_foot_data_source.dart';
import '../data/csv_replay_data_source.dart';
import '../data/foot_data_source.dart';
import '../data/mock_foot_data_source.dart';
import '../services/ble_connection_service.dart';
import '../services/ble_command_bridge.dart';
import '../services/monitoring_controller.dart';
import '../services/risk_notification_service.dart';
import '../widgets/ai_advice_card.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/foot_pressure_view.dart';
import '../widgets/risk_banner.dart';

class RealtimeScreen extends StatefulWidget {
  const RealtimeScreen({
    super.key,
    required this.settings,
    required this.connectionService,
  });
  final AppSettings settings;
  final BleConnectionService connectionService;

  @override
  State<RealtimeScreen> createState() => _RealtimeScreenState();
}

class _RealtimeScreenState extends State<RealtimeScreen>
    with WidgetsBindingObserver {
  late final MonitoringController controller;
  final RiskNotificationService _notifications = RiskNotificationService();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _handledNoticeSequence = 0;

  FootDataSource _source(FootGuardApiClient api) =>
      switch (widget.settings.dataMode) {
        FootDataMode.mock =>
          MockFootDataSource(scenario: widget.settings.mockScenario),
        FootDataMode.csvReplay => CsvReplayDataSource(
            assetPath: widget.settings.csvAsset,
            speed: widget.settings.replaySpeed),
        FootDataMode.backend => BackendFootDataSource(api),
        FootDataMode.ble => BleFootDataSource(widget.connectionService),
      };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notifications.initialize();
    final api = FootGuardApiClient(baseUrl: widget.settings.backendUrl);
    final commandBridge = widget.settings.dataMode == FootDataMode.ble
        ? BleCommandBridge(api: api, gateway: widget.connectionService)
        : null;
    controller = MonitoringController(
      source: _source(api),
      api: api,
      commandBridge: commandBridge,
    );
    controller.addListener(_handleNotice);
    controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  void _handleNotice() {
    if (controller.noticeSequence == _handledNoticeSequence ||
        controller.riskNoticeMessage == null) {
      return;
    }
    _handledNoticeSequence = controller.noticeSequence;
    final message = controller.riskNoticeMessage!;
    if (_lifecycleState != AppLifecycleState.resumed) {
      _notifications.show(title: 'FootGuard 风险与干预提醒', body: message);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.health_and_safety_outlined),
          title: const Text('风险与干预提醒'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_handleNotice);
    controller.dispose();
    super.dispose();
  }

  bool _riskAppliesToSide(String side) {
    return controller.activeRisks.any(
      (risk) => risk.riskSide == side || risk.riskSide == 'both',
    );
  }

  bool _showTemperatureAbnormality(String side) {
    return _riskAppliesToSide(side) &&
        controller.activeRisks.any(
          (risk) =>
              risk.riskType == 'temperature_asymmetry' &&
              (risk.riskSide == side || risk.riskSide == 'both'),
        );
  }

  bool _showPressureAbnormality(String side) {
    return _riskAppliesToSide(side) &&
        controller.activeRisks.any(
          (risk) =>
              const {
                'left_load_bias',
                'right_load_bias',
                'forefoot_high',
              }.contains(risk.riskType) &&
              (risk.riskSide == side || risk.riskSide == 'both'),
        );
  }

  Future<void> _restartCalibration() async {
    try {
      await controller.restartWearingCalibration();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已开始本次穿戴标定，请双脚平行自然站稳约 8–12 秒'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标定启动失败，请确认后端已连接')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => RefreshIndicator(
        onRefresh: controller.refreshBackend,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                ConnectionStatusCard(
                    label: '左脚设备', status: controller.connections.left),
                const SizedBox(width: 10),
                ConnectionStatusCard(
                    label: '右脚设备', status: controller.connections.right),
              ],
            ),
            const SizedBox(height: 12),
            RiskBanner(
              risk: controller.risk,
              activeRisks: controller.activeRisks,
              baselineReady: controller.calibrationStatus?.baselineReady ??
                  controller.regionalAnalysis?.baselineReady ??
                  false,
              pressureAvailable:
                  controller.regionalAnalysis?.pressureAvailable ??
                      (controller.left?.pressureChannelsValid == true &&
                          controller.right?.pressureChannelsValid == true),
            ),
            if (controller.recoveryObservation != null) ...[
              const SizedBox(height: 10),
              _RecoveryObservationCard(
                observation: controller.recoveryObservation!,
                backendOnline: controller.backendOnline,
              ),
            ],
            const SizedBox(height: 10),
            _WearingCalibrationCard(
              status: controller.calibrationStatus,
              backendOnline: controller.backendOnline,
              resetting: controller.calibrationResetting,
              onRestart: _restartCalibration,
            ),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(controller.errorMessage!,
                  style: const TextStyle(color: Color(0xFFB54A42))),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 680;
              final analysis = controller.regionalAnalysis;
              final feet = [
                Expanded(
                  child: FootPressureView(
                    side: 'left',
                    showPressureAbnormality: _showPressureAbnormality('left'),
                    showTemperatureAbnormality:
                        _showTemperatureAbnormality('left'),
                    frame: controller.left,
                    oppositeFrame: controller.right,
                    pressureScores: analysis?.leftPressureScores,
                    pressureValid: analysis?.leftPressureValid,
                    oppositePressureValid: analysis?.rightPressureValid,
                    pressureAnalysisValid: analysis?.leftPressureAnalysisValid,
                    pressureChannelStatus: analysis?.leftPressureChannelStatus,
                    temperatureScores: analysis?.leftTemperatureScores,
                    temperatureDeltaC: analysis?.temperatureDeltaC,
                    baselineReady: analysis?.baselineReady ?? false,
                    baselineSampleCount: analysis?.baselineSampleCount ?? 0,
                    baselineRequiredSamples:
                        analysis?.baselineRequiredSamples ?? 40,
                  ),
                ),
                const SizedBox(width: 12, height: 12),
                Expanded(
                  child: FootPressureView(
                    side: 'right',
                    showPressureAbnormality: _showPressureAbnormality('right'),
                    showTemperatureAbnormality:
                        _showTemperatureAbnormality('right'),
                    frame: controller.right,
                    oppositeFrame: controller.left,
                    pressureScores: analysis?.rightPressureScores,
                    pressureValid: analysis?.rightPressureValid,
                    oppositePressureValid: analysis?.leftPressureValid,
                    pressureAnalysisValid: analysis?.rightPressureAnalysisValid,
                    pressureChannelStatus: analysis?.rightPressureChannelStatus,
                    temperatureScores: analysis?.rightTemperatureScores,
                    temperatureDeltaC: analysis?.temperatureDeltaC,
                    baselineReady: analysis?.baselineReady ?? false,
                    baselineSampleCount: analysis?.baselineSampleCount ?? 0,
                    baselineRequiredSamples:
                        analysis?.baselineRequiredSamples ?? 40,
                  ),
                ),
              ];
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: feet)
                  : Column(
                      children: [
                        FootPressureView(
                          side: 'left',
                          showPressureAbnormality:
                              _showPressureAbnormality('left'),
                          showTemperatureAbnormality:
                              _showTemperatureAbnormality('left'),
                          frame: controller.left,
                          oppositeFrame: controller.right,
                          pressureScores: analysis?.leftPressureScores,
                          pressureValid: analysis?.leftPressureValid,
                          oppositePressureValid: analysis?.rightPressureValid,
                          pressureAnalysisValid:
                              analysis?.leftPressureAnalysisValid,
                          pressureChannelStatus:
                              analysis?.leftPressureChannelStatus,
                          temperatureScores: analysis?.leftTemperatureScores,
                          temperatureDeltaC: analysis?.temperatureDeltaC,
                          baselineReady: analysis?.baselineReady ?? false,
                          baselineSampleCount:
                              analysis?.baselineSampleCount ?? 0,
                          baselineRequiredSamples:
                              analysis?.baselineRequiredSamples ?? 40,
                        ),
                        const SizedBox(height: 12),
                        FootPressureView(
                          side: 'right',
                          showPressureAbnormality:
                              _showPressureAbnormality('right'),
                          showTemperatureAbnormality:
                              _showTemperatureAbnormality('right'),
                          frame: controller.right,
                          oppositeFrame: controller.left,
                          pressureScores: analysis?.rightPressureScores,
                          pressureValid: analysis?.rightPressureValid,
                          oppositePressureValid: analysis?.leftPressureValid,
                          pressureAnalysisValid:
                              analysis?.rightPressureAnalysisValid,
                          pressureChannelStatus:
                              analysis?.rightPressureChannelStatus,
                          temperatureScores: analysis?.rightTemperatureScores,
                          temperatureDeltaC: analysis?.temperatureDeltaC,
                          baselineReady: analysis?.baselineReady ?? false,
                          baselineSampleCount:
                              analysis?.baselineSampleCount ?? 0,
                          baselineRequiredSamples:
                              analysis?.baselineRequiredSamples ?? 40,
                        ),
                      ],
                    );
            }),
            const SizedBox(height: 12),
            _MetricsCard(controller: controller),
            const SizedBox(height: 12),
            AiAdviceCard(
              advice: controller.aiAdvice,
              status: controller.aiAdviceStatus,
              loading: controller.aiAdviceLoading,
              questionAnswer: controller.aiQuestionAnswer,
              questionStatus: controller.aiQuestionStatus,
              questionLoading: controller.aiQuestionLoading,
              onQuestionSelected: controller.askAiQuestion,
              chatAnswer: controller.aiChatAnswer,
              chatLoading: controller.aiChatLoading,
              chatStatus: controller.aiChatStatus,
              onChatSubmitted: controller.askAiChat,
            ),
            const SizedBox(height: 12),
            _SessionAdviceCard(controller: controller),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              child: ListTile(
                leading:
                    const CircleAvatar(child: Icon(Icons.vibration_rounded)),
                title: const Text('马达提醒状态',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(controller.motorStatus),
                trailing: controller.motorCommand == null ||
                        controller.usesRealBleCommands
                    ? null
                    : FilledButton(
                        onPressed: controller.executeMotorCommand,
                        child: const Text('模拟执行')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecoveryObservationCard extends StatelessWidget {
  const _RecoveryObservationCard({
    required this.observation,
    required this.backendOnline,
  });

  final RecoveryObservation observation;
  final bool backendOnline;

  @override
  Widget build(BuildContext context) {
    final observing = observation.status == 'observing';
    final seconds = (observation.remainingMs / 1000).ceil();
    final progress =
        observing ? (1 - observation.remainingMs / 15000).clamp(0.0, 1.0) : 1.0;
    final result = switch (observation.effectLabel) {
      'effective' => '有效',
      'partial' => '部分有效',
      'ineffective' => '未恢复',
      _ => '数据不足',
    };
    return Card(
      elevation: 0,
      color: observing ? const Color(0xFFFFF7E8) : const Color(0xFFEAF7F3),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(observing
                    ? Icons.timer_outlined
                    : Icons.fact_check_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    observing
                        ? (!backendOnline &&
                                !observation.eventId.startsWith('local_evt_')
                            ? '后端断开，干预倒计时已暂停'
                            : '干预效果观察中 $seconds 秒')
                        : '干预观察结果：$result',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
          ],
        ),
      ),
    );
  }
}

class _SessionAdviceCard extends StatelessWidget {
  const _SessionAdviceCard({required this.controller});

  final MonitoringController controller;

  @override
  Widget build(BuildContext context) {
    final advice = controller.sessionAdvice;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.summarize_outlined),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '当前 / 最近会话综合建议',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  tooltip: '刷新会话建议',
                  onPressed: controller.sessionAdviceLoading
                      ? null
                      : controller.refreshSessionAdvice,
                  icon: controller.sessionAdviceLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            if (advice == null)
              Text(controller.backendOnline
                  ? '正在汇总本次穿戴与最近风险记录'
                  : '后端离线，保留上次会话建议；本地风险闭环继续运行')
            else ...[
              Text(
                advice.isHistorical ? '当前无实时数据 · 最近会话' : '当前会话',
                style: const TextStyle(
                  color: Color(0xFF087F72),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(advice.advice),
              const SizedBox(height: 6),
              Text(
                advice.provider,
                style: const TextStyle(color: Color(0xFF718096), fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WearingCalibrationCard extends StatelessWidget {
  const _WearingCalibrationCard({
    required this.status,
    required this.backendOnline,
    required this.resetting,
    required this.onRestart,
  });

  final CalibrationStatus? status;
  final bool backendOnline;
  final bool resetting;
  final Future<void> Function() onRestart;

  String get _reason => switch (status?.statusReason) {
        'ready' => '本次穿戴基线已锁定，压力风险与马达已启用',
        'pressure_unavailable' => '压力通道不完整，请检查鞋垫与接线',
        'not_loaded' => '请穿好双脚并自然承重',
        'left_not_loaded' => '左脚未形成有效多点承重，请调整左脚位置',
        'right_not_loaded' => '右脚未形成有效多点承重，请调整右脚位置',
        'pressure_residual' => '当前主要是固定残余压力，请双脚穿好并完整踩住鞋垫',
        'moving' => '身体移动较大，请保持自然站立',
        'unstable' => '数据波动较大，请放松并保持站稳',
        _ => '等待双脚有效压力数据',
      };

  @override
  Widget build(BuildContext context) {
    final ready = status?.baselineReady ?? false;
    final progress = status?.progress ?? 0.0;
    final count = status?.sampleCount ?? 0;
    final required = status?.requiredSamples ?? 40;
    final color = ready ? const Color(0xFF168A70) : const Color(0xFF39758C);
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              spacing: 12,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ready ? Icons.verified_rounded : Icons.tune_rounded,
                      color: color,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      ready ? '本次穿戴已就绪' : '本次穿戴标定 $count/$required',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: !backendOnline || resetting ? null : onRestart,
                  icon: resetting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('新体验者 / 重新穿戴'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: ready ? 1 : progress,
              minHeight: 7,
              borderRadius: BorderRadius.circular(4),
              color: color,
            ),
            const SizedBox(height: 7),
            Text(
              _reason,
              style: const TextStyle(color: Color(0xFF63757B), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({required this.controller});
  final MonitoringController controller;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 28,
            runSpacing: 12,
            children: [
              _Metric(
                  label: '载荷偏向',
                  value: controller.loadBias?.toStringAsFixed(3) ?? '--'),
              _Metric(
                  label: '左右差值',
                  value: controller.loadDiff?.toStringAsFixed(3) ?? '--'),
              _Metric(
                  label: '同步误差',
                  value: controller.syncErrorMs == null
                      ? '--'
                      : '${controller.syncErrorMs} ms'),
              _Metric(label: '活动状态', value: controller.motionStatusLabel),
              _Metric(
                  label: '左脚运动',
                  value: controller.footMotionStatusLabel('left')),
              _Metric(
                  label: '右脚运动',
                  value: controller.footMotionStatusLabel('right')),
              _Metric(
                  label: '后端', value: controller.backendOnline ? '在线' : '离线'),
              _Metric(label: '数据源', value: controller.source.label),
            ],
          ),
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 105,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF718096), fontSize: 12)),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );
}
