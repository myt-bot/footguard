import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/ai_advice.dart';
import 'package:footguard/models/ai_question_answer.dart';
import 'package:footguard/models/foot_frame.dart';
import 'package:footguard/models/risk_state.dart';
import 'package:footguard/screens/home_screen.dart';
import 'package:footguard/widgets/ai_advice_card.dart';
import 'package:footguard/widgets/foot_pressure_view.dart';
import 'package:footguard/widgets/risk_banner.dart';

void main() {
  testWidgets('home shows project and motor reminder capability', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HomeScreen(onStartMonitoring: () {})),
      ),
    );
    expect(find.text('足安智垫'), findsOneWidget);
    expect(find.text('马达振动提醒'), findsOneWidget);
  });

  testWidgets('risk banner displays incomplete state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RiskBanner(risk: RiskState.incomplete())),
      ),
    );
    expect(find.text('双足数据不完整'), findsOneWidget);
  });

  testWidgets('risk banner displays left load warning', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RiskBanner(
            risk: RiskState(
              riskType: 'left_load_bias',
              riskSide: 'left',
              riskLevel: 2,
              durationMs: 6500,
            ),
          ),
        ),
      ),
    );
    expect(find.text('双足负载分配异常'), findsOneWidget);
    expect(find.textContaining('需要减负'), findsOneWidget);
  });

  testWidgets(
    'risk banner prioritizes local pressure and separates temperature',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RiskBanner(
              risk: RiskState(
                riskType: 'left_load_bias',
                riskSide: 'left',
                riskLevel: 2,
                durationMs: 12000,
              ),
              activeRisks: [
                RiskState(
                  riskType: 'left_load_bias',
                  riskSide: 'left',
                  riskLevel: 2,
                  durationMs: 12000,
                ),
                RiskState(
                  riskType: 'medial_load_concentration',
                  riskSide: 'left',
                  riskLevel: 2,
                  durationMs: 11000,
                ),
                RiskState(
                  riskType: 'temperature_asymmetry',
                  riskSide: 'right',
                  riskLevel: 2,
                  durationMs: 16000,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('左脚内侧局部负荷集中'), findsOneWidget);
      expect(find.text('同时存在'), findsOneWidget);
      expect(find.text('左侧负载持续偏高'), findsOneWidget);
      expect(find.text('右脚同区温度趋势异常'), findsOneWidget);
      expect(find.textContaining('不计入15秒压力改善'), findsOneWidget);
    },
  );

  testWidgets('unknown string risk uses a safe generic label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RiskBanner(
            risk: RiskState(
              riskType: 'future_pressure_region',
              riskSide: 'both',
              riskLevel: 2,
              durationMs: 10000,
            ),
          ),
        ),
      ),
    );

    expect(find.text('双脚区域负荷集中'), findsOneWidget);
  });

  testWidgets('risk banner distinguishes missing load from normal posture', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RiskBanner(
            risk: RiskState(
              riskType: 'normal',
              riskSide: 'none',
              riskLevel: 0,
              durationMs: 0,
            ),
            pressureAvailable: false,
          ),
        ),
      ),
    );

    expect(find.text('未检测到有效承重'), findsOneWidget);
    expect(find.text('双足状态正常'), findsNothing);
  });

  testWidgets(
    'AI advice card identifies DeepSeek as an auxiliary explanation',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AiAdviceCard(
              advice: AiAdvice(
                provider: 'openai-compatible:deepseek-v4-flash',
                riskLevel: 2,
                explanation: '左脚负荷持续偏高。',
                advice: '请短暂减轻左脚负荷并检查足部皮肤。',
                target: 'left',
                candidatePattern: 'double',
              ),
              status: '辅助解释已更新',
              loading: false,
            ),
          ),
        ),
      );

      expect(find.text('AI 状态助手（辅助）'), findsOneWidget);
      expect(find.text('DeepSeek 云端解释'), findsOneWidget);
      expect(find.text('左脚负荷持续偏高。'), findsOneWidget);
      expect(find.textContaining('不构成医疗诊断'), findsOneWidget);
      expect(find.text('为什么出现风险？'), findsOneWidget);
      expect(find.text('现在怎么做？'), findsOneWidget);
      expect(find.text('怎样判断改善？'), findsOneWidget);
      expect(find.text('何时进一步检查？'), findsOneWidget);
    },
  );

  testWidgets('AI advice card shows the selected fixed-question answer', (
    tester,
  ) async {
    String? selectedKey;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAdviceCard(
            advice: null,
            status: '当前状态正常',
            loading: false,
            questionAnswer: const AiQuestionAnswer(
              provider: 'openai-compatible:deepseek-v4-flash',
              questionKey: 'improvement_check',
              question: '怎样判断已经改善？',
              answer: '观察异常区域压力和左右负载差是否持续回落。',
            ),
            onQuestionSelected: (key) async {
              selectedKey = key;
            },
          ),
        ),
      ),
    );

    expect(find.text('怎样判断已经改善？'), findsOneWidget);
    expect(find.textContaining('左右负载差'), findsOneWidget);
    expect(find.text('DeepSeek 云端回答'), findsOneWidget);

    await tester.tap(find.text('现在怎么做？'));
    expect(selectedKey, 'immediate_action');
  });

  testWidgets('pressure view names the abnormal anatomical regions', (
    tester,
  ) async {
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 1,
      packetSeq: 1,
      timestampMs: 1760000000000,
      pressure: [0.82, 0.63, 0.51, 0.30, 0.40, 0.28],
      temperature: [30.7, 30.8, 30.4, 30.6],
      imu: ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
      battery: 95,
      qualityFlags: 0,
      source: 'mock',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FootPressureView(
              side: 'left',
              frame: frame,
              pressureScores: [0.82, 0.63, 0.51, 0.30, 0.40, 0.28],
              temperatureScores: [0.1, 0.8, 0.0, 0.2],
              temperatureDeltaC: [0.1, 2.4, 0.0, 0.3],
              baselineReady: true,
              showPressureAbnormality: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('左脚压力与温度分布'), findsOneWidget);
    expect(find.text('区域变化高'), findsOneWidget);
    expect(find.textContaining('拇趾区'), findsOneWidget);
    expect(find.textContaining('前掌外侧'), findsWidgets);
    expect(find.text('T1 前掌外侧'), findsOneWidget);
    expect(find.text('T2 拇趾/第一跖骨头邻近'), findsOneWidget);
    expect(find.text('T4 中足中央'), findsOneWidget);
    expect(find.textContaining('P1'), findsNothing);
  });

  testWidgets('pressure view treats tiny unloaded readings as no contact', (
    tester,
  ) async {
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 1,
      packetSeq: 1,
      timestampMs: 1760000000000,
      pressure: [0.0005, 0, 0, 0, 0, 0],
      temperature: [30, 30, 30, 30],
      imu: ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
      battery: 95,
      qualityFlags: 0,
      source: 'ble',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FootPressureView(side: 'left', frame: frame),
          ),
        ),
      ),
    );

    expect(find.text('当前未承重或受力过低'), findsOneWidget);
    expect(find.text('未承重'), findsOneWidget);
    expect(find.textContaining('相对异常区域'), findsNothing);
  });

  testWidgets('unloaded frame ignores stale backend pressure scores', (
    tester,
  ) async {
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 1,
      packetSeq: 2,
      timestampMs: 1760000000200,
      pressure: [0, 0, 0, 0, 0, 0],
      temperature: [30, 30, 30, 30],
      imu: ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
      battery: 95,
      qualityFlags: 0,
      source: 'ble',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FootPressureView(
              side: 'left',
              frame: frame,
              pressureScores: [1, 1, 1, 1, 1, 1],
              baselineReady: true,
              showPressureAbnormality: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('未承重'), findsOneWidget);
    expect(find.text('当前未承重或受力过低'), findsOneWidget);
    expect(find.textContaining('占比 0.0%'), findsNothing);
    expect(find.textContaining('异常程度 100%'), findsNothing);
  });

  testWidgets('single high residual pressure point is treated as unloaded', (
    tester,
  ) async {
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_right_001',
      side: 'right',
      syncId: 1,
      packetSeq: 3,
      timestampMs: 1760000000400,
      pressure: [0, 0, 0.12, 0, 0, 0],
      temperature: [30, 30, 30, 30],
      imu: ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
      battery: 95,
      qualityFlags: 0,
      source: 'ble',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FootPressureView(
              side: 'right',
              frame: frame,
              pressureScores: [0, 0, 1, 0, 0, 0],
              baselineReady: true,
              showPressureAbnormality: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('未承重'), findsOneWidget);
    expect(find.text('当前未承重或受力过低'), findsOneWidget);
    expect(find.textContaining('相对异常区域'), findsNothing);
  });

  testWidgets('valid pressure regions stay visible when other channels fail', (
    tester,
  ) async {
    const frame = FootFrame(
      protocolVersion: 1,
      sensorLayoutVersion: 'layout_6p4t_v1',
      deviceId: 'foot_left_001',
      side: 'left',
      syncId: 1,
      packetSeq: 3,
      timestampMs: 1760000000400,
      pressure: [0.72, 0.41, 0.20, 0, 0, 0],
      temperature: [0, 0, 0, 0],
      imu: ImuData(ax: 0, ay: 0, az: 1, gx: 0, gy: 0, gz: 0),
      battery: 95,
      qualityFlags: 0x3f8,
      source: 'ble',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FootPressureView(side: 'left', frame: frame),
          ),
        ),
      ),
    );

    expect(find.text('压力不可用'), findsOneWidget);
    expect(find.textContaining('3 个压力点数据不可用'), findsOneWidget);
    expect(find.text('当前未承重或受力过低'), findsNothing);
    expect(find.text('温度不可用'), findsOneWidget);
  });
}
