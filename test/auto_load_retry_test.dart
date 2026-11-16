import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 前 [failuresBeforeSuccess] 次 catalog 报错、之后正常：
/// 模拟刚装完第一次打开时内核/网络还没就绪、首次请求落空。
class _FlakyRepository extends FixtureRepository {
  _FlakyRepository({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  int catalogCalls = 0;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCalls++;
    if (catalogCalls <= failuresBeforeSuccess) {
      throw AppFailure('合成网络错误');
    }
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
      filters: filters,
    );
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

class _GoodRepository extends FixtureRepository {
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
      // 默认主题已改 Win7：本测试验通用外壳，显式钉住紫蓝霓虹。
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
    SourceSite.importedSites['siteb'] = SourceSite(
      'siteb',
      'SiteB',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() {
      SourceSite.importedSites.remove('missav');
      SourceSite.importedSites.remove('siteb');
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  Future<void> pumpHome(
    WidgetTester tester,
    AppRepository repository,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: repository, store: store),
      ),
    );
  }

  /// 推进假时钟，把自动补拉的 1.5 秒延迟与帧回调都刷完。
  Future<void> flushRetries(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('首屏首次请求失败时自动补拉，无需点按就出内容', (tester) async {
    final repository = _FlakyRepository(failuresBeforeSuccess: 1);
    await pumpHome(tester, repository);
    await flushRetries(tester);
    expect(repository.catalogCalls, greaterThanOrEqualTo(2));
    expect(find.text('第1页短剧'), findsWidgets);
    expect(find.text('暂时无法加载'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('一直失败时自动补拉有上限，不会无限刷', (tester) async {
    final repository = _FlakyRepository(failuresBeforeSuccess: 100);
    await pumpHome(tester, repository);
    await flushRetries(tester);
    // 首启链（1 次 + 最多 2 次补拉）与空屏补拉链（同样上限）
    // 两条链加起来最多 6 次；且多于 1 次，证明失败也自动补了。
    expect(repository.catalogCalls, greaterThanOrEqualTo(2));
    expect(repository.catalogCalls, lessThanOrEqualTo(6));
    expect(find.text('暂时无法加载'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('切换站点后自动加载新站内容，无需手动刷新', (tester) async {
    final repository = _GoodRepository();
    await pumpHome(tester, repository);
    await flushRetries(tester);
    expect(repository.requests, contains('missav'));
    expect(repository.requests, isNot(contains('siteb')));

    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    // 按行键点选：方块列一个站多面印站名，按文本找会命中多个。
    await tester.tap(find.byKey(const ValueKey('site-picker-row-siteb')));
    await flushRetries(tester);

    expect(repository.requests, contains('siteb'));
    expect(find.text('暂时无法加载'), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
