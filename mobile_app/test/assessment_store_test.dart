import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/models/assessment.dart';
import 'package:footguard/services/offline_monitoring_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('health profile and glucose remain queued until backend recovery',
      () async {
    final store = OfflineMonitoringStore();
    const profile = HealthProfile(
      ulcerOrAmputation: 'no',
      sensoryOrCirculationIssue: 'unknown',
    );
    const reading = GlucoseReading(
      value: 6.2,
      unit: 'mmol/L',
      context: 'fasting',
      measuredAtMs: 1785000000000,
    );

    await store.savePendingHealthProfile(profile);
    await store.savePendingGlucose([reading]);
    expect((await store.loadPendingHealthProfile())?.ulcerOrAmputation, 'no');
    expect((await store.loadPendingGlucose()).single.value, 6.2);

    await store.clearPendingHealthProfile();
    await store.clearPendingGlucose();
    expect(await store.loadPendingHealthProfile(), isNull);
    expect(await store.loadPendingGlucose(), isEmpty);
  });
}
