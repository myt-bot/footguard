import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/config/app_config.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/screens/settings_screen.dart';
import 'package:footguard/services/local_tts_service.dart';

class _FakeTtsSpeaker implements TtsSpeaker {
  final spoken = <String>[];

  @override
  Future<bool> speak(String text) async {
    spoken.add(text);
    return true;
  }

  @override
  Future<void> stop() async {}
}

Future<void> _scrollUntilVisible(
  WidgetTester tester,
  Finder finder, {
  double delta = 300,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.scrollUntilVisible(
    finder,
    delta,
    scrollable: find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('release settings expose BLE mode without simulation controls', (
    tester,
  ) async {
    AppSettings? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (settings) => applied = settings,
          ),
        ),
      ),
    );

    expect(find.text('BLE 真机模式'), findsOneWidget);
    expect(find.text('数据源'), findsNothing);
    expect(find.text('模拟场景'), findsNothing);
    expect(find.text('CSV 回放数据'), findsNothing);
    expect(find.text('FastAPI 后端地址'), findsOneWidget);
    expect(find.text('语音提醒'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'http://192.168.1.6:8000/',
    );
    await _scrollUntilVisible(tester, find.text('应用设置'));
    await tester.tap(find.text('应用设置'));
    await tester.pump();

    expect(applied?.dataMode, FootDataMode.ble);
    expect(applied?.backendUrl, 'http://192.168.1.6:8000');
  });

  testWidgets('voice switch persists and test button uses local TTS', (
    tester,
  ) async {
    final speaker = _FakeTtsSpeaker();
    AppSettings? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (settings) => applied = settings,
            ttsSpeaker: speaker,
          ),
        ),
      ),
    );

    await tester.tap(find.text('测试中文语音'));
    await tester.pumpAndSettle();
    expect(speaker.spoken, ['语音提醒已开启。']);
    expect(find.text('中文语音测试成功'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(applied?.voiceEnabled, isFalse);
    expect(find.text('测试中文语音'), findsOneWidget);
  });

  testWidgets('baseline status is visible and reset requires confirmation', (
    tester,
  ) async {
    var resetCalls = 0;
    var resetNotifications = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) {},
            onCalibrationReset: () => resetNotifications += 1,
            calibrationStatusLoader: (_) async => const CalibrationStatus(
              baselineReady: true,
              sampleCount: 40,
              requiredSamples: 40,
            ),
            calibrationResetter: (_) async {
              resetCalls += 1;
              return const CalibrationStatus(
                baselineReady: false,
                sampleCount: 0,
                requiredSamples: 40,
                resetAtMs: 1785000000000,
              );
            },
          ),
        ),
      ),
    );

    await _scrollUntilVisible(tester, find.byTooltip('刷新基线状态'));
    await tester.tap(find.byTooltip('刷新基线状态'));
    await tester.pumpAndSettle();
    expect(find.text('本次穿戴基线已完成，压力风险与马达已启用'), findsOneWidget);

    await _scrollUntilVisible(tester, find.text('新体验者 / 重新穿戴'));
    await tester.tap(find.text('新体验者 / 重新穿戴'));
    await tester.pumpAndSettle();
    expect(find.text('重新学习个人基线？'), findsOneWidget);
    expect(resetCalls, 0);

    await tester.tap(find.text('确认重新校准'));
    await tester.pumpAndSettle();
    expect(resetCalls, 1);
    expect(resetNotifications, 1);
    expect(find.textContaining('学习中：0/40'), findsOneWidget);
  });
}
