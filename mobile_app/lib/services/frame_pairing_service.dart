import '../models/foot_frame.dart';

class FramePairingService {
  static const _maxPendingKeys = 128;
  final Map<(int, int), Map<String, FootFrame>> _pending = {};

  List<FootFrame>? add(FootFrame frame) {
    final key = (frame.syncId, frame.packetSeq);
    final frames = _pending.putIfAbsent(key, () => {});
    frames[frame.side] = frame;
    while (_pending.length > _maxPendingKeys) {
      _pending.remove(_pending.keys.first);
    }

    final left = frames['left'];
    final right = frames['right'];
    if (left == null || right == null) {
      return null;
    }
    _pending.remove(key);
    if ((left.timestampMs - right.timestampMs).abs() > 50) {
      return null;
    }
    return [left, right];
  }
}
