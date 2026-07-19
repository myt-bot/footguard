import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onStartMonitoring});

  final VoidCallback onStartMonitoring;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF126B67), Color(0xFF1BA889)]),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.health_and_safety_rounded,
                  color: Colors.white, size: 42),
              const SizedBox(height: 22),
              Text('足安智垫',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: Colors.white, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('双足压力、温度与姿态协同监测\n持续风险触发对应侧马达振动提醒',
                  style: TextStyle(color: Color(0xFFE4FFFA), height: 1.5)),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF126B67)),
                onPressed: onStartMonitoring,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('开始实时监测'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('闭环能力',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        const _FeatureTile(
            icon: Icons.sensors_rounded,
            title: '双足多源感知',
            subtitle: '每脚 6 区压力、4 点温度与六轴 IMU'),
        const _FeatureTile(
            icon: Icons.balance_rounded,
            title: '连续窗口判断',
            subtitle: '质量门控后识别持续偏载与前掌高载'),
        const _FeatureTile(
            icon: Icons.vibration_rounded,
            title: '马达振动提醒',
            subtitle: '风险侧双振提醒、ACK 确认与恢复效果记录'),
      ],
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
              child: Icon(icon, color: const Color(0xFF12766C))),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
        ),
      );
}
