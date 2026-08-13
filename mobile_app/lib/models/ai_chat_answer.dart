class AiChatAnswer {
  const AiChatAnswer({
    required this.provider,
    required this.question,
    required this.answer,
  });

  final String provider;
  final String question;
  final String answer;

  bool get usedFallback => provider.contains('fallback');

  String get sourceLabel {
    if (usedFallback) return '本地安全降级回答';
    if (provider.contains('deepseek')) return 'DeepSeek 云端回答';
    return provider;
  }

  factory AiChatAnswer.fromJson(Map<String, dynamic> json) => AiChatAnswer(
        provider: json['provider'] as String,
        question: json['question'] as String,
        answer: json['answer'] as String,
      );
}
