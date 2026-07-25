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
}
