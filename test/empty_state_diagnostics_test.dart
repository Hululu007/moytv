import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _EmptyRepository extends FixtureRepository {
  _EmptyRepository({this.diagnostics = true});

  final bool diagnostics;

  @override
  bool get supportsSourceManagement => diagnostics;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage([]);

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalStore store;

  Future<void> seed({String? appThemeMode}) async {
    SharedPreferences.setMockInitialValues({
      'source': 'missav',
      'hiddenSites': '[]',
      if (appThemeMode != null) 'appThemeMode': appThemeMode,
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
    // 手机（Android）才走玻璃顶栏；体末复位（见内嵌测试注释）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    bool diagnostics = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(
          repository: _EmptyRepository(diagnostics: diagnostics),
          store: store,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('空状态有站源诊断入口（支持诊断时）', (tester) async {
    await seed();
    await pumpHome(tester);
    expect(find.text('没有找到匹配的短剧'), findsOneWidget);
    expect(find.text('站源诊断'), findsOneWidget);
    // 收尾：手动卸树（取消站源轮询的 2 秒周期定时器）再排干 3 秒
    // （放行轮询 refresh 链上后到的 100ms 缓存刷新定时器）。只排干
    // 或只卸树都会在校验时挂起，两者缺一不可（实测）。
    await tester.pumpWidget(Container());
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('空状态无站源诊断入口（不支持诊断时）', (tester) async {
    await seed();
    await pumpHome(tester, diagnostics: false);
    expect(find.text('没有找到匹配的短剧'), findsOneWidget);
    expect(find.text('站源诊断'), findsNothing);
    // 收尾：手动卸树（取消站源轮询的 2 秒周期定时器）再排干 3 秒
    // （放行轮询 refresh 链上后到的 100ms 缓存刷新定时器）。只排干
    // 或只卸树都会在校验时挂起，两者缺一不可（实测）。
    await tester.pumpWidget(Container());
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('左侧分类主题空状态也有站源诊断入口', (tester) async {
    await seed(appThemeMode: 'leftCategories');
    await pumpHome(tester);
    expect(find.text('没有找到匹配的短剧'), findsOneWidget);
    expect(find.text('站源诊断'), findsOneWidget);
    // 收尾：手动卸树（取消站源轮询的 2 秒周期定时器）再排干 3 秒
    // （放行轮询 refresh 链上后到的 100ms 缓存刷新定时器）。只排干
    // 或只卸树都会在校验时挂起，两者缺一不可（实测）。
    await tester.pumpWidget(Container());
    await tester.pump(const Duration(seconds: 3));
    debugDefaultTargetPlatformOverride = null;
  });
}
