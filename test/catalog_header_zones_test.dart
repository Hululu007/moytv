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
      // 默认主题已改 XP：本测试验通用外壳，显式钉住紫蓝霓虹。
      'appThemeMode': 'purpleNeon',
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

  /// 切区全走底部标签栏：0=片库 / 1=直播 / 3=网盘。
  Future<void> tapShellTab(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(ValueKey('shell-tab-$index')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('narrow library: single-row icon bar, site icon first', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    // 站名文字行已去掉：站图标是胶囊第一位，点它弹站点选择；
    // 旧的站源胶囊与下拉盒已删。
    final selector = find.byKey(const ValueKey('source-switch'));
    expect(selector, findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsOneWidget);
    final capsuleRect = tester.getRect(capsules);
    final selectorRect = tester.getRect(selector);
    // 单行 44 高：胶囊就是标题行，站图标在胶囊内第一位。
    expect(capsuleRect.height, 44);
    expect(capsuleRect.top, 0);
    expect(selectorRect.top, capsuleRect.top);
    expect(selectorRect.left, closeTo(capsuleRect.left + 4, 0.5));
    final mineRect = tester.getRect(
      find.byKey(const ValueKey('open-mine-page')),
    );
    expect(mineRect.left, closeTo(selectorRect.right, 0.5));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.preferredSize.height, 44);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide library: same single-row icon bar', (tester) async {
    await pumpHome(tester, const Size(900, 844));
    final selector = find.byKey(const ValueKey('source-switch'));
    expect(selector, findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    final capsules = find.byType(GlassButtonGroup);
    expect(capsules, findsOneWidget);
    final capsuleRect = tester.getRect(capsules);
    final selectorRect = tester.getRect(selector);
    expect(capsuleRect.height, 44);
    expect(selectorRect.left, closeTo(capsuleRect.left + 4, 0.5));
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.preferredSize.height, 44);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('multimedia: no selector, no capsule, own title', (
    tester,
  ) async {
    await pumpHome(tester, const Size(390, 844));
    await tapShellTab(tester, 3);
    expect(find.byType(MultimediaScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('source-switch')), findsNothing);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byType(GlassButtonGroup), findsNothing);
    expect(find.text('网盘'), findsWidgets);
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
    await tapShellTab(tester, 3);
    expect(find.byKey(const ValueKey('source-switch')), findsNothing);
    await tapShellTab(tester, 0);
    expect(find.byKey(const ValueKey('source-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-site-box')), findsNothing);
    expect(find.byKey(const ValueKey('source-dropdown')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
