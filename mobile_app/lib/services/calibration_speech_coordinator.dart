class CalibrationSpeechCoordinator {
  bool _active = false;
  final Set<String> _handledStages = {};

  bool get active => _active;

  void start() {
    _active = true;
    _handledStages.clear();
  }

  void cancel() {
    _active = false;
    _handledStages.clear();
  }

  bool take(String stage) {
    if (!_active || !_handledStages.add(stage)) return false;
    if (stage == 'complete') _active = false;
    return stage != 'standing_baseline';
  }
}
