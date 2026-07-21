import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/api_client.dart';
import '../data/backend_foot_data_source.dart';
import '../data/ble_foot_data_source.dart';
import '../data/csv_replay_data_source.dart';
import '../data/foot_data_source.dart';
import '../data/mock_foot_data_source.dart';
import '../services/ble_connection_service.dart';
import '../services/monitoring_controller.dart';
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

class _RealtimeScreenState extends State<RealtimeScreen> {
  late final MonitoringController controller;

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
    final api = FootGuardApiClient(baseUrl: widget.settings.backendUrl);
    controller = MonitoringController(source: _source(api), api: api);
    controller.start();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
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
                    battery: controller.left?.battery),
                const SizedBox(width: 10),
                ConnectionStatusCard(
                    label: '右脚设备',
                    status: controller.connections.right,
                    battery: controller.right?.battery),
              ],
            ),
            const SizedBox(height: 12),
            RiskBanner(risk: controller.risk),
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
                    frame: controller.left,
                    oppositeFrame: controller.right,
                    pressureScores: analysis?.leftPressureScores,
                    temperatureScores: analysis?.leftTemperatureScores,
                    temperatureDeltaC: analysis?.temperatureDeltaC,
                    baselineReady: analysis?.baselineReady ?? false,
                  ),
                ),
                const SizedBox(width: 12, height: 12),
                Expanded(
                  child: FootPressureView(
                    side: 'right',
                    frame: controller.right,
                    oppositeFrame: controller.left,
                    pressureScores: analysis?.rightPressureScores,
                    temperatureScores: analysis?.rightTemperatureScores,
                    temperatureDeltaC: analysis?.temperatureDeltaC,
                    baselineReady: analysis?.baselineReady ?? false,
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
                          frame: controller.left,
                          oppositeFrame: controller.right,
                          pressureScores: analysis?.leftPressureScores,
                          temperatureScores: analysis?.leftTemperatureScores,
                          temperatureDeltaC: analysis?.temperatureDeltaC,
                          baselineReady: analysis?.baselineReady ?? false,
                        ),
                        const SizedBox(height: 12),
                        FootPressureView(
                          side: 'right',
                          frame: controller.right,
                          oppositeFrame: controller.left,
                          pressureScores: analysis?.rightPressureScores,
                          temperatureScores: analysis?.rightTemperatureScores,
                          temperatureDeltaC: analysis?.temperatureDeltaC,
                          baselineReady: analysis?.baselineReady ?? false,
                        ),
                      ],
                    );
            }),
            const SizedBox(height: 12),
            _MetricsCard(controller: controller),
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              child: ListTile(
                leading:
                    const CircleAvatar(child: Icon(Icons.vibration_rounded)),
                title: const Text('马达提醒状态',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(controller.motorStatus),
                trailing: controller.motorCommand == null
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
