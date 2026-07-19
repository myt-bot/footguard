import 'dart:async';

import 'package:flutter/services.dart';

import '../models/foot_frame.dart';
import 'foot_data_source.dart';

class CsvReplayDataSource implements FootDataSource {
  CsvReplayDataSource({required this.assetPath, this.speed = 1.0});

  final String assetPath;
  final double speed;
  final _frames = StreamController<FootFrame>.broadcast();
  final _connections = StreamController<FootConnectionSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  Timer? _timer;
  List<FootFrame> _data = const [];
  int _index = 0;

  @override
  Stream<FootFrame> get frames => _frames.stream;
  @override
  Stream<FootConnectionSnapshot> get connectionState => _connections.stream;
  @override
  Stream<String?> get errorState => _errors.stream;
  @override
  String get label => 'CSV 回放';
  @override
  bool get shouldUploadToBackend => true;

  @override
  Future<void> start() async {
    try {
      _data = parseCsv(await rootBundle.loadString(assetPath));
      _index = 0;
      _connections.add(const FootConnectionSnapshot(
        left: FootConnectionStatus.connected,
        right: FootConnectionStatus.connected,
      ));
      final interval = Duration(milliseconds: maxOf(20, (100 / speed).round()));
      _timer = Timer.periodic(interval, (_) => _emit());
    } catch (error) {
      _errors.add('CSV 加载失败：$error');
      _connections.add(const FootConnectionSnapshot(
        left: FootConnectionStatus.error,
        right: FootConnectionStatus.error,
      ));
    }
  }

  static int maxOf(int first, int second) => first > second ? first : second;

  void _emit() {
    if (_index >= _data.length) {
      _timer?.cancel();
      return;
    }
    _frames.add(_data[_index++]);
  }

  static List<FootFrame> parseCsv(String text) {
    final lines = text.trim().split(RegExp(r'\r?\n'));
    if (lines.length < 2) {
      throw const FormatException('CSV has no data');
    }
    final headers = lines.first.split(',');
    return lines.skip(1).where((line) => line.trim().isNotEmpty).map((line) {
      final values = line.split(',');
      if (values.length != headers.length) {
        throw const FormatException('invalid CSV row');
      }
      final row = <String, String>{
        for (var index = 0; index < headers.length; index++)
          headers[index]: values[index],
      };
      double number(String key) => double.parse(row[key]!);
      int integer(String key) => int.parse(row[key]!);
      return FootFrame(
        protocolVersion: integer('protocol_version'),
        sensorLayoutVersion: row['sensor_layout_version']!,
        deviceId: row['device_id']!,
        side: row['side']!,
        syncId: integer('sync_id'),
        packetSeq: integer('packet_seq'),
        timestampMs: integer('timestamp_ms'),
        pressure: [for (var i = 1; i <= 6; i++) number('p$i')],
        temperature: [for (var i = 1; i <= 4; i++) number('t$i')],
        imu: ImuData(
          ax: number('ax'),
          ay: number('ay'),
          az: number('az'),
          gx: number('gx'),
          gy: number('gy'),
          gz: number('gz'),
        ),
        battery: integer('battery'),
        qualityFlags: integer('quality_flags'),
        source: row['source']!,
      );
    }).toList(growable: false);
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _connections.add(const FootConnectionSnapshot.disconnected());
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _connections.close();
    await _errors.close();
  }
}
