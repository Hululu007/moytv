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

  /// 抽屉里点一行/一枚顶 Tab（导航固定抽屉，切区全走抽屉）。
  Future<void> tapDrawerLabel(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('open-app-drawer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final item = find.descendant(
      of: find.byType(Drawer),
      matching: find.text(label),
    );
    expect(item, findsOneWidget);
    await tester.tap(item);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('narrow library: capsule sits below the site box', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    final siteBox = find.byKey(const ValueKey('drawer-site-box'));
    expect(siteBox, findsOneWidget);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsWidgets);
    final siteRect = tester.getRect(siteBox);
    for (final capsule in capsules.evaluate()) {
      final rect = tester.getRect(find.byWidget(capsule.widget));
      expect(rect.overlaps(siteRect), isFalse);
    }
    // 至少一个胶囊在第二行（顶在站源条下方）。
    final tops = capsules.evaluate().map(
      (e) => tester.getRect(find.byWidget(e.widget)).top,
    );
    expect(tops.any((top) => top >= siteRect.bottom), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide library: capsule shares the actions row', (tester) async {
    await pumpHome(tester, const Size(900, 844));
    final siteBox = find.byKey(const ValueKey('drawer-site-box'));
    expect(siteBox, findsOneWidget);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsWidgets);
    final siteRect = tester.getRect(siteBox);
    for (final capsule in capsules.evaluate()) {
      final rect = tester.getRect(find.byWidget(capsule.widget));
      expect(rect.overlaps(siteRect), isFalse);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('multimedia: no site box, no capsule, own title', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    await tapDrawerLabel(tester, '多媒体');
    expect(find.byType(MultimediaScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byType(GlassButtonGroup), findsNothing);
    expect(find.text('多媒体'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('live: no site box, no capsule', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tapDrawerLabel(tester, '直播');
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byType(GlassButtonGroup), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('back to library: site box returns', (tester) async {
    await pumpHome(tester, const Size(390, 844));
    await tapDrawerLabel(tester, '多媒体');
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    await tapDrawerLabel(tester, '影视');
    expect(
      find.byKey(const ValueKey('drawer-site-box')),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
