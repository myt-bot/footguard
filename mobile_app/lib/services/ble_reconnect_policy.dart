class BleReconnectPolicy {
  const BleReconnectPolicy({
    this.initialDelay = const Duration(seconds: 2),
    this.maximumDelay = const Duration(seconds: 30),
  });

  final Duration initialDelay;
  final Duration maximumDelay;

  Duration delayForAttempt(int attempt) {
    final safeAttempt = attempt < 1 ? 1 : attempt;
    final exponent = (safeAttempt - 1).clamp(0, 20).toInt();
    final multiplier = 1 << exponent;
    final milliseconds = initialDelay.inMilliseconds * multiplier;
    return Duration(
      milliseconds: milliseconds
          .clamp(
            initialDelay.inMilliseconds,
            maximumDelay.inMilliseconds,
          )
          .toInt(),
    );
  }
}
