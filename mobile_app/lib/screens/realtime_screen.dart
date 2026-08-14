import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/api_client.dart';
import '../data/backend_foot_data_source.dart';
import '../data/ble_foot_data_source.dart';
import '../data/csv_replay_data_source.dart';
import '../data/foot_data_source.dart';
import '../data/mock_foot_data_source.dart';
import '../models/gait_summary.dart';
import '../services/ble_connection_service.dart';
import '../services/ble_command_bridge.dart';
import '../services/calibration_speech_coordinator.dart';
import '../services/monitoring_controller.dart';
import '../services/risk_notification_service.dart';
import '../services/local_tts_service.dart';
import '../widgets/connection_status_card.dart';
import '../widgets/foot_pressure_view.dart';
import '../widgets/risk_banner.dart';

class RealtimeScreen extends StatefulWidget {
  const RealtimeScreen({
    super.key,
    required this.settings,
    required this.connectionService,
    required this.ttsSpeaker,
    required this.calibrationSpeech,
  });
  final AppSettings settings;
  final BleConnectionService connectionService;
  final TtsSpeaker ttsSpeaker;
  final CalibrationSpeechCoordinator calibrationSpeech;

  @override
  State<RealtimeScreen> createState() => _RealtimeScreenState();
}

class _RealtimeScreenState extends State<RealtimeScreen>
    with WidgetsBindingObserver {
  late final MonitoringController controller;
  final RiskNotificationService _notifications = RiskNotificationService();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  int _handledNoticeSequence = 0;
  int _handledGaitNoticeSequence = 0;

  FootDataSource _source(FootGuardApiClient api) =>
      switch (widget.settings.dataMode) {
        FootDataMode.mock => MockFootDataSource(
            scenario: widget.settings.mockScenario,
          ),
        FootDataMode.csvReplay => CsvReplayDataSource(
            assetPath: widget.settings.csvAsset,
            speed: widget.settings.replaySpeed,
          ),
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
    controller.addListener(_handleControllerChanges);
    controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
  }

  void _handleControllerChanges() {
    _handleCalibrationSpeech();
    _handleNotice();
    _handleGaitNotice();
  }

  void _handleCalibrationSpeech() {
    if (!widget.settings.voiceEnabled || !controller.bothFeetConnected) return;
    final stage = controller.calibrationStage;
    if (!widget.calibrationSpeech.take(stage)) return;
    final message = switch (stage) {
      'empty_reference' => '请保持双脚离开鞋垫，开始空载温度采集。',
      'put_on' => '空载温度采集完成，现在可以穿鞋，并自然站立开始个人基线采集。',
      'complete' => '个人基线采集完成，本次穿戴已就绪。',
      _ => null,
    };
    if (message != null) unawaited(widget.ttsSpeaker.speak(message));
  }

  void _handleNotice() {
    if (widget.calibrationSpeech.active) return;
    if (controller.noticeSequence == _handledNoticeSequence ||
        controller.riskNoticeMessage == null) {
      return;
    }
    _handledNoticeSequence = controller.noticeSequence;
    final message = controller.riskNoticeMessage!;
    if (widget.settings.voiceEnabled) {
      unawaited(widget.ttsSpeaker.speak(message));
    }
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

  void _handleGaitNotice() {
    if (widget.calibrationSpeech.active ||
        controller.gaitNoticeSequence == _handledGaitNoticeSequence ||
        controller.gaitNoticeMessage == null) {
      return;
    }
    _handledGaitNoticeSequence = controller.gaitNoticeSequence;
    final message = controller.gaitNoticeMessage!;
    if (widget.settings.voiceEnabled) {
      unawaited(widget.ttsSpeaker.speak(message));
    }
    if (_lifecycleState != AppLifecycleState.resumed) {
      _notifications.show(title: 'FootGuard 行走评估', body: message);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_handleControllerChanges);
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
    final analysis = controller.regionalAnalysis;
    if (analysis?.baselineReady != true ||
        analysis?.pressureAvailable != true) {
      return false;
    }
    final scores = side == 'left'
        ? analysis!.leftPressureScores
        : analysis!.rightPressureScores;
    return scores.any((score) => score >= 0.25);
  }

  Future<void> _restartCalibration() async {
    await widget.ttsSpeaker.stop();
    widget.calibrationSpeech.start();
    try {
      await controller.restartWearingCalibration();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已开始空载温度采集，请保持双脚完全离开鞋垫')),
      );
    } catch (_) {
      widget.calibrationSpeech.cancel();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('标定启动失败，请确认后端已连接')));
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
                  label: '左脚设备',
                  status: controller.connections.left,
                ),
                const SizedBox(width: 10),
                ConnectionStatusCard(
                  label: '右脚设备',
                  status: controller.connections.right,
                ),
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
              recoveryObservation: controller.recoveryObservation,
              backendOnline: controller.backendOnline,
            ),
            if (controller.activeRisks.any(
                  (risk) => risk.riskType == 'temperature_asymmetry',
                ) &&
                controller.regionalAnalysis?.pressureAvailable == false) ...[
              const SizedBox(height: 8),
              const Text(
                '当前无承重，温度变化仅用于演示或辅助观察，不表示真实穿鞋状态下的医学风险。',
                style: TextStyle(color: Color(0xFFA86612), fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            _WearingCalibrationCard(
              status: controller.calibrationStatus,
              stage: controller.calibrationStage,
              backendOnline: controller.backendOnline,
              resetting: controller.calibrationResetting,
              onRestart: _restartCalibration,
            ),
            if (controller.errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                controller.errorMessage!,
                style: const TextStyle(color: Color(0xFFB54A42)),
              ),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 680;
                final analysis = controller.regionalAnalysis;
                final feet = [
                  Expanded(
                    child: FootPressureView(
                      side: 'left',
                      showPressureAbnormality: _showPressureAbnormality('left'),
                      showTemperatureAbnormality: _showTemperatureAbnormality(
                        'left',
                      ),
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
                      baselineSampleCount: analysis?.baselineSampleCount ?? 0,
                      baselineRequiredSamples:
                          analysis?.baselineRequiredSamples ?? 40,
                    ),
                  ),
                  const SizedBox(width: 12, height: 12),
                  Expanded(
                    child: FootPressureView(
                      side: 'right',
                      showPressureAbnormality: _showPressureAbnormality(
                        'right',
                      ),
                      showTemperatureAbnormality: _showTemperatureAbnormality(
                        'right',
                      ),
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
                      baselineSampleCount: analysis?.baselineSampleCount ?? 0,
                      baselineRequiredSamples:
                          analysis?.baselineRequiredSamples ?? 40,
                    ),
                  ),
                ];
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: feet,
                      )
                    : Column(
                        children: [
                          FootPressureView(
                            side: 'left',
                            showPressureAbnormality: _showPressureAbnormality(
                              'left',
                            ),
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
                            showPressureAbnormality: _showPressureAbnormality(
                              'right',
                            ),
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
              },
            ),
            const SizedBox(height: 12),
            _MetricsCard(controller: controller),
            if (controller.gait.lastCompletedEpisode != null) ...[
              const SizedBox(height: 12),
              _GaitAssessmentCard(
                episode: controller.gait.lastCompletedEpisode!,
              ),
            ],
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.vibration_rounded),
                ),
                title: const Text(
                  '马达提醒状态',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(controller.motorStatus),
                trailing: controller.motorCommand == null ||
                        controller.usesRealBleCommands
                    ? null
                    : FilledButton(
                        onPressed: controller.executeMotorCommand,
                        child: const Text('模拟执行'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WearingCalibrationCard extends StatelessWidget {
  const _WearingCalibrationCard({
    required this.status,
    required this.stage,
    required this.backendOnline,
    required this.resetting,
    required this.onRestart,
  });

  final CalibrationStatus? status;
  final String stage;
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

  String get _progressReason {
    final current = status;
    if (current == null || current.baselineReady) return _reason;
    if (current.sampleCount >= current.requiredSamples) {
      return '最低样本数已达到，正在校验承重稳定性，请继续自然站立';
    }
    return _reason;
  }

  String get _stageTitle => switch (stage) {
        'empty_reference' => '步骤 1：空载温度采集',
        'put_on' => '步骤 2：请穿鞋并自然站立',
        'standing_baseline' =>
          '步骤 2：个人基线 ${status?.sampleCount ?? 0}/${status?.requiredSamples ?? 40}',
        'complete' => '本次穿戴已就绪',
        _ => '本次穿戴标定',
      };

  String get _stageReason => switch (stage) {
        'empty_reference' => '请保持双脚完全离开鞋垫，空载完成后会立即语音提示',
        'put_on' => '空载温度已完成，现在可以穿鞋并开始个人基线采集',
        'standing_baseline' => _progressReason,
        'complete' => '个人基线已锁定，风险识别与马达提醒已启用',
        _ => _progressReason,
      };

  String get _temperatureReason {
    final current = status;
    if (current == null || !current.emptyTemperatureReferenceReady) {
      return '温度参考学习中：双脚先离开鞋垫，保持约 27 秒；此阶段温差只显示、不报警。';
    }
    if (!current.baselineReady) {
      return '空载温度参考已完成，请穿鞋自然站立完成本次穿戴基线。';
    }
    if (!current.temperatureRiskEnabled) {
      return '温度风险暂停：当前可信温区少于 2 个，压力监测不受影响。';
    }
    if (current.temperatureOffsetChannels.isNotEmpty) {
      final labels = current.temperatureOffsetChannels
          .map((index) => 'T${index + 1}')
          .join('、');
      return '温度偏置补偿已启用：$labels 使用相对本次穿戴基线的变化判断。';
    }
    return '温度基线已就绪：按相对变化判断，并保留普通温区绝对温差兜底。';
  }

  @override
  Widget build(BuildContext context) {
    final ready = status?.baselineReady ?? false;
    final progress = status?.progress ?? 0.0;
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
                      _stageTitle,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed: resetting ? null : onRestart,
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
              _stageReason,
              style: const TextStyle(color: Color(0xFF63757B), fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              _temperatureReason,
              style: const TextStyle(color: Color(0xFF39758C), fontSize: 12),
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
                value: controller.loadBias?.toStringAsFixed(3) ?? '--',
              ),
              _Metric(
                label: '左右差值',
                value: controller.loadDiff?.toStringAsFixed(3) ?? '--',
              ),
              _Metric(
                label: '同步误差',
                value: controller.syncErrorMs == null
                    ? '--'
                    : '${controller.syncErrorMs} ms',
              ),
              _Metric(label: '活动状态', value: controller.motionStatusLabel),
              _Metric(
                label: '左脚运动',
                value: controller.footMotionStatusLabel('left'),
              ),
              _Metric(
                label: '右脚运动',
                value: controller.footMotionStatusLabel('right'),
              ),
              _Metric(label: '基础步态', value: controller.gaitStatusLabel),
              _Metric(
                label: controller.gait.state == 'walking' ? '近12秒落脚' : '最近一次落脚',
                value: controller.gaitStepLabel,
              ),
              _Metric(
                label: controller.gait.state == 'walking' ? '实时估算步频' : '最近估算步频',
                value: controller.gaitCadenceLabel,
              ),
              _Metric(
                  label: '后端', value: controller.backendOnline ? '在线' : '离线'),
              _Metric(label: '数据源', value: controller.source.label),
            ],
          ),
        ),
      );
}

class _GaitAssessmentCard extends StatelessWidget {
  const _GaitAssessmentCard({required this.episode});

  final GaitEpisodeSummary episode;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.directions_walk_rounded),
                  SizedBox(width: 8),
                  Text(
                    '最近一次完整行走评估',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${episode.stepCount} 次落脚 · ${episode.cadenceSpm.toStringAsFixed(0)} 步/分钟 · '
                '负荷不对称 ${(episode.loadAsymmetry * 100).toStringAsFixed(0)}%',
              ),
              const SizedBox(height: 8),
              if (episode.issues.isEmpty)
                const Text(
                  '本次有效行走未发现达到工程阈值的负荷或步时问题。',
                  style: TextStyle(color: Color(0xFF147D73)),
                )
              else
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: episode.issues
                      .map(
                        (issue) => Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(_issueLabel(issue)),
                        ),
                      )
                      .toList(growable: false),
                ),
            ],
          ),
        ),
      );

  static String _issueLabel(GaitIssue issue) {
    final side = issue.side == 'left'
        ? '左脚'
        : issue.side == 'right'
            ? '右脚'
            : '';
    return switch (issue.issueType) {
      'walking_load_asymmetry' => '$side行走负荷偏高',
      'walking_forefoot_concentration' => '$side前掌反复受压',
      'walking_medial_concentration' => '$side内侧反复受压',
      'walking_lateral_concentration' => '$side外侧反复受压',
      'step_timing_instability' => '步时波动较大',
      _ => '行走趋势异常',
    };
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 105,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Color(0xFF718096), fontSize: 12),
            ),
            const SizedBox(height: 3),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
      );
}
