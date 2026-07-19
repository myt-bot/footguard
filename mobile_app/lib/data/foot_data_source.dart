import '../models/foot_frame.dart';

enum FootConnectionStatus { disconnected, connecting, connected, error }

class FootConnectionSnapshot {
  const FootConnectionSnapshot({required this.left, required this.right});

  const FootConnectionSnapshot.disconnected()
      : left = FootConnectionStatus.disconnected,
        right = FootConnectionStatus.disconnected;

  final FootConnectionStatus left;
  final FootConnectionStatus right;
}

abstract class FootDataSource {
  Stream<FootFrame> get frames;
  Stream<FootConnectionSnapshot> get connectionState;
  Stream<String?> get errorState;
  String get label;
  bool get shouldUploadToBackend;

  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}
