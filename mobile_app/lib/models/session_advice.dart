class SessionAdvice {
  const SessionAdvice({
    required this.provider,
    required this.sessionStatus,
    required this.advice,
  });

  final String provider;
  final String sessionStatus;
  final String advice;

  bool get isHistorical => sessionStatus == 'recent';

  factory SessionAdvice.fromJson(Map<String, dynamic> json) => SessionAdvice(
        provider: json['provider'] as String,
        sessionStatus: json['session_status'] as String,
        advice: json['advice'] as String,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'session_status': sessionStatus,
        'advice': advice,
      };
}
