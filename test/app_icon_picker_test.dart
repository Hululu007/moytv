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

    await pumpPage(tester, switcher: AppIconSwitcher(supportedOverride: true));
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
    await pumpPage(tester, switcher: AppIconSwitcher(supportedOverride: false));
    expect(find.text('仅安卓支持更换应用图标'), findsOneWidget);
    expect(find.text('烈焰'), findsNothing);
  });

  testWidgets('切换被系统拒绝：提示具体原因、横条出现、点选停掉', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'currentIcon') return 'default';
          throw PlatformException(
            code: 'switch_failed',
            message: 'Permission denied',
            details: 'SecurityException',
          );
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await pumpPage(tester, switcher: AppIconSwitcher(supportedOverride: true));
    await tester.tap(find.byKey(const ValueKey('app-icon-ant_flame')));
    await tester.pumpAndSettle();
    expect(
      find.text('切换失败：系统拒绝了换图标，当前桌面或容器不允许（SecurityException）'),
      findsOneWidget,
    );
    expect(find.textContaining('上次切换被系统拒绝了'), findsOneWidget);
    expect(find.text('再试一次'), findsOneWidget);
    // 点选已停掉：再点别的图标不再发通道。
    final sent = calls.where((c) => c.method == 'setIcon').length;
    await tester.tap(find.byKey(const ValueKey('app-icon-ant_lens')));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setIcon').length, sent);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(appIconSwitchDeniedKey), isTrue);
  });

  testWidgets('拒绝记忆进页即显横条，再试一次清除', (tester) async {
    SharedPreferences.setMockInitialValues({appIconSwitchDeniedKey: true});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'currentIcon') return 'default';
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await pumpPage(tester, switcher: AppIconSwitcher(supportedOverride: true));
    expect(find.textContaining('上次切换被系统拒绝了'), findsOneWidget);
    await tester.tap(find.text('再试一次'));
    await tester.pumpAndSettle();
    expect(find.textContaining('上次切换被系统拒绝了'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(appIconSwitchDeniedKey), isNull);
  });
}
