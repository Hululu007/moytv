import 'package:moyi/app_drawer.dart';
import 'package:moyi/midnight_zone.dart';
import 'package:moyi/signature_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adult source names carry the prefix', () {
    expect(isAdultSourceName('🔞快猫'), isTrue);
    expect(isAdultSourceName('🔞'), isTrue);
    expect(isAdultSourceName('HGTV'), isFalse);
    expect(isAdultSourceName(''), isFalse);
  });

  test('adult filter keeps only the selected side', () {
    const names = ['HGTV', '🔞快猫', '红果', '🔞撸先生'];
    expect(filterSourcesByAdult(names, (name) => name, true), [
      '🔞快猫',
      '🔞撸先生',
    ]);
    expect(filterSourcesByAdult(names, (name) => name, false), ['HGTV', '红果']);
    expect(filterSourcesByAdult(names, (name) => name, null), names);
  });

  test('signature verdict allows unknown and expected values only', () {
    expect(isSignatureAllowed(null), isTrue);
    expect(isSignatureAllowed(releaseSignatureSha256), isTrue);
    expect(isSignatureAllowed('0' * 64), isFalse);
    expect(releaseSignatureSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required ValueChanged<HomeZone> onZoneSelected,
    required ValueChanged<AppDrawerTool> onTool,
    required ValueChanged<bool> onMinorProtectionChanged,
  }) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDrawer(
            zone: HomeZone.library,
            currentVersion: '1.4.25',
            onZoneSelected: onZoneSelected,
            onWatchRoom: () {},
            onTool: onTool,
            onMinorProtectionChanged: onMinorProtectionChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('drawer has no separate midnight entry after the merge', (
    tester,
  ) async {
    final zones = <HomeZone>[];
    await pumpDrawer(
      tester,
      onZoneSelected: zones.add,
      onTool: (_) {},
      onMinorProtectionChanged: (_) {},
    );
    expect(find.text('片库'), findsOneWidget);
    expect(find.text('短剧'), findsNothing);
    expect(find.text('点播'), findsNothing);
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('听书'), findsNothing);
    // 午夜区已并入统一站点区：抽屉里不再有午夜区入口。
    expect(find.text('午夜区'), findsNothing);
    // 未成年保护不再等双击激活才出现，始终在抽屉里。
    expect(find.text('未成年保护'), findsOneWidget);
    // 统一站点区是唯一的管理入口。
    expect(find.text('站点区'), findsOneWidget);
    expect(find.text('站源管理'), findsNothing);
    await tester.tap(find.text('阅读'));
    await tester.pumpAndSettle();
    expect(find.text('听书'), findsOneWidget);
    await tester.ensureVisible(find.text('听书'));
    await tester.tap(find.text('听书'));
    expect(zones, [HomeZone.audio]);
  });

  testWidgets('drawer guardian switch hides adult sites once', (tester) async {
    final zones = <HomeZone>[];
    var minorProtection = false;
    final tools = <AppDrawerTool>[];
    await pumpDrawer(
      tester,
      onZoneSelected: zones.add,
      onTool: tools.add,
      onMinorProtectionChanged: (value) => minorProtection = value,
    );
    expect(find.text('未成年保护'), findsOneWidget);
    await tester.ensureVisible(find.text('未成年保护'));
    await tester.tap(find.text('未成年保护'));
    expect(minorProtection, isTrue);
    await tester.ensureVisible(find.text('软件更新'));
    await tester.tap(find.text('软件更新'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tools, [AppDrawerTool.appUpdate]);
  });
}
