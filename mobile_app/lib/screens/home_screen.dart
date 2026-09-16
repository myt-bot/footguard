import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/assessment.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.backendUrl = 'http://127.0.0.1:8000',
    required this.onStartMonitoring,
  });

  final String backendUrl;
  final VoidCallback onStartMonitoring;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final FootGuardApiClient _api =
      FootGuardApiClient(baseUrl: widget.backendUrl);
  late Future<AssessmentSummary> _assessment = _api.latestAssessment();

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async {
          final next = _api.latestAssessment();
          setState(() => _assessment = next);
          await next;
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF126B67),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.health_and_safety_rounded,
                      color: Colors.white, size: 42),
                  const SizedBox(height: 18),
                  Text(
                    '足安智垫',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text('双足压力、温度与姿态协同监测',
                      style: TextStyle(color: Color(0xFFE4FFFA), height: 1.5)),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF126B67),
                    ),
                    onPressed: widget.onStartMonitoring,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('开始实时监测'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<AssessmentSummary>(
              future: _assessment,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Card(
                    elevation: 0,
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Card(
                    elevation: 0,
                    child: ListTile(
                      leading: Icon(Icons.cloud_off_outlined),
                      title: Text('近期监测评级暂不可用'),
                      subtitle: Text('连接后端后下拉刷新；实时 BLE 监测仍可继续。'),
                    ),
                  );
                }
                return _AssessmentCard(summary: snapshot.data!);
              },
            ),
            const SizedBox(height: 16),
            Text('监测能力',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            const _FeatureTile(
              icon: Icons.sensors_rounded,
              title: '双足多源感知',
              subtitle: '每脚 6 区压力、4 点温度与六轴 IMU',
            ),
            const _FeatureTile(
              icon: Icons.balance_rounded,
              title: '连续窗口判断',
              subtitle: '质量门控后识别持续偏载与前掌高载',
            ),
            const _FeatureTile(
              icon: Icons.vibration_rounded,
              title: '马达振动提醒',
              subtitle: '压力风险触发对应侧马达；温度仅文字和语音提醒',
            ),
          ],
        ),
      );
}

class _AssessmentCard extends StatelessWidget {
  const _AssessmentCard({required this.summary});
  final AssessmentSummary summary;

  @override
  Widget build(BuildContext context) {
    final rating = summary.rating;
    final color = switch (rating.level) {
      0 => const Color(0xFF18765C),
      1 => const Color(0xFF9A6A08),
      2 => const Color(0xFFB45721),
      _ => const Color(0xFFB23B3B),
    };
    final trendIcon = switch (rating.trend) {
      'improving' => Icons.trending_down_rounded,
      'worsening' => Icons.trending_up_rounded,
      'stable' => Icons.trending_flat_rounded,
      _ => Icons.help_outline_rounded,
    };
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.assessment_outlined, color: color),
              const SizedBox(width: 8),
              const Expanded(
                  child: Text('近期监测评级',
                      style: TextStyle(fontWeight: FontWeight.w800))),
              Text(rating.label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Icon(trendIcon, size: 20, color: const Color(0xFF526A68)),
              const SizedBox(width: 6),
              Expanded(child: Text(rating.trendLabel)),
            ]),
            if (rating.evidence.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('主要依据：${rating.evidence.first}'),
            ],
            if (rating.dataQuality.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('数据质量：${rating.dataQuality.first}',
                  style:
                      const TextStyle(color: Color(0xFF607D7B), fontSize: 13)),
            ],
            if (summary.temperature.demoDays > 0) ...[
              const Divider(height: 20),
              const Row(children: [
                Icon(Icons.science_outlined, size: 18),
                SizedBox(width: 6),
                Expanded(child: Text('单次温度演示已完成，不计入真实评级')),
              ]),
            ],
            const SizedBox(height: 10),
            const Text('这是设备近期监测分级，不是糖尿病足诊断或临床风险等级。',
                style: TextStyle(color: Color(0xFF718096), fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFFE0F5F0),
            child: Icon(icon, color: const Color(0xFF12766C)),
          ),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
        ),
      );
}
