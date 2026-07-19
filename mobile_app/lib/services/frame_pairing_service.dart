import '../models/foot_frame.dart';

class FramePairingService {
  FootFrame? _left;
  FootFrame? _right;

  List<FootFrame>? add(FootFrame frame) {
    if (frame.side == 'left') {
      _left = frame;
    } else {
      _right = frame;
    }
    final left = _left;
    final right = _right;
    if (left == null || right == null) {
      return null;
    }
    if (left.syncId != right.syncId || left.packetSeq != right.packetSeq) {
      return null;
    }
    if ((left.timestampMs - right.timestampMs).abs() > 50) {
      return null;
    }
    _left = null;
    _right = null;
    return [left, right];
  }
}
