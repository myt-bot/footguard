import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/config/app_config.dart';
import 'package:footguard/data/csv_replay_data_source.dart';
import 'package:footguard/data/foot_data_source.dart';
import 'package:footguard/data/mock_foot_data_source.dart';

void main() {
  test('settings switch data source without changing backend URL', () {
    const settings = AppSettings();
    final changed = settings.copyWith(dataMode: FootDataMode.csvReplay);
    expect(changed.dataMode, FootDataMode.csvReplay);
    expect(changed.backendUrl, settings.backendUrl);
  });

  test('mock source emits paired left and right frames', () async {
    final source = MockFootDataSource(scenario: 'normal_stand');
    final framesFuture = source.frames.take(2).toList();
    final connectionFuture = source.connectionState.first;
    await source.start();
    final frames = await framesFuture.timeout(const Duration(seconds: 1));
    final connection =
        await connectionFuture.timeout(const Duration(seconds: 1));
    expect(frames.map((frame) => frame.side).toSet(), {'left', 'right'});
    expect(frames[0].syncId, frames[1].syncId);
    expect(connection.left, FootConnectionStatus.connected);
    expect(connection.right, FootConnectionStatus.connected);
    await source.dispose();
  });

  test('CSV parser preserves chronological order', () {
    const csv =
        'protocol_version,sensor_layout_version,device_id,side,sync_id,packet_seq,timestamp_ms,p1,p2,p3,p4,p5,p6,t1,t2,t3,t4,ax,ay,az,gx,gy,gz,battery,quality_flags,source\n'
        '1,layout_6p4t_v1,foot_left_001,left,1,0,1000,0.1,0.1,0.1,0.1,0.1,0.1,30,30,30,30,0,0,9.8,0,0,0,95,0,csv_replay\n'
        '1,layout_6p4t_v1,foot_right_001,right,1,0,1020,0.1,0.1,0.1,0.1,0.1,0.1,30,30,30,30,0,0,9.8,0,0,0,93,0,csv_replay';
    final frames = CsvReplayDataSource.parseCsv(csv);
    expect(frames, hasLength(2));
    expect(frames.first.timestampMs, lessThan(frames.last.timestampMs));
  });
}
