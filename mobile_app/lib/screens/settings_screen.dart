import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/api_client.dart';

typedef BackendHealthCheck = Future<bool> Function(String baseUrl);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.healthCheck,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final BackendHealthCheck? healthCheck;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings value = widget.settings;
  late final TextEditingController backend =
      TextEditingController(text: value.backendUrl);
  bool _testingBackend = false;
  String? _backendStatus;
  bool _backendOnline = false;

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      value = widget.settings;
      backend.text = value.backendUrl;
      _backendStatus = null;
      _backendOnline = false;
    }
  }

  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }

  String? _backendUrlError() {
    if (!isValidBackendUrl(backend.text)) {
      return '请输入以 http:// 或 https:// 开头的完整地址';
    }
    return null;
  }

  void _save() {
    final urlError = _backendUrlError();
    if (urlError != null) {
      setState(() {
        _backendStatus = urlError;
        _backendOnline = false;
      });
      return;
    }
    value = value.copyWith(
      backendUrl: normalizeBackendUrl(backend.text),
    );
    widget.onChanged(value);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置已保存，实时页数据源已更新')),
    );
  }

  Future<void> _testBackend() async {
    final urlError = _backendUrlError();
    if (urlError != null) {
      setState(() {
        _backendStatus = urlError;
        _backendOnline = false;
      });
      return;
    }
    setState(() {
      _testingBackend = true;
      _backendStatus = '正在检测后端…';
      _backendOnline = false;
    });
    try {
      final online = await (widget.healthCheck ?? _defaultHealthCheck)(
        backend.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _backendOnline = online;
        _backendStatus = online ? '后端连接正常' : '后端响应异常';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _backendOnline = false;
        _backendStatus = '连接失败：$error';
      });
    } finally {
      if (mounted) {
        setState(() => _testingBackend = false);
      }
    }
  }

  static Future<bool> _defaultHealthCheck(String baseUrl) async {
    final api = FootGuardApiClient(baseUrl: baseUrl);
    try {
      return await api.health();
    } finally {
      api.close();
    }
  }

  void _restoreDefaults() {
    const defaults = AppSettings();
    setState(() {
      value = defaults;
      backend.text = defaults.backendUrl;
      _backendStatus = '已恢复默认值，点击“应用设置”后保存';
      _backendOnline = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scenario = mockScenarioOption(value.mockScenario);
    final csvAsset = csvReplayOptions.any(
      (option) => option.assetPath == value.csvAsset,
    )
        ? value.csvAsset
        : csvReplayOptions.first.assetPath;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: backend,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {
            _backendStatus = null;
            _backendOnline = false;
          }),
          decoration: InputDecoration(
            labelText: 'FastAPI 后端地址',
            helperText: '真机填写电脑局域网地址；模拟器可用 http://10.0.2.2:8000',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: '检测连接',
              onPressed: _testingBackend ? null : _testBackend,
              icon: _testingBackend
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering_outlined),
            ),
          ),
        ),
        if (_backendStatus != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              _backendStatus!,
              key: const ValueKey('backend-status'),
              style: TextStyle(
                color: _backendOnline
                    ? const Color(0xFF147D73)
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        DropdownButtonFormField<FootDataMode>(
          key: ValueKey('data-mode-${value.dataMode.name}'),
          initialValue: value.dataMode,
          decoration: const InputDecoration(
            labelText: '数据源',
            border: OutlineInputBorder(),
          ),
          items: FootDataMode.values
              .map(
                (mode) => DropdownMenuItem(
                  value: mode,
                  child: Text(_modeLabel(mode)),
                ),
              )
              .toList(),
          onChanged: (mode) =>
              setState(() => value = value.copyWith(dataMode: mode)),
        ),
        if (value.dataMode == FootDataMode.mock) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('mock-scenario-${value.mockScenario}'),
            initialValue: value.mockScenario,
            decoration: const InputDecoration(
              labelText: '模拟场景',
              border: OutlineInputBorder(),
            ),
            items: mockScenarioOptions
                .map(
                  (option) => DropdownMenuItem(
                    value: option.id,
                    child: Text(option.label),
                  ),
                )
                .toList(),
            onChanged: (scenarioId) => setState(
              () => value = value.copyWith(mockScenario: scenarioId),
            ),
          ),
          const SizedBox(height: 8),
          _InfoPanel(
            icon: Icons.movie_filter_outlined,
            title: scenario.label,
            body: scenario.description,
          ),
        ],
        if (value.dataMode == FootDataMode.csvReplay) ...[
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            key: ValueKey('csv-asset-$csvAsset'),
            initialValue: csvAsset,
            decoration: const InputDecoration(
              labelText: 'CSV 回放数据',
              border: OutlineInputBorder(),
            ),
            items: csvReplayOptions
                .map(
                  (option) => DropdownMenuItem(
                    value: option.assetPath,
                    child: Text(option.label),
                  ),
                )
                .toList(),
            onChanged: (assetPath) => setState(
              () => value = value.copyWith(csvAsset: assetPath),
            ),
          ),
          const SizedBox(height: 8),
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
            trailing: Text('${value.replaySpeed}×'),
          ),
        ],
        if (value.dataMode == FootDataMode.backend) ...[
          const SizedBox(height: 8),
          const _InfoPanel(
            icon: Icons.cloud_outlined,
            title: '后端快照模式',
            body: '只读取后端已接收的双足数据，不从本机上传传感器帧。',
          ),
        ],
        if (value.dataMode == FootDataMode.ble) ...[
          const SizedBox(height: 8),
          const _InfoPanel(
            icon: Icons.bluetooth_connected,
            title: 'BLE 真机模式',
            body: '连接 FootGuard-L 与 FootGuard-R，双足帧会上传后端完成风险分析。',
          ),
        ],
        const SizedBox(height: 12),
        const _InfoPanel(
          icon: Icons.science_outlined,
          title: '当前竞赛原型规则',
          body: '个人基线至少需要 15 组稳定双足承重样本；偏载相对基线差值达到 '
              '0.25、前掌占比较基线增加 0.12，或同位置左右校正温差达到 '
              '2.0°C 时开始计时。持续 3/6/10 秒分别进入关注、警告、持续风险；'
              '风险等级 2 起发送双振 800 ms 马达命令。以上为工程原型规则，不是医疗诊断标准。',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _restoreDefaults,
                icon: const Icon(Icons.restart_alt),
                label: const Text('恢复默认值'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('应用设置'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static String _modeLabel(FootDataMode mode) => switch (mode) {
        FootDataMode.mock => '模拟场景实时生成',
        FootDataMode.csvReplay => 'CSV 场景回放',
        FootDataMode.backend => '仅显示后端数据',
        FootDataMode.ble => 'BLE 真机实时数据',
      };
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(body),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
