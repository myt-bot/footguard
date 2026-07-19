import 'package:flutter/material.dart';

import '../data/api_client.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.backendUrl});
  final String backendUrl;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final FootGuardApiClient api =
      FootGuardApiClient(baseUrl: widget.backendUrl);
  late Future<List<RiskEventRecord>> events = api.events();

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
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: data.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final event = data[index];
                final date =
                    DateTime.fromMillisecondsSinceEpoch(event.startedAtMs);
                return Card(
                  elevation: 0,
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${event.riskLevel}')),
                    title: Text(event.riskType,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${event.riskSide} · ${(event.durationMs / 1000).toStringAsFixed(1)} 秒\n${date.toLocal()}'),
                    trailing: Text(event.status),
                  ),
                );
              },
            ),
          );
        },
      );

  Future<void> _reload() async {
    setState(() => events = api.events());
    await events;
  }
}

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
