import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../models/session_advice.dart';

class SessionAnalysisView extends StatelessWidget {
  const SessionAnalysisView({
    super.key,
    required this.points,
    required this.events,
    required this.advice,
    this.cached = false,
  });

  final List<AnalyticsFramePoint> points;
  final List<RiskEventRecord> events;
  final SessionAdvice? advice;
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final pairs = _paired(points);
    final recent =
        pairs.length <= 160 ? pairs : pairs.sublist(pairs.length - 160);
    final pressureFeedback = events
        .expand((event) => event.componentFeedback)
        .where((item) => item.pressureIntervention)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cached)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              '当前后端不可用，以下为最近一次缓存的会话分析。',
              style: TextStyle(color: Color(0xFFA86612)),
            ),
          ),
        _AdviceCard(advice: advice),
        const SizedBox(height: 12),
        _TrendCard(
          title: '左右总负载趋势',
          subtitle: '分别观察两脚相对负载变化，不把原始值当作绝对压力。',
          series: [
            _Series('左脚', const Color(0xFF0B8F83),
                recent.map((item) => item.left?.totalPressure).toList()),
            _Series('右脚', const Color(0xFFE47B35),
                recent.map((item) => item.right?.totalPressure).toList()),
          ],
        ),
        const SizedBox(height: 12),
        _TrendCard(
          title: '前掌负荷占比趋势',
          subtitle: '用于观察左、右或双脚前掌负荷是否相对本次穿戴持续集中。',
          percent: true,
          series: [
            _Series('左脚前掌', const Color(0xFF2877B8),
                recent.map((item) => item.left?.forefootRatio).toList()),
            _Series('右脚前掌', const Color(0xFFD05A78),
                recent.map((item) => item.right?.forefootRatio).toList()),
          ],
        ),
        const SizedBox(height: 12),
        _TrendCard(
          title: '同区温差趋势',
          subtitle: '显示左右对应温度区域的最大差值，仅用于趋势观察。',
          suffix: '℃',
          series: [
            _Series('最大同区温差', const Color(0xFFD25145),
                recent.map((item) => item.temperatureDeltaMax).toList()),
          ],
        ),
        const SizedBox(height: 12),
        _TimelineCard(events: events),
        const SizedBox(height: 12),
        _InterventionCard(feedback: pressureFeedback),
      ],
    );
  }

  static List<_PairPoint> _paired(List<AnalyticsFramePoint> rows) {
    final grouped = <String, _PairPoint>{};
    for (final row in rows) {
      final key = '${row.syncId}:${row.packetSeq}';
      final current = grouped[key] ?? _PairPoint(timestampMs: row.timestampMs);
      grouped[key] = row.side == 'left'
          ? current.copyWith(left: row)
          : current.copyWith(right: row);
    }
    final result = grouped.values
        .where((item) => item.left != null || item.right != null)
        .toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return result;
  }
}

class _PairPoint {
  const _PairPoint({required this.timestampMs, this.left, this.right});
  final int timestampMs;
  final AnalyticsFramePoint? left;
  final AnalyticsFramePoint? right;

  _PairPoint copyWith(
          {AnalyticsFramePoint? left, AnalyticsFramePoint? right}) =>
      _PairPoint(
        timestampMs: math.max(
          timestampMs,
          left?.timestampMs ?? right?.timestampMs ?? timestampMs,
        ),
        left: left ?? this.left,
        right: right ?? this.right,
      );

  double? get temperatureDeltaMax {
    if (left == null ||
        right == null ||
        left!.temperature.length != 4 ||
        right!.temperature.length != 4) {
      return null;
    }
    final deltas = List.generate(
      4,
      (index) => (left!.temperature[index] - right!.temperature[index]).abs(),
    ).where((value) => value.isFinite).toList(growable: false);
    return deltas.isEmpty ? null : deltas.reduce(math.max);
  }
}

class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.advice});
  final SessionAdvice? advice;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5F2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.auto_awesome_outlined, color: Color(0xFF147D73)),
              SizedBox(width: 8),
              Text('最近会话综合建议', style: TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            Text(advice?.advice ?? '暂无可用会话建议。完成一次穿戴监测后可在此查看。'),
            const SizedBox(height: 6),
            const Text('仅用于辅助观察，不替代医疗诊断。',
                style: TextStyle(fontSize: 11, color: Color(0xFF60706F))),
          ],
        ),
      );
}

class _Series {
  const _Series(this.label, this.color, this.values);
  final String label;
  final Color color;
  final List<double?> values;
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({
    required this.title,
    required this.subtitle,
    required this.series,
    this.percent = false,
    this.suffix = '',
  });
  final String title;
  final String subtitle;
  final List<_Series> series;
  final bool percent;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final all =
        series.expand((item) => item.values).whereType<double>().toList();
    final maximum = all.isEmpty ? 0.0 : all.reduce(math.max);
    final minimum = all.isEmpty ? 0.0 : all.reduce(math.min);
    String format(double value) => percent
        ? '${(value * 100).round()}%'
        : '${value.toStringAsFixed(suffix.isEmpty ? 2 : 1)}$suffix';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(subtitle,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6E7B7A))),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          children: series
              .map((item) => Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 3, color: item.color),
                    const SizedBox(width: 5),
                    Text(item.label, style: const TextStyle(fontSize: 11)),
                  ]))
              .toList(growable: false),
        ),
        const SizedBox(height: 8),
        if (all.isEmpty)
          const SizedBox(height: 120, child: Center(child: Text('暂无趋势数据')))
        else
          SizedBox(
            height: 130,
            child: CustomPaint(
              painter:
                  _TrendPainter(series: series, min: minimum, max: maximum),
              child: Align(
                alignment: Alignment.topRight,
                child: Text('${format(maximum)}  ',
                    style: const TextStyle(fontSize: 10)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(
      {required this.series, required this.min, required this.max});
  final List<_Series> series;
  final double min;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFFE5ECEB)
      ..strokeWidth = 1;
    for (var index = 0; index <= 3; index++) {
      final y = size.height * index / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final span = math.max(max - min, 1e-6);
    for (final item in series) {
      final path = Path();
      var started = false;
      for (var index = 0; index < item.values.length; index++) {
        final value = item.values[index];
        if (value == null) {
          started = false;
          continue;
        }
        final x = item.values.length <= 1
            ? 0.0
            : size.width * index / (item.values.length - 1);
        final y = size.height - ((value - min) / span) * size.height;
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = item.color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.min != min ||
      oldDelegate.max != max;
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.events});
  final List<RiskEventRecord> events;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('风险与干预时间线', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          if (events.isEmpty)
            const Text('本次会话暂无正式风险事件。')
          else
            for (final event in events.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.circle,
                          size: 10, color: Color(0xFF147D73)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_riskLabel(event.riskType, event.riskSide)} · '
                          '${event.interventionStartedAtMs == null ? '未执行马达' : '已执行马达并观察15秒'} · '
                          '${event.status == 'active' ? '进行中' : '已结束'}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ]),
              ),
        ]),
      );
}

class _InterventionCard extends StatelessWidget {
  const _InterventionCard({required this.feedback});
  final List<RiskComponentFeedbackRecord> feedback;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('压力干预前后变化', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (feedback.isEmpty)
            const Text('暂无完整的压力干预前后对比数据。')
          else
            for (final item in feedback.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                      child: Text(_riskLabel(item.riskType, item.riskSide))),
                  Text(_effectLabel(item.effectLabel),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (item.improvementRatio != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      item.improvementRatio! < 0
                          ? '偏离增加 ${(-item.improvementRatio! * 100).round()}%'
                          : '改善 ${(item.improvementRatio! * 100).round()}%',
                    ),
                  ],
                ]),
              ),
        ]),
      );
}

String _riskLabel(String type, String side) => switch (type) {
      'forefoot_high' =>
        side == 'both' ? '双脚前掌负荷集中' : '${side == 'left' ? '左脚' : '右脚'}前掌负荷集中',
      'left_load_bias' => '左侧负载持续偏高',
      'right_load_bias' => '右侧负载持续偏高',
      'medial_load_concentration' => '${side == 'left' ? '左脚' : '右脚'}内侧负荷集中',
      'lateral_load_concentration' => '${side == 'left' ? '左脚' : '右脚'}外侧负荷集中',
      'temperature_asymmetry' => '同区温度趋势异常',
      _ => '风险事件',
    };

String _effectLabel(String value) => switch (value) {
      'effective' => '明显改善',
      'partial' => '部分改善',
      'ineffective' => '未改善',
      'worsened' => '偏离增加',
      _ => '数据不足',
    };
