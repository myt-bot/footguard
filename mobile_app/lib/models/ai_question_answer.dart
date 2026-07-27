class AiQuestionAnswer {
  const AiQuestionAnswer({
    required this.provider,
    required this.questionKey,
    required this.question,
    required this.answer,
  });

  final String provider;
  final String questionKey;
  final String question;
  final String answer;

  factory AiQuestionAnswer.fromJson(Map<String, dynamic> json) =>
      AiQuestionAnswer(
        provider: json['provider'] as String,
        questionKey: json['question_key'] as String,
        question: json['question'] as String,
        answer: json['answer'] as String,
      );

  bool get usedFallback => provider.contains('fallback');

  String get sourceLabel {
    if (usedFallback) {
      return '本地安全降级回答';
    }
    if (provider.contains('deepseek')) {
      return 'DeepSeek 云端回答';
    }
    return provider;
  }
}
