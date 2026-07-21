import 'package:flutter/material.dart';

import '../config/app_config.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen(
      {super.key, required this.settings, required this.onChanged});
  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings value = widget.settings;
  late final TextEditingController backend =
      TextEditingController(text: value.backendUrl);

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      value = widget.settings;
      backend.text = value.backendUrl;
    }
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }

  void _save() {
    value = value.copyWith(backendUrl: backend.text.trim());
    widget.onChanged(value);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设置已应用，重新进入实时页生效')));
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: backend,
            decoration: const InputDecoration(
                labelText: 'FastAPI 地址',
                helperText: '模拟器使用 http://10.0.2.2:8000',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<FootDataMode>(
            key: ValueKey('data-mode-${value.dataMode.name}'),
            initialValue: value.dataMode,
            decoration: const InputDecoration(
                labelText: '数据源', border: OutlineInputBorder()),
            items: FootDataMode.values
                .map((mode) => DropdownMenuItem(
                    value: mode, child: Text(_modeLabel(mode))))
                .toList(),
            onChanged: (mode) =>
                setState(() => value = value.copyWith(dataMode: mode)),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('mock-scenario-${value.mockScenario}'),
            initialValue: value.mockScenario,
            decoration: const InputDecoration(
                labelText: 'Mock 场景', border: OutlineInputBorder()),
            items: mockScenarios
                .map((scenario) =>
                    DropdownMenuItem(value: scenario, child: Text(scenario)))
                .toList(),
            onChanged: (scenario) =>
                setState(() => value = value.copyWith(mockScenario: scenario)),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('CSV 回放速度'),
            subtitle: Slider(
              value: value.replaySpeed,
              min: 0.5,
              max: 4,
              divisions: 7,
              label: '${value.replaySpeed}×',
              onChanged: (speed) =>
                  setState(() => value = value.copyWith(replaySpeed: speed)),
            ),
          ),
          const Card(
            elevation: 0,
            child: ListTile(
              leading: Icon(Icons.science_outlined),
              title: Text('当前暂定规则'),
              subtitle: Text('偏载阈值 0.25；连续 3/6/10 秒对应关注/警告/持续。仅用于竞赛原型，不是医疗标准。'),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('应用设置')),
        ],
      );

  static String _modeLabel(FootDataMode mode) => switch (mode) {
        FootDataMode.mock => 'Mock 实时生成',
        FootDataMode.csvReplay => 'CSV 场景回放',
        FootDataMode.backend => '仅显示后端数据',
        FootDataMode.ble => 'BLE 真机实时数据',
      };
}
