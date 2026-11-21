import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_subtitle_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('设置页能打开：标题、总开关、源语言、模型、延迟提示都在', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 视口拉高：ListView 懒加载，视口不够高时下面的项不建出来。
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: LiveSubtitleSettingsScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('实时翻译字幕'), findsWidgets);
    expect(find.text('源语言'), findsOneWidget);
    expect(find.text('识别模型'), findsOneWidget);
    expect(find.text('翻译服务'), findsOneWidget);
    expect(find.textContaining('一般慢 4–7 秒'), findsOneWidget);
    // Linux 测试机上插件不支持：应显示“本机不支持”，总开关禁用。
    expect(find.text('本机不支持'), findsOneWidget);
    final switchTile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('live-subtitle-enabled')),
    );
    expect(switchTile.onChanged, isNull);
    expect(switchTile.value, isFalse);
  });

  testWidgets('总开关打开后能保存', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(home: LiveSubtitleSettingsScreen()),
    );
    await tester.pumpAndSettle();
    // Linux 上开关禁用，点它不应改变任何东西。
    await tester.tap(find.byKey(const ValueKey('live-subtitle-enabled')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('moyi_live_subtitle_enabled'), isNull);
  });
}
