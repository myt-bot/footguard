import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/models/risk_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('AI advice request posts structured rule result and parses UTF-8',
      () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/ai/advice');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['risk']['risk_type'], 'left_load_bias');
      expect(body['temperature_delta_max_c'], 2.6);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'protocol_version': 1,
          'provider': 'openai-compatible:deepseek-v4-flash',
          'risk_level': 2,
          'explanation': '左脚负荷持续偏高。',
          'advice': '请短暂减轻左脚负荷并检查足部皮肤。',
          'target': 'left',
          'candidate_pattern': 'double',
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: client,
    );

    final result = await api.aiAdvice(
      risk: const RiskState(
        riskType: 'left_load_bias',
        riskSide: 'left',
        riskLevel: 2,
        durationMs: 6200,
      ),
      loadDiff: 0.31,
      temperatureDeltaMaxC: 2.6,
      baselineReady: true,
    );

    expect(result.sourceLabel, 'DeepSeek 云端解释');
    expect(result.explanation, '左脚负荷持续偏高。');
    expect(result.target, 'left');
    api.close();
  });

  test('fixed AI question posts an allow-listed key and parses the answer',
      () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/ai/question');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['question_key'], 'improvement_check');
      expect(body.containsKey('question'), isFalse);
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'protocol_version': 1,
          'provider': 'openai-compatible:deepseek-v4-flash',
          'question_key': 'improvement_check',
          'question': '怎样判断已经改善？',
          'answer': '观察负载差是否持续下降。',
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: client,
    );

    final result = await api.aiQuestion(
      questionKey: 'improvement_check',
      risk: const RiskState(
        riskType: 'left_load_bias',
        riskSide: 'left',
        riskLevel: 2,
        durationMs: 6200,
      ),
      loadDiff: 0.31,
      temperatureDeltaMaxC: 1.2,
      baselineReady: true,
    );

    expect(result.sourceLabel, 'DeepSeek 云端回答');
    expect(result.question, '怎样判断已经改善？');
    expect(result.answer, '观察负载差是否持续下降。');
    api.close();
  });

  test('calibration status can be read and reset', () async {
    var resetRequested = false;
    final client = MockClient((request) async {
      if (request.url.path == '/api/v1/calibration/reset') {
        expect(request.method, 'POST');
        resetRequested = true;
        return http.Response(
          jsonEncode({
            'baseline_ready': false,
            'sample_count': 0,
            'required_samples': 15,
            'reset_at_ms': 1785000000000,
          }),
          200,
        );
      }
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/calibration/status');
      return http.Response(
        jsonEncode({
          'baseline_ready': true,
          'sample_count': 15,
          'required_samples': 15,
          'reset_at_ms': null,
        }),
        200,
      );
    });
    final api = FootGuardApiClient(
      baseUrl: 'http://footguard.test',
      client: client,
    );

    final status = await api.calibrationStatus();
    expect(status.baselineReady, isTrue);
    expect(status.progress, 1);

    final reset = await api.resetCalibration();
    expect(resetRequested, isTrue);
    expect(reset.baselineReady, isFalse);
    expect(reset.sampleCount, 0);
    api.close();
  });
}
