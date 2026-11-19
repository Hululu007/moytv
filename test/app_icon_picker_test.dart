import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_icon_picker_page.dart';
import 'package:moyi/app_icon_switcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moyi/icon_switch');

  Future<void> pumpPage(
    WidgetTester tester, {
    required AppIconSwitcher switcher,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: AppIconPickerPage(switcher: switcher)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('六张图标齐全，点选切换并提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    String current = 'default';
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'currentIcon') return current;
      if (call.method == 'setIcon') {
        current = (call.arguments as Map)['id'] as String;
        return true;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await pumpPage(
      tester,
      switcher: AppIconSwitcher(supportedOverride: true),
    );
    for (final name in ['默认', '烈焰', '镜头', '蓝窗', '风暴', '草原']) {
      expect(find.text(name), findsOneWidget);
    }

    await tester.tap(find.byKey(const ValueKey('app-icon-ant_flame')));
    await tester.pumpAndSettle();
    expect(current, 'ant_flame');
    expect(find.text('已切换为「烈焰」，桌面图标稍后刷新'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(appIconSelectionKey), 'ant_flame');
  });

  testWidgets('非安卓只显示不支持提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(
      tester,
      switcher: AppIconSwitcher(supportedOverride: false),
    );
    expect(find.text('仅安卓支持更换应用图标'), findsOneWidget);
    expect(find.text('烈焰'), findsNothing);
  });
}
