import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/config/app_config.dart';
import 'package:footguard/screens/settings_screen.dart';

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
    await tester.ensureVisible(find.text('应用设置'));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(find.text('应用设置'));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(find.text('应用设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用设置'));
    await tester.pump();

    expect(applied, isNull);
    expect(
      find.text('请输入以 http:// 或 https:// 开头的完整地址'),
      findsOneWidget,
    );
  });
}
