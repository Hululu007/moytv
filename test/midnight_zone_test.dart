import 'package:moyi/app_drawer.dart';
import 'package:moyi/midnight_zone.dart';
import 'package:moyi/signature_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('midnight activation persists across loads', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await loadMidnightActivated(), isFalse);
    await saveMidnightActivated(true);
    expect(await loadMidnightActivated(), isTrue);
    await saveMidnightActivated(false);
    expect(await loadMidnightActivated(), isFalse);
  });

  test('signature verdict allows unknown and expected values only', () {
    expect(isSignatureAllowed(null), isTrue);
    expect(isSignatureAllowed(releaseSignatureSha256), isTrue);
    expect(isSignatureAllowed('0' * 64), isFalse);
    expect(releaseSignatureSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  Future<void> pumpDrawer(
    WidgetTester tester, {
    required bool midnightActivated,
    required ValueChanged<HomeZone> onZoneSelected,
    required ValueChanged<AppDrawerTool> onTool,
    required ValueChanged<bool> onMinorProtectionChanged,
    required VoidCallback onVersionDoubleTap,
  }) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDrawer(
            zone: HomeZone.drama,
            midnightActivated: midnightActivated,
            currentVersion: '1.4.25',
            onZoneSelected: onZoneSelected,
            onWatchRoom: () {},
            onTool: onTool,
            onMinorProtectionChanged: onMinorProtectionChanged,
            onVersionDoubleTap: onVersionDoubleTap,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('drawer hides midnight module and switch until activated', (
    tester,
  ) async {
    final zones = <HomeZone>[];
    await pumpDrawer(
      tester,
      midnightActivated: false,
      onZoneSelected: zones.add,
      onTool: (_) {},
      onMinorProtectionChanged: (_) {},
      onVersionDoubleTap: () {},
    );
    expect(find.text('短剧'), findsOneWidget);
    expect(find.text('点播'), findsOneWidget);
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('听书'), findsOneWidget);
    expect(find.text('午夜区'), findsNothing);
    expect(find.text('未成年保护'), findsNothing);
    expect(find.text('站源管理'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
    await tester.ensureVisible(find.text('听书'));
    await tester.tap(find.text('听书'));
    expect(zones, [HomeZone.audio]);
  });

  testWidgets('drawer shows midnight module and switch after activation', (
    tester,
  ) async {
    final zones = <HomeZone>[];
    var minorProtection = false;
    var versionDoubleTaps = 0;
    final tools = <AppDrawerTool>[];
    await pumpDrawer(
      tester,
      midnightActivated: true,
      onZoneSelected: zones.add,
      onTool: tools.add,
      onMinorProtectionChanged: (value) => minorProtection = value,
      onVersionDoubleTap: () => versionDoubleTaps++,
    );
    expect(find.text('午夜区'), findsOneWidget);
    expect(find.text('未成年保护'), findsOneWidget);
    await tester.ensureVisible(find.text('午夜区'));
    await tester.tap(find.text('午夜区'));
    expect(zones, [HomeZone.midnight]);
    await tester.ensureVisible(find.text('未成年保护'));
    await tester.tap(find.text('未成年保护'));
    expect(minorProtection, isTrue);
    await tester.ensureVisible(find.text('软件更新'));
    await tester.tap(find.text('软件更新'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tools, [AppDrawerTool.appUpdate]);
    expect(versionDoubleTaps, 0);
    final center = tester.getCenter(find.text('软件更新'));
    final first = await tester.startGesture(center);
    await first.up();
    await tester.pump(const Duration(milliseconds: 50));
    final second = await tester.startGesture(center);
    await second.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(versionDoubleTaps, 1);
    expect(tools, [AppDrawerTool.appUpdate]);
  });
}
