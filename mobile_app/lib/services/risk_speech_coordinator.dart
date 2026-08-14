import '../models/risk_state.dart';

class RiskSpeechCoordinator {
  RiskSpeechCoordinator({this.rearmAfterMs = 5000});

  final int rearmAfterMs;
  final Set<String> _announced = {};
  final Map<String, int> _missingSince = {};

  List<RiskState> takeNew(List<RiskState> active, int nowMs) {
    final current = active.map(_signature).toSet();
    for (final signature in _announced.toList()) {
      if (current.contains(signature)) {
        _missingSince.remove(signature);
        continue;
      }
      final missingSince = _missingSince.putIfAbsent(signature, () => nowMs);
      if (nowMs - missingSince >= rearmAfterMs) {
        _announced.remove(signature);
        _missingSince.remove(signature);
      }
    }

    final newlyActionable = active
        .where((risk) => !_announced.contains(_signature(risk)))
        .toList(growable: false);
    _announced.addAll(newlyActionable.map(_signature));
    return newlyActionable;
  }

  void reset() {
    _announced.clear();
    _missingSince.clear();
  }

  static String _signature(RiskState risk) =>
      '${risk.riskType}:${risk.riskSide}';
}
