import 'package:flutter/material.dart';

import '../models/ai_advice.dart';

class AiAdviceCard extends StatelessWidget {
  const AiAdviceCard({
    super.key,
    required this.advice,
    required this.status,
    required this.loading,
  });

  final AiAdvice? advice;
  final String status;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final value = advice;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.auto_awesome_outlined)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 风险解释（辅助）',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '规则负责判定与提醒，AI 仅解释结果',
                        style: TextStyle(
                          color: Color(0xFF718096),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (value == null)
              Text(status)
            else ...[
              Text(
                value.sourceLabel,
                style: const TextStyle(
                  color: Color(0xFF087F72),
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                value.provider,
                style: const TextStyle(
                  color: Color(0xFF718096),
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 8),
              Text(value.explanation),
              const SizedBox(height: 10),
              const Text(
                '建议',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(value.advice),
              const SizedBox(height: 10),
              const Text(
                '仅用于竞赛原型的辅助解释，不构成医疗诊断或治疗建议。',
                style: TextStyle(
                  color: Color(0xFF718096),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
