import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/liquid_glass.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _NoCoverRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'source': 'missav',
      'hiddenSites': '[]',
    });
    store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    SourceSite.importedSites['missav'] = SourceSite(
      'missav',
      'MissAV',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() => SourceSite.importedSites.remove('missav'));
    // 手机（Android）才走玻璃顶栏，胶囊遮挡只在该栏出现；体末复位。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  Future<void> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: _NoCoverRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 切区全走底部标签栏：0=片库 / 1=直播 / 4=多媒体。
  Future<void> tapShellTab(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(ValueKey('shell-tab-$index')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('narrow library: single source selector, capsule below title', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    // 只留标题上的一个站源选择器；旧的站源胶囊与下拉盒已删。
    final selector = find.byKey(const ValueKey('source-switch'));
    expect(selector, findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsWidgets);
    final titleRect = tester.getRect(selector);
    for (final capsule in capsules.evaluate()) {
      final rect = tester.getRect(find.byWidget(capsule.widget));
      expect(rect.overlaps(titleRect), isFalse);
    }
    // 至少一个胶囊在第二行（顶在标题下方）。
    final tops = capsules.evaluate().map(
      (e) => tester.getRect(find.byWidget(e.widget)).top,
    );
    expect(tops.any((top) => top >= titleRect.bottom), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide library: capsule shares the actions row', (tester) async {
    await pumpHome(tester, const Size(900, 844));
    final selector = find.byKey(const ValueKey('source-switch'));
    expect(selector, findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsWidgets);
    final titleRect = tester.getRect(selector);
    for (final capsule in capsules.evaluate()) {
      final rect = tester.getRect(find.byWidget(capsule.widget));
      expect(rect.overlaps(titleRect), isFalse);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('multimedia: no selector, no capsule, own title', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    await tapShellTab(tester, 4);
    expect(find.byType(MultimediaScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('source-switch')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byType(GlassButtonGroup), findsNothing);
    expect(find.text('多媒体'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('live: no selector, no capsule', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tapShellTab(tester, 1);
    expect(find.byKey(const ValueKey('source-switch')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byType(GlassButtonGroup), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('back to library: single selector returns', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tapShellTab(tester, 4);
    expect(find.byKey(const ValueKey('source-switch')), findsNothing);
    await tapShellTab(tester, 0);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
