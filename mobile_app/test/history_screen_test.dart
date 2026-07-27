import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/screens/history_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('risk event parses before and after intervention values', () {
    final event = RiskEventRecord.fromJson({
      'event_id': 'evt_1_left',
      'risk_type': 'left_load_bias',
      'risk_side': 'left',
      'risk_level': 2,
      'started_at_ms': 1760000000000,
      'ended_at_ms': 1760000010000,
      'duration_ms': 10000,
      'before_load_diff': 0.40,
      'after_load_diff': 0.15,
      'intervention_action': 'motor_vibration',
      'effect_label': 'effective',
      'recovery_time_ms': 2500,
      'status': 'resolved',
    });

    expect(event.endedAtMs, 1760000010000);
    expect(event.hasLoadDiffComparison, isTrue);
    expect(event.loadDiffImprovementRatio, closeTo(0.625, 0.0001));
    expect(event.effectLabel, 'effective');
    expect(event.recoveryTimeMs, 2500);
  });

  testWidgets('history shows risk timeline and recovery comparison',
      (tester) async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v1/events');
      return http.Response.bytes(
        utf8.encode(jsonEncode([
          {
            'event_id': 'evt_1_left',
            'risk_type': 'left_load_bias',
            'risk_side': 'left',
            'risk_level': 2,
            'started_at_ms': 1760000000000,
            'ended_at_ms': 1760000010000,
            'duration_ms': 10000,
            'before_load_diff': 0.40,
            'after_load_diff': 0.15,
            'intervention_action': 'motor_vibration',
            'effect_label': 'effective',
            'recovery_time_ms': 2500,
            'status': 'resolved',
          },
          {
            'event_id': 'evt_2_right',
            'risk_type': 'temperature_asymmetry',
            'risk_side': 'right',
            'risk_level': 3,
            'started_at_ms': 1760000020000,
            'ended_at_ms': null,
            'duration_ms': 12000,
            'before_load_diff': 0.20,
            'after_load_diff': null,
            'status': 'active',
          },
        ])),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = FootGuardApiClient(
      baseUrl: 'http://example.test',
      client: client,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HistoryScreen(
            backendUrl: 'http://example.test',
            apiClient: api,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('历史风险记录'), findsOneWidget);
    expect(find.text('2 条'), findsNWidgets(2));
    expect(find.text('左脚负载持续偏高'), findsOneWidget);
    expect(find.text('同区温差异常'), findsOneWidget);
    expect(find.text('已恢复'), findsOneWidget);
    expect(find.text('进行中'), findsWidgets);

    await tester.tap(find.text('左脚负载持续偏高'));
    await tester.pumpAndSettle();

    expect(find.text('干预后评估：明显改善'), findsOneWidget);
    expect(find.textContaining('40.0% → 15.0%'), findsOneWidget);
    expect(find.textContaining('改善 63%'), findsOneWidget);
    expect(find.textContaining('恢复用时 2.5 秒'), findsOneWidget);
    expect(find.textContaining('马达提醒后调整姿势'), findsOneWidget);
  });

  testWidgets('history derives load-bias result from displayed values',
      (tester) async {
    final client = MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'event_id': 'evt_inconsistent',
              'risk_type': 'right_load_bias',
              'risk_side': 'right',
              'risk_level': 3,
              'started_at_ms': 1760000000000,
              'ended_at_ms': 1760000010000,
              'duration_ms': 10000,
              'before_load_diff': 0.65,
              'after_load_diff': 0.70,
              'intervention_action': 'motor_vibration',
              'effect_label': 'effective',
              'recovery_time_ms': 2500,
              'status': 'resolved',
            },
          ])),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
    final api =
        FootGuardApiClient(baseUrl: 'http://example.test', client: client);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HistoryScreen(
          backendUrl: 'http://example.test',
          apiClient: api,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('右脚负载持续偏高'));
    await tester.pumpAndSettle();

    expect(find.text('干预后评估：未见明显改善'), findsOneWidget);
    expect(find.textContaining('65.0% → 70.0%'), findsOneWidget);
    expect(find.textContaining('增加 8%'), findsOneWidget);
  });

  testWidgets('temperature event does not claim load-bias improvement',
      (tester) async {
    final client = MockClient((request) async => http.Response.bytes(
          utf8.encode(jsonEncode([
            {
              'event_id': 'evt_temperature',
              'risk_type': 'temperature_asymmetry',
              'risk_side': 'left',
              'risk_level': 2,
              'started_at_ms': 1760000000000,
              'ended_at_ms': 1760000010000,
              'duration_ms': 10000,
              'before_load_diff': 0.90,
              'after_load_diff': 0.10,
              'intervention_action': 'motor_vibration',
              'effect_label': 'effective',
              'recovery_time_ms': 2500,
              'status': 'resolved',
            },
          ])),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ));
    final api =
        FootGuardApiClient(baseUrl: 'http://example.test', client: client);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HistoryScreen(
          backendUrl: 'http://example.test',
          apiClient: api,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同区温差异常'));
    await tester.pumpAndSettle();

    expect(find.text('事件已解除'), findsOneWidget);
    expect(find.textContaining('温差事件不能用左右负载差判定'), findsOneWidget);
    expect(find.textContaining('90.0% → 10.0%'), findsNothing);
    expect(find.textContaining('明显改善'), findsNothing);
  });
}
