class AiAdvice {
  const AiAdvice({
    required this.provider,
    required this.riskLevel,
    required this.explanation,
    required this.advice,
    required this.target,
    required this.candidatePattern,
  });

  final String provider;
  final int riskLevel;
  final String explanation;
  final String advice;
  final String target;
  final String candidatePattern;

  factory AiAdvice.fromJson(Map<String, dynamic> json) => AiAdvice(
        provider: json['provider'] as String,
        riskLevel: json['risk_level'] as int,
        explanation: json['explanation'] as String,
        advice: json['advice'] as String,
        target: json['target'] as String,
        candidatePattern: json['candidate_pattern'] as String,
      );

  bool get usedFallback => provider.contains('fallback');

  String get sourceLabel {
    if (usedFallback) {
      return '本地安全降级解释';
    }
    if (provider.contains('deepseek')) {
      return 'DeepSeek 云端解释';
    }
    return provider;
  }
}
