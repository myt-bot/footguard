import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/config/app_config.dart';
import 'package:footguard/data/api_client.dart';
import 'package:footguard/screens/settings_screen.dart';

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
  testWidgets('settings display mock scenarios in Chinese', (tester) async {
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

    expect(find.text('模拟场景'), findsOneWidget);
    expect(find.text('正常站立'), findsWidgets);
    expect(find.textContaining('双脚稳定承重'), findsOneWidget);
    expect(find.text('normal_stand'), findsNothing);

    await tester.tap(find.text('正常站立').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('左脚持续偏载').last);
    await tester.pumpAndSettle();
    await _scrollUntilVisible(tester, find.text('应用设置'));
    await tester.tap(find.text('应用设置'));
    await tester.pump();

    expect(applied?.mockScenario, 'left_load_bias');
  });

  testWidgets('CSV mode exposes dataset and replay speed controls',
      (tester) async {
    AppSettings? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(dataMode: FootDataMode.csvReplay),
            onChanged: (settings) => applied = settings,
          ),
        ),
      ),
    );

    expect(find.text('CSV 回放数据'), findsOneWidget);
    expect(find.text('提醒前后恢复演示'), findsOneWidget);
    expect(find.text('CSV 回放速度'), findsOneWidget);
    expect(find.text('模拟场景'), findsNothing);

    await tester.tap(find.text('提醒前后恢复演示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正常行走').last);
    await tester.pumpAndSettle();
    await _scrollUntilVisible(tester, find.text('应用设置'));
    await tester.tap(find.text('应用设置'));
    await tester.pump();

    expect(applied?.csvAsset, 'assets/sample_data/normal_walk.csv');
  });

  testWidgets('backend address can be validated before applying settings',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) {},
            healthCheck: (baseUrl) async => baseUrl == 'http://10.0.2.2:8000',
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('检测连接'));
    await tester.pumpAndSettle();

    expect(find.text('后端连接正常'), findsOneWidget);
  });

  testWidgets('invalid backend address is not applied', (tester) async {
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

    await tester.enterText(
      find.byType(TextField),
      '192.168.1.10:8000',
    );
    await _scrollUntilVisible(tester, find.text('应用设置'));
    await tester.tap(find.text('应用设置'));
    await tester.pump();

    expect(applied, isNull);
    await _scrollUntilVisible(
      tester,
      find.byKey(const ValueKey('backend-status')),
      delta: -300,
    );
    expect(
      find.text('请输入以 http:// 或 https:// 开头的完整地址'),
      findsOneWidget,
    );
  });

  testWidgets('baseline status is visible and reset requires confirmation',
      (tester) async {
    var resetCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            settings: const AppSettings(),
            onChanged: (_) {},
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
    expect(find.textContaining('学习中：0/40'), findsOneWidget);
  });
}
