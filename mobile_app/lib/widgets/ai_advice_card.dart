import 'package:flutter/material.dart';

import '../models/ai_advice.dart';
import '../models/ai_chat_answer.dart';
import '../models/ai_question_answer.dart';

class AiAdviceCard extends StatefulWidget {
  const AiAdviceCard({
    super.key,
    required this.advice,
    required this.status,
    required this.loading,
    this.questionAnswer,
    this.questionStatus = '请选择一个常见问题',
    this.questionLoading = false,
    this.onQuestionSelected,
    this.chatAnswer,
    this.chatLoading = false,
    this.chatStatus = '可询问当前状态、设备检查或日常观察建议',
    this.onChatSubmitted,
  });

  final AiAdvice? advice;
  final String status;
  final bool loading;
  final AiQuestionAnswer? questionAnswer;
  final String questionStatus;
  final bool questionLoading;
  final Future<void> Function(String questionKey)? onQuestionSelected;
  final AiChatAnswer? chatAnswer;
  final bool chatLoading;
  final String chatStatus;
  final Future<void> Function(String question)? onChatSubmitted;

  @override
  State<AiAdviceCard> createState() => _AiAdviceCardState();
}

class _AiAdviceCardState extends State<AiAdviceCard> {
  final TextEditingController _chat = TextEditingController();

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.advice;
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
                        'AI 状态助手（辅助）',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '结合压力、温度、设备与本次穿戴状态回答',
                        style: TextStyle(
                          color: Color(0xFF718096),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (value == null)
              Text(widget.status)
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
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            const Text(
              '常见问题',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              '选择问题后，AI 会结合当前双足监测结果回答。',
              style: TextStyle(
                color: Color(0xFF718096),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final question in _questions)
                  ActionChip(
                    avatar: Icon(question.icon, size: 18),
                    label: Text(question.label),
                    onPressed: widget.questionLoading ||
                            widget.onQuestionSelected == null
                        ? null
                        : () {
                            widget.onQuestionSelected!(question.key);
                          },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.questionLoading)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在生成回答…'),
                ],
              )
            else if (widget.questionAnswer != null)
              _QuestionAnswerPanel(answer: widget.questionAnswer!)
            else
              Text(
                widget.questionStatus,
                style: const TextStyle(color: Color(0xFF718096)),
              ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 14),
            const Text('自由提问', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            TextField(
              controller: _chat,
              maxLength: 120,
              minLines: 1,
              maxLines: 3,
              enabled: !widget.chatLoading,
              decoration: InputDecoration(
                hintText: '询问当前压力、温度、设备或日常观察建议',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: '发送问题',
                  icon: widget.chatLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded),
                  onPressed:
                      widget.chatLoading || widget.onChatSubmitted == null
                          ? null
                          : () => widget.onChatSubmitted!(_chat.text),
                ),
              ),
              onSubmitted: widget.chatLoading || widget.onChatSubmitted == null
                  ? null
                  : widget.onChatSubmitted,
            ),
            if (widget.chatAnswer != null)
              _ChatAnswerPanel(answer: widget.chatAnswer!)
            else
              Text(
                widget.chatStatus,
                style: const TextStyle(
                  color: Color(0xFF718096),
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatAnswerPanel extends StatelessWidget {
  const _ChatAnswerPanel({required this.answer});
  final AiChatAnswer answer;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF7F5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(answer.question,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(answer.answer),
            const SizedBox(height: 8),
            Text(answer.sourceLabel,
                style: const TextStyle(
                    color: Color(0xFF087F72),
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _QuestionAnswerPanel extends StatelessWidget {
  const _QuestionAnswerPanel({required this.answer});

  final AiQuestionAnswer answer;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF7F5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              answer.question,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(answer.answer),
            const SizedBox(height: 8),
            Text(
              answer.sourceLabel,
              style: const TextStyle(
                color: Color(0xFF087F72),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
}

class _QuestionOption {
  const _QuestionOption(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

const _questions = [
  _QuestionOption(
    'risk_reason',
    '为什么出现风险？',
    Icons.help_outline_rounded,
  ),
  _QuestionOption(
    'immediate_action',
    '现在怎么做？',
    Icons.directions_walk_rounded,
  ),
  _QuestionOption(
    'improvement_check',
    '怎样判断改善？',
    Icons.trending_down_rounded,
  ),
  _QuestionOption(
    'when_to_seek_help',
    '何时进一步检查？',
    Icons.health_and_safety_outlined,
  ),
];
