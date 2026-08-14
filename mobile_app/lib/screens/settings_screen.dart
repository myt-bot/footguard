import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../data/api_client.dart';
import '../services/local_tts_service.dart';
import '../services/offline_monitoring_store.dart';

typedef BackendHealthCheck = Future<bool> Function(String baseUrl);
typedef CalibrationStatusLoader = Future<CalibrationStatus> Function(
  String baseUrl,
);
typedef CalibrationResetter = Future<CalibrationStatus> Function(
  String baseUrl,
);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.onChanged,
    this.onCalibrationReset,
    this.healthCheck,
    this.calibrationStatusLoader,
    this.calibrationResetter,
    this.ttsSpeaker,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onChanged;
  final VoidCallback? onCalibrationReset;
  final BackendHealthCheck? healthCheck;
  final CalibrationStatusLoader? calibrationStatusLoader;
  final CalibrationResetter? calibrationResetter;
  final TtsSpeaker? ttsSpeaker;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings value = widget.settings;
  late final TextEditingController backend = TextEditingController(
    text: value.backendUrl,
  );
  bool _testingBackend = false;
  String? _backendStatus;
  bool _backendOnline = false;
  bool _loadingCalibration = false;
  CalibrationStatus? _calibrationStatus;
  String? _calibrationError;
  late final TtsSpeaker _ttsSpeaker = widget.ttsSpeaker ?? AndroidTtsService();

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.settings, widget.settings)) {
      value = widget.settings;
      backend.text = value.backendUrl;
      _backendStatus = null;
      _backendOnline = false;
      _calibrationStatus = null;
      _calibrationError = null;
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
      dataMode:
          diagnosticReplayEnabled && value.dataMode == FootDataMode.csvReplay
              ? FootDataMode.csvReplay
              : FootDataMode.ble,
    );
    widget.onChanged(value);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设置已保存，实时页数据源已更新')));
  }

  Future<void> _testVoice() async {
    final available = await _ttsSpeaker.speak('语音提醒已开启。');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(available ? '中文语音测试成功' : '中文语音不可用，文字提醒仍会保留')),
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

  Future<CalibrationStatus> _defaultCalibrationStatus(String baseUrl) async {
    final api = FootGuardApiClient(baseUrl: baseUrl);
    try {
      return await api.calibrationStatus();
    } finally {
      api.close();
    }
  }

  Future<CalibrationStatus> _defaultResetCalibration(String baseUrl) async {
    final api = FootGuardApiClient(baseUrl: baseUrl);
    try {
      final status = await api.resetCalibration();
      await OfflineMonitoringStore().clearBaseline();
      return status;
    } finally {
      api.close();
    }
  }

  Future<void> _loadCalibrationStatus() async {
    if (_backendUrlError() != null) {
      setState(() => _calibrationError = '请先填写有效的后端地址');
      return;
    }
    setState(() {
      _loadingCalibration = true;
      _calibrationError = null;
    });
    try {
      final status =
          await (widget.calibrationStatusLoader ?? _defaultCalibrationStatus)(
        backend.text.trim(),
      );
      if (!mounted) return;
      setState(() => _calibrationStatus = status);
    } catch (error) {
      if (!mounted) return;
      setState(() => _calibrationError = '读取基线状态失败：$error');
    } finally {
      if (mounted) {
        setState(() => _loadingCalibration = false);
      }
    }
  }

  Future<void> _confirmResetCalibration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新学习个人基线？'),
        content: const Text(
          '更换体验者或重新穿鞋后都需要重新建立本次穿戴基线。'
          '确认后先保持双脚完全离开鞋垫，完成空载温度采集；'
          '听到提示后再穿鞋，并自然站立完成个人基线采集。'
          '重新校准不会删除历史事件，但会结束当前风险并使待执行马达命令失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认重新校准'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _loadingCalibration = true;
      _calibrationError = null;
    });
    try {
      final status =
          await (widget.calibrationResetter ?? _defaultResetCalibration)(
        backend.text.trim(),
      );
      if (!mounted) return;
      setState(() => _calibrationStatus = status);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已开始空载温度采集，请保持双脚完全离开鞋垫')),
      );
      widget.onCalibrationReset?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() => _calibrationError = '重新校准失败：$error');
    } finally {
      if (mounted) {
        setState(() => _loadingCalibration = false);
      }
    }
  }

  String _calibrationReason(String reason) => switch (reason) {
        'pressure_unavailable' => '压力通道不可用，请先检查连接和传感器。',
        'not_loaded' => '等待双脚稳定承重。',
        'left_not_loaded' => '左脚未形成有效多点承重，请调整左脚位置。',
        'right_not_loaded' => '右脚未形成有效多点承重，请调整右脚位置。',
        'pressure_residual' => '仅检测到固定残余压力，请完整穿好双脚。',
        'moving' => '当前移动较大，请保持自然站立。',
        'unstable' => '数据波动较大，请保持双脚平行并放松站立。',
        'ready' => '标定已完成。',
        _ => '等待双脚同步数据。',
      };

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
    final csvAsset =
        csvReplayOptions.any((option) => option.assetPath == value.csvAsset)
            ? value.csvAsset
            : csvReplayOptions.first.assetPath;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '提醒与监测设置',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.record_voice_over_rounded),
                title: const Text('语音提醒'),
                subtitle: const Text('使用 Android 本地语音；关闭后仍保留文字提醒'),
                value: value.voiceEnabled,
                onChanged: (enabled) {
                  setState(() => value = value.copyWith(voiceEnabled: enabled));
                  if (!enabled) unawaited(_ttsSpeaker.stop());
                  widget.onChanged(value);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: value.voiceEnabled ? _testVoice : null,
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('测试中文语音'),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const _InfoPanel(
          icon: Icons.cloud_outlined,
          title: '后端连接',
          body: '真机填写电脑局域网地址；该地址只控制数据上传、历史与 AI，不会切换 BLE 数据源。',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: backend,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {
            _backendStatus = null;
            _backendOnline = false;
            _calibrationStatus = null;
            _calibrationError = null;
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
        if (diagnosticReplayEnabled) ...[
          const _InfoPanel(
            icon: Icons.build_circle_outlined,
            title: '隐藏诊断入口',
            body: '仅用于真实 CSV 回放，不是正式用户功能。',
          ),
          const SizedBox(height: 12),
        ],
        if (diagnosticReplayEnabled)
          DropdownButtonFormField<FootDataMode>(
            key: ValueKey('data-mode-${value.dataMode.name}'),
            initialValue: value.dataMode,
            decoration: const InputDecoration(
              labelText: '数据源',
              border: OutlineInputBorder(),
            ),
            items: const [FootDataMode.ble, FootDataMode.csvReplay]
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
        if (diagnosticReplayEnabled &&
            value.dataMode == FootDataMode.csvReplay) ...[
          const SizedBox(height: 16),
          const _InfoPanel(
            icon: Icons.warning_amber_rounded,
            title: '诊断与应急回放',
            body: '当前为历史真实数据回放，不是真机实时监测。',
          ),
          const SizedBox(height: 8),
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
            onChanged: (assetPath) =>
                setState(() => value = value.copyWith(csvAsset: assetPath)),
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
        if (!diagnosticReplayEnabled || value.dataMode == FootDataMode.ble) ...[
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
          title: '当前穿戴自适应规则',
          body: '每次更换体验者或重新穿鞋后，先采集 40 组稳定双足承重样本。'
              '偏载使用左右载荷对数比相对本次基线的变化，前掌使用足内占比变化，'
              '并结合基线波动自动提高噪声较大场景的阈值。压力持续 5/10/20 秒分别进入趋势观察、需要减负、持续未改善；'
              '压力 10 秒或温度 15 秒时文字与语音提醒一次，压力 20 秒或温度 30 秒仍未恢复时马达执行一次。'
              '趋势观察不弹窗、不播报、不震动。'
              '以上为工程原型规则，不是医疗诊断标准。',
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '本次穿戴基线',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新基线状态',
                      onPressed:
                          _loadingCalibration ? null : _loadCalibrationStatus,
                      icon: _loadingCalibration
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _calibrationStatus == null
                      ? '点击刷新，从后端读取当前学习进度。'
                      : _calibrationStatus!.baselineReady
                          ? '本次穿戴基线已完成，压力风险与马达已启用'
                          : _calibrationStatus!.sampleCount >=
                                  _calibrationStatus!.requiredSamples
                              ? '最低样本数已达到，正在校验承重稳定性，请继续自然站立'
                              : '学习中：${_calibrationStatus!.sampleCount}/'
                                  '${_calibrationStatus!.requiredSamples} 组稳定双足承重样本',
                  key: const ValueKey('calibration-status'),
                ),
                if (_calibrationStatus != null &&
                    !_calibrationStatus!.baselineReady) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _calibrationStatus!.progress),
                  const SizedBox(height: 6),
                  Text(
                    _calibrationReason(_calibrationStatus!.statusReason),
                    style: const TextStyle(
                      color: Color(0xFF718096),
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_calibrationError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _calibrationError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed:
                        _loadingCalibration ? null : _confirmResetCalibration,
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('新体验者 / 重新穿戴'),
                  ),
                ),
              ],
            ),
          ),
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
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
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
