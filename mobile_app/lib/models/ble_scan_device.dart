enum FootSide { left, right }

class BleScanDevice {
  const BleScanDevice({
    required this.remoteId,
    required this.name,
    required this.side,
    required this.rssi,
  });

  final String remoteId;
  final String name;
  final FootSide side;
  final int rssi;

  String get sideName => side == FootSide.left ? 'left' : 'right';
}

class BleScanSnapshot {
  const BleScanSnapshot({
    required this.isScanning,
    this.left,
    this.right,
  });

  const BleScanSnapshot.empty()
      : isScanning = false,
        left = null,
        right = null;

  final bool isScanning;
  final BleScanDevice? left;
  final BleScanDevice? right;

  bool get bothFound => left != null && right != null;

  BleScanSnapshot copyWith({
    bool? isScanning,
    BleScanDevice? left,
    BleScanDevice? right,
  }) =>
      BleScanSnapshot(
        isScanning: isScanning ?? this.isScanning,
        left: left ?? this.left,
        right: right ?? this.right,
      );
}
