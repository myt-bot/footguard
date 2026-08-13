import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/foot_frame.dart';

class FootPressureView extends StatelessWidget {
  const FootPressureView({
    super.key,
    required this.side,
    required this.frame,
    this.oppositeFrame,
    this.pressureScores,
    this.pressureValid,
    this.oppositePressureValid,
    this.pressureAnalysisValid,
    this.pressureChannelStatus,
    this.temperatureScores,
    this.temperatureDeltaC,
    this.baselineReady = false,
    this.baselineSampleCount = 0,
    this.baselineRequiredSamples = 40,
    this.showPressureAbnormality = false,
    this.showTemperatureAbnormality = true,
  });

  final String side;
  final FootFrame? frame;
  final FootFrame? oppositeFrame;
  final List<double>? pressureScores;
  final List<bool>? pressureValid;
  final List<bool>? oppositePressureValid;
  final List<bool>? pressureAnalysisValid;
  final List<String>? pressureChannelStatus;
  final List<double>? temperatureScores;
  final List<double?>? temperatureDeltaC;
  final bool baselineReady;
  final int baselineSampleCount;
  final int baselineRequiredSamples;
  final bool showPressureAbnormality;
  final bool showTemperatureAbnormality;

  static const _defaultDistribution = <double>[
    0.16,
    0.17,
    0.18,
    0.14,
    0.18,
    0.17,
  ];
  static const _pressureZones = <String>[
    '拇趾区',
    '前掌外侧',
    '前掌中央',
    '前掌内侧',
    '中足中央',
    '足跟中央',
  ];
  static const _temperatureZones = <String>[
    '前掌外侧',
    '拇趾/第一跖骨头邻近',
    '足跟中央',
    '中足中央',
  ];

  // Competition-prototype display gate; recalibrate after final insole assembly.
  // One unloaded FSR can retain a high residual. Require multi-point contact
  // before using pressure data to paint an abnormal region.
  static const double _minimumFallbackPressure = 0.01;
  static const int _minimumContactChannels = 2;

  bool _pressureChannelValid(int index) {
    final backendValidity = pressureValid;
    if (backendValidity != null && backendValidity.length == 6) {
      return backendValidity[index];
    }
    return frame?.pressureChannelValid(index) == true;
  }

  bool _oppositePressureChannelValid(int index) {
    final backendValidity = oppositePressureValid;
    if (backendValidity != null && backendValidity.length == 6) {
      return backendValidity[index];
    }
    return oppositeFrame?.pressureChannelValid(index) == true;
  }

  bool _pressureChannelAnalysisValid(int index) {
    final validity = pressureAnalysisValid;
    return validity == null || validity.length != 6 || validity[index];
  }

  bool _pressureChannelTrustedForContact(int index) {
    final statuses = pressureChannelStatus;
    return statuses == null ||
        statuses.length != 6 ||
        statuses[index] != 'residual_suspect';
  }

  bool get _pressureContactPresent {
    if (frame == null || frame!.pressure.length != 6) {
      return false;
    }
    final validValues = [
      for (var index = 0; index < 6; index++)
        if (_pressureChannelValid(index) &&
            _pressureChannelTrustedForContact(index))
          frame!.pressure[index],
    ];
    return validValues
            .where((value) => value >= _minimumFallbackPressure)
            .length >=
        _minimumContactChannels;
  }

  List<double> get _fallbackPressureScores {
    if (!_pressureContactPresent) {
      return List.filled(6, 0.0);
    }
    final current = frame?.pressure;
    if (current == null || current.length != 6) {
      return List.filled(6, 0.0);
    }
    final peer = oppositeFrame?.pressureChannelsValid == true
        ? oppositeFrame?.pressure
        : null;
    final total = current.fold<double>(0, (sum, value) => sum + value);
    return List.generate(6, (index) {
      final distribution = current[index] / total;
      final shareChange = math.max(
        0.0,
        (distribution - _defaultDistribution[index]) /
            _defaultDistribution[index],
      );
      var asymmetry = 0.0;
      if (peer != null && peer.length == 6) {
        asymmetry = math.max(
          0.0,
          (current[index] - peer[index]) /
              math.max(current[index] + peer[index], 1e-9),
        );
      }
      return math
          .max(shareChange / 0.50, asymmetry / 0.35)
          .clamp(0.0, 1.0)
          .toDouble();
    });
  }

  List<double> get _resolvedPressureScores {
    if (!_pressureContactPresent || !showPressureAbnormality) {
      return List.filled(6, 0.0);
    }
    final values = pressureScores;
    return values != null && values.length == 6
        ? List.generate(
            6,
            (index) => _pressureChannelAnalysisValid(index)
                ? values[index].clamp(0.0, 1.0).toDouble()
                : 0.0,
            growable: false,
          )
        : _fallbackPressureScores;
  }

  List<double> get _pressureIntensity {
    final current = frame?.pressure;
    if (current == null || current.length != 6 || !_pressureContactPresent) {
      return List.filled(6, 0.0);
    }
    final allValidValues = <double>[
      for (var index = 0; index < 6; index++)
        if (_pressureChannelValid(index)) current[index],
      if (oppositeFrame?.pressure.length == 6)
        for (var index = 0; index < 6; index++)
          if (_oppositePressureChannelValid(index))
            oppositeFrame!.pressure[index],
    ];
    final maximum =
        allValidValues.isEmpty ? 0.0 : allValidValues.reduce(math.max);
    if (maximum <= 0) return List.filled(6, 0.0);
    return List.generate(6, (index) {
      if (!_pressureChannelValid(index)) return 0.0;
      return (current[index] / maximum).clamp(0.0, 1.0).toDouble();
    }, growable: false);
  }

  List<double> get _fallbackTemperatureScores {
    if (frame == null || oppositeFrame == null) {
      return List.filled(4, 0.0);
    }
    final current = frame?.temperature;
    final peer = oppositeFrame?.temperature;
    if (current == null ||
        peer == null ||
        current.length != 4 ||
        peer.length != 4) {
      return List.filled(4, 0.0);
    }
    return List.generate(4, (index) {
      if (frame?.temperatureChannelValid(index) != true ||
          oppositeFrame?.temperatureChannelValid(index) != true) {
        return 0.0;
      }
      return ((current[index] - peer[index]) / 2.0).clamp(0.0, 1.0).toDouble();
    });
  }

  List<double> get _resolvedTemperatureScores {
    if (!showTemperatureAbnormality || frame == null) {
      return List.filled(4, 0.0);
    }
    final values = temperatureScores;
    return values != null && values.length == 4
        ? List.generate(
            4,
            (index) => frame?.temperatureChannelValid(index) == true
                ? values[index].clamp(0.0, 1.0).toDouble()
                : 0.0,
            growable: false,
          )
        : _fallbackTemperatureScores;
  }

  double? _sideTemperatureDelta(int index) {
    if (frame?.temperatureChannelValid(index) != true ||
        oppositeFrame?.temperatureChannelValid(index) != true) {
      return null;
    }
    final current = frame?.temperature;
    final opposite = oppositeFrame?.temperature;
    if (current == null ||
        opposite == null ||
        current.length != 4 ||
        opposite.length != 4) {
      return null;
    }
    // “较对侧”必须对应屏幕上同一时刻显示的两只脚原始温度。
    // 后端的 temperatureDeltaC 是扣除个人基线后的风险特征，
    // 可用于风险评分，但不能拿来冒充可见温度的直接相减结果。
    return current[index] - opposite[index];
  }

  @override
  Widget build(BuildContext context) {
    final riskScores = _resolvedPressureScores;
    final pressureIntensity = _pressureIntensity;
    final temperatureSeverity = _resolvedTemperatureScores;
    final maximum = math.max(
      riskScores.reduce(math.max),
      temperatureSeverity.reduce(math.max),
    );
    final abnormalIndexes = [
      for (var index = 0; index < riskScores.length; index++)
        if (riskScores[index] >= 0.25) index,
    ]..sort((left, right) => riskScores[right].compareTo(riskScores[left]));
    final total = frame?.totalLoad ?? 0.0;
    final validPressureCount = frame == null
        ? 0
        : List.generate(6, _pressureChannelValid)
            .where((valid) => valid)
            .length;
    final channelStatuses = pressureChannelStatus;
    final rawInvalidCount = channelStatuses == null
        ? 6 - validPressureCount
        : channelStatuses.where((value) => value == 'raw_invalid').length;
    final uncoveredCount = channelStatuses
            ?.where((value) => value == 'uncovered_in_baseline')
            .length ??
        0;
    final residualCount =
        channelStatuses?.where((value) => value == 'residual_suspect').length ??
            0;
    final validTemperatureCount = frame == null
        ? 0
        : List.generate(4, frame!.temperatureChannelValid)
            .where((valid) => valid)
            .length;
    final pressureStatus = frame == null
        ? '等待压力数据'
        : validPressureCount < 4
            ? '压力不可用'
            : !_pressureContactPresent
                ? '未承重'
                : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                side == 'left' ? '左脚压力与温度分布' : '右脚压力与温度分布',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const Spacer(),
              _LevelBadge(score: maximum, statusLabel: pressureStatus),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            baselineReady
                ? '颜色显示实时受力；异常描边依据本次穿戴基线与左右同区对比'
                : '颜色显示实时受力；压力风险将在本次穿戴基线完成后启用'
                    '（基线学习中 $baselineSampleCount/'
                    '$baselineRequiredSamples）',
            style: const TextStyle(color: Color(0xFF718096), fontSize: 11),
          ),
          const SizedBox(height: 8),
          Center(
            child: SizedBox(
              width: 172,
              height: 370,
              child: CustomPaint(
                painter: _FootMapPainter(
                  side: side,
                  pressureIntensity: pressureIntensity,
                  pressureRiskScores: riskScores,
                  pressureValid: List.generate(
                    6,
                    _pressureChannelValid,
                    growable: false,
                  ),
                  temperatureScores: temperatureSeverity,
                ),
              ),
            ),
          ),
          const _RelativeLegend(),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: abnormalIndexes.isEmpty
                  ? const Color(0xFFEAF7F3)
                  : const Color(0xFFFFF2E7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  abnormalIndexes.isEmpty
                      ? Icons.check_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  size: 19,
                  color: abnormalIndexes.isEmpty
                      ? const Color(0xFF168A70)
                      : const Color(0xFFE66D22),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    abnormalIndexes.isEmpty
                        ? frame == null
                            ? '等待压力数据'
                            : validPressureCount < 4
                                ? '有效压力点不足，已暂停本脚压力判断'
                                : !_pressureContactPresent
                                    ? '当前未承重或受力过低'
                                    : '当前未发现明显的相对压力异常'
                        : '相对异常区域：${abnormalIndexes.take(3).map((index) {
                            final share = total <= 0
                                ? 0.0
                                : frame!.pressure[index] / total * 100;
                            return '${_pressureZones[index]}（占比 ${share.toStringAsFixed(1)}%，变化程度 ${(riskScores[index] * 100).round()}%）';
                          }).join('、')}',
                    style: const TextStyle(fontSize: 12, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
          if (frame != null && rawInvalidCount > 0) ...[
            const SizedBox(height: 7),
            Text(
              '$rawInvalidCount 个压力点数据不可用，已置灰且不按零压力参与计算',
              style: const TextStyle(
                color: Color(0xFF9A6200),
                fontSize: 11,
              ),
            ),
          ],
          if (frame != null && uncoveredCount > 0) ...[
            const SizedBox(height: 7),
            Text(
              '$uncoveredCount 个压力点本次标定未覆盖，保留实时显示但未纳入区域风险分析',
              style: const TextStyle(color: Color(0xFF9A6200), fontSize: 11),
            ),
          ],
          if (frame != null && residualCount > 0) ...[
            const SizedBox(height: 7),
            Text(
              '$residualCount 个压力点检测到稳定空载残余，保留显示但已从压力风险中排除',
              style: const TextStyle(color: Color(0xFF9A6200), fontSize: 11),
            ),
          ],
          const SizedBox(height: 11),
          Row(
            children: [
              Expanded(
                child: Text(
                  '温度测点位置',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              Text(
                validTemperatureCount == 0
                    ? '温度不可用'
                    : validTemperatureCount < 4
                        ? '$validTemperatureCount/4 可用'
                        : '4/4 可用',
                style: TextStyle(
                  color: validTemperatureCount == 4
                      ? const Color(0xFF168A70)
                      : const Color(0xFF9A6200),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          for (var row = 0; row < 2; row++) ...[
            Row(
              children: [
                for (var column = 0; column < 2; column++) ...[
                  if (column > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _TemperatureTile(
                      channel: row * 2 + column + 1,
                      zone: _temperatureZones[row * 2 + column],
                      value: frame?.temperatureChannelValid(row * 2 + column) ==
                              true
                          ? frame!.temperature[row * 2 + column]
                          : null,
                      delta: _sideTemperatureDelta(row * 2 + column),
                      score: temperatureSeverity[row * 2 + column],
                    ),
                  ),
                ],
              ],
            ),
            if (row == 0) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.score, this.statusLabel});

  final double score;
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    final (label, color) = statusLabel != null
        ? (statusLabel!, const Color(0xFF718096))
        : switch (score) {
            >= 0.75 => ('严重异常', const Color(0xFFD62F2F)),
            >= 0.50 => ('明显异常', const Color(0xFFF06A24)),
            >= 0.25 => ('需关注', const Color(0xFFE5A11B)),
            _ => ('相对正常', const Color(0xFF168A70)),
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _RelativeLegend extends StatelessWidget {
  const _RelativeLegend();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: const LinearGradient(
              colors: [
                Color(0xFF76C7D8),
                Color(0xFF64C29B),
                Color(0xFFF0CF4A),
                Color(0xFFF17A2A),
                Color(0xFFD62F2F),
              ],
            ),
          ),
        ),
        const SizedBox(height: 3),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('低受力',
                style: TextStyle(fontSize: 10, color: Color(0xFF718096))),
            Text('当前相对受力强度',
                style: TextStyle(fontSize: 10, color: Color(0xFF718096))),
            Text('高受力',
                style: TextStyle(fontSize: 10, color: Color(0xFF718096))),
          ],
        ),
      ],
    );
  }
}

class _TemperatureTile extends StatelessWidget {
  const _TemperatureTile({
    required this.channel,
    required this.zone,
    required this.value,
    required this.delta,
    required this.score,
  });

  final int channel;
  final String zone;
  final double? value;
  final double? delta;
  final double score;

  @override
  Widget build(BuildContext context) {
    final alert = score >= 0.75;
    final deltaText = delta == null
        ? '等待双足对比'
        : '较对侧 ${delta! >= 0 ? '+' : ''}${delta!.toStringAsFixed(1)}℃';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: alert ? const Color(0xFFFFE9E5) : const Color(0xFFF3F7F7),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: [
          Icon(
            Icons.device_thermostat_rounded,
            size: 18,
            color: alert ? const Color(0xFFD62F2F) : const Color(0xFF52737A),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'T$channel $zone',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800),
                ),
                Text(
                  '${value?.toStringAsFixed(1) ?? '--'}℃ · $deltaText',
                  style:
                      const TextStyle(fontSize: 10, color: Color(0xFF63757B)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FootMapPainter extends CustomPainter {
  _FootMapPainter({
    required this.side,
    required this.pressureIntensity,
    required this.pressureRiskScores,
    required this.pressureValid,
    required this.temperatureScores,
  });

  final String side;
  final List<double> pressureIntensity;
  final List<double> pressureRiskScores;
  final List<bool> pressureValid;
  final List<double> temperatureScores;

  bool get _isLeft => side == 'left';

  @override
  void paint(Canvas canvas, Size size) {
    final foot = _footPath(size);
    canvas.drawShadow(foot, const Color(0xFF304F55), 7, false);
    canvas.drawPath(
      foot,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7FAFA), Color(0xFFE6EFF0)],
        ).createShader(Offset.zero & size),
    );

    canvas.save();
    canvas.clipPath(foot);
    _drawSections(canvas, size);
    for (var index = 0; index < pressureIntensity.length; index++) {
      _drawPressureArea(
        canvas,
        size,
        index,
        pressureIntensity[index],
        pressureRiskScores[index],
        pressureValid[index],
      );
    }
    canvas.restore();

    canvas.drawPath(
      foot,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..color = const Color(0xFF8FA5AA),
    );
    for (var index = 0; index < temperatureScores.length; index++) {
      _drawTemperatureMarker(canvas, size, index, temperatureScores[index]);
    }
  }

  Path _footPath(Size size) {
    Offset point(double x, double y) => Offset(x * size.width, y * size.height);
    final path = Path()..moveTo(point(0.50, 0.02).dx, point(0.50, 0.02).dy);
    path.cubicTo(
      point(0.29, 0.02).dx,
      point(0.29, 0.02).dy,
      point(0.20, 0.10).dx,
      point(0.20, 0.10).dy,
      point(0.18, 0.28).dx,
      point(0.18, 0.28).dy,
    );
    path.cubicTo(
      point(0.17, 0.42).dx,
      point(0.17, 0.42).dy,
      point(0.23, 0.51).dx,
      point(0.23, 0.51).dy,
      point(0.24, 0.70).dx,
      point(0.24, 0.70).dy,
    );
    path.cubicTo(
      point(0.23, 0.88).dx,
      point(0.23, 0.88).dy,
      point(0.33, 0.98).dx,
      point(0.33, 0.98).dy,
      point(0.50, 0.99).dx,
      point(0.50, 0.99).dy,
    );
    path.cubicTo(
      point(0.67, 0.98).dx,
      point(0.67, 0.98).dy,
      point(0.77, 0.88).dx,
      point(0.77, 0.88).dy,
      point(0.76, 0.70).dx,
      point(0.76, 0.70).dy,
    );
    path.cubicTo(
      point(0.77, 0.51).dx,
      point(0.77, 0.51).dy,
      point(0.83, 0.42).dx,
      point(0.83, 0.42).dy,
      point(0.82, 0.28).dx,
      point(0.82, 0.28).dy,
    );
    path.cubicTo(
      point(0.80, 0.10).dx,
      point(0.80, 0.10).dy,
      point(0.71, 0.02).dx,
      point(0.71, 0.02).dy,
      point(0.50, 0.02).dx,
      point(0.50, 0.02).dy,
    );
    return path..close();
  }

  void _drawSections(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF92A9AE).withValues(alpha: 0.45);
    canvas.drawLine(
      Offset(size.width * 0.18, size.height * 0.38),
      Offset(size.width * 0.82, size.height * 0.38),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 0.23, size.height * 0.71),
      Offset(size.width * 0.77, size.height * 0.71),
      paint,
    );
  }

  Offset _pressurePosition(Size size, int index) {
    const left = <Offset>[
      Offset(0.50, 0.14),
      Offset(0.31, 0.30),
      Offset(0.50, 0.37),
      Offset(0.69, 0.38),
      Offset(0.50, 0.62),
      Offset(0.50, 0.84),
    ];
    final position = left[index];
    final x = _isLeft ? position.dx : 1 - position.dx;
    return Offset(x * size.width, position.dy * size.height);
  }

  Offset _temperaturePosition(Size size, int index) {
    const left = <Offset>[
      // Coordinates measured proportionally from the approved insole diagram.
      // T1: forefoot lateral
      // T2: hallux / first metatarsal head adjacent
      // T3: heel centre
      // T4: central midfoot
      // The right foot mirrors these x coordinates.
      Offset(0.290, 0.215),
      Offset(0.690, 0.158),
      Offset(0.505, 0.842),
      Offset(0.440, 0.520),
    ];
    final position = left[index];
    final x = _isLeft ? position.dx : 1 - position.dx;
    return Offset(x * size.width, position.dy * size.height);
  }

  void _drawPressureArea(
    Canvas canvas,
    Size size,
    int index,
    double intensityScore,
    double riskScore,
    bool valid,
  ) {
    final center = _pressurePosition(size, index);
    final radiusX = size.width * (index <= 3 ? 0.31 : 0.28);
    final radiusY = size.height * (index <= 3 ? 0.15 : 0.14);
    final color = valid ? _heatColor(intensityScore) : const Color(0xFF9BA9AC);
    final intensity = valid ? 0.18 + intensityScore * 0.75 : 0.32;
    final area = Rect.fromCenter(
      center: center,
      width: radiusX * 2,
      height: radiusY * 2,
    );
    final shader = RadialGradient(
      colors: [
        color.withValues(alpha: intensity),
        color.withValues(alpha: intensity * 0.52),
        color.withValues(alpha: 0),
      ],
      stops: const [0, 0.52, 1],
    ).createShader(area);
    canvas.drawOval(area, Paint()..shader = shader);
    if (riskScore >= 0.25 && valid) {
      canvas.drawOval(
        area.deflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = riskScore >= 0.75 ? 3.2 : 2.2
          ..color = riskScore >= 0.75
              ? const Color(0xFFD62F2F)
              : const Color(0xFFE66D22),
      );
    }
  }

  Color _heatColor(double score) {
    if (score >= 0.75) return const Color(0xFFD62F2F);
    if (score >= 0.50) return const Color(0xFFF06A24);
    if (score >= 0.25) return const Color(0xFFF0C443);
    if (score >= 0.12) return const Color(0xFF62BD8E);
    return const Color(0xFF76C7D8);
  }

  void _drawTemperatureMarker(
    Canvas canvas,
    Size size,
    int index,
    double score,
  ) {
    final center = _temperaturePosition(size, index);
    final color =
        score >= 0.75 ? const Color(0xFFD62F2F) : const Color(0xFFC83C36);
    canvas.drawCircle(
        center, 11, Paint()..color = Colors.white.withValues(alpha: 0.92));
    canvas.drawCircle(
      center,
      11,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    canvas.drawLine(
      center.translate(0, -5),
      center.translate(0, 3),
      Paint()
        ..strokeWidth = 2.3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.drawCircle(center.translate(0, 5), 3.2, Paint()..color = color);

    final label = TextPainter(
      text: TextSpan(
        text: 'T${index + 1}',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(center.dx - label.width / 2, center.dy + 13),
    );
  }

  @override
  bool shouldRepaint(covariant _FootMapPainter oldDelegate) {
    return oldDelegate.side != side ||
        oldDelegate.pressureIntensity.toString() !=
            pressureIntensity.toString() ||
        oldDelegate.pressureRiskScores.toString() !=
            pressureRiskScores.toString() ||
        oldDelegate.pressureValid.toString() != pressureValid.toString() ||
        oldDelegate.temperatureScores.toString() !=
            temperatureScores.toString();
  }
}
