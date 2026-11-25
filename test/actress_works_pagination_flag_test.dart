// 作品列表翻页标志卡死回归测试（2026-11-25，群里报的文件夹二次加载死
// 同款洞在魔蚁 nvku 页的 _loadWorks 里）：
// - 翻页进行中切分类：旧翻页回来时代际已顶掉直接 return，reset 又
//   不清 _loadingMore → 新分类滑到底被守卫挡掉，只出第一页、再往
//   下翻一页都出不来，只有重启能恢复。
// - 修法（与修仙版 3fcdfd89 同口径）：reset 开头清 _loadingMore；
//   分页 _fetchPage 抛错也复位；_fetchPage 本地取数段包 try/catch。
// 本测试只验第一条（可复现）：第 2 页请求被门控住，切分类、放行
// 旧请求，再滑到底——新分类的第 2 页必须还能取到。修前本测试失败
// （第 2 次翻页请求永远不发），修后通过。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_nvku_cache.dart';
import 'package:moyi/actress/actress_nvku_page.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/whos_local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 门控仓库：每页 30 部（满一页，_hasMore 才为真）；第 2 页第一次
/// 请求被门控住（等测试放行），之后的第 2 页请求立刻回。
class _GatedRepository extends FixtureRepository {
  final catalogCalls = <(String, int)>[];
  Completer<CatalogPage>? page2Gate;
  var _page2Held = false;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    return const [
      CatalogCategory('new', '最新上架'),
      CatalogCategory('c0', '有码 · 100'),
    ];
  }

  List<Drama> _page(String category, int page) => [
    for (var i = 1; i <= 30; i++)
      Drama(
        id: 'nvku:$category-p$page-$i',
        source: 'nvku',
        title: '作品 $category 第$page页第$i部',
        episodes: 1,
        category: '合成数据',
      ),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    catalogCalls.add((category, page));
    if (page == 2 && !_page2Held) {
      _page2Held = true;
      page2Gate = Completer<CatalogPage>();
      return page2Gate!.future;
    }
    return CatalogPage(_page(category, page), page: page, hasMore: true);
  }
}

/// 空影视库服务：文件夹/标签都回空，作品列表只走仓库那路。
class _EmptyFilmService extends FilmLibraryService {
  _EmptyFilmService({required super.database});

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 0,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async => const [];

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async => const {};

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    return (key: 'video_tag.tag_name', values: const <(String, int)>[]);
  }

  @override
  Future<List<FilmLibraryEntry>> listFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
    required int offset,
    required int limit,
  }) async => const [];

  @override
  Future<int> countFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
  }) async => 0;
}

ThemeData _testTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

/// 真异步沉降：runAsync 里等真时间、再刷一帧；until 满足即停。
Future<void> _settleReal(
  WidgetTester tester, {
  bool Function()? until,
}) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (until != null && until()) return;
    if (until == null && i >= 1) return;
  }
}

void main() {
  late LocalStore store;
  late MemoryActressDatabase db;
  late _GatedRepository repository;
  late _EmptyFilmService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NvkuEntryCache.clearForTest();
    store = LocalStore(await SharedPreferences.getInstance());
    db = MemoryActressDatabase();
    repository = _GatedRepository();
    service = _EmptyFilmService(database: db);
    await ActressMytvBind.instance.ensureBound();
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme(AppThemeMode.purpleNeon),
        home: ActressNvkuPage(
          repository: repository,
          store: store,
          database: db,
          filmService: service,
        ),
      ),
    );
    await _settleReal(
      tester,
      until: () => find.text('作品 new 第1页第1部').evaluate().isNotEmpty,
    );
    expect(find.text('作品 new 第1页第1部'), findsOneWidget);
  }

  /// 滑到底触发一次翻页（_onScroll 在离底部 600 内调 _loadWorks）。
  /// 不用 scrollUntilVisible：作品网格在首页/分类两个页签里各挂一份
  /// （IndexedStack 常驻），按标题找会在两个页签里各撞一个，单元素
  /// 断言过不了；直接拖外层 ListView（find.byType 深度优先，首页
  /// 那个在最前），网格本身不可滚、拖动落在父级滚动条上。
  Future<void> scrollToBottom(WidgetTester tester) async {
    await tester.drag(find.byType(ListView).first, const Offset(0, -10000));
    await tester.pump();
  }

  testWidgets('翻页进行中切分类，旧翻页回来后新分类仍能翻页', (tester) async {
    await pumpPage(tester);
    // 第 1 页 30 部全在，_hasMore 为真。
    expect(find.text('作品 new 第1页第30部'), findsOneWidget);

    // 滑到底：第 2 页请求发出、被门控住，翻页标志置起。
    await scrollToBottom(tester);
    await _settleReal(
      tester,
      until: () => repository.catalogCalls.any((c) => c.$2 == 2),
    );
    expect(
      repository.catalogCalls.where((c) => c.$2 == 2),
      hasLength(1),
      reason: '第 2 页请求应已发出一次',
    );
    expect(repository.page2Gate, isNotNull);

    // 滚回顶部：ListView 滚到底后顶部的胶囊孩子超出缓存会被销毁，
    // 得先滚回来、等胶囊重建出来再点（这是 ListView 的正常行为，
    // 不是页面 bug）。
    await tester.drag(find.byType(ListView).first, const Offset(0, 10000));
    await tester.pump();
    expect(find.byKey(const ValueKey('nvku-chip-c0')), findsOneWidget);

    // 切分类“有码”：reset 走新代际，第 1 页重取（按 key 点药丸，
    // 标签原名带尾数“有码 · 100”，不按文本找）。
    await tester.tap(find.byKey(const ValueKey('nvku-chip-c0')));
    await _settleReal(
      tester,
      until: () =>
          repository.catalogCalls.any((c) => c.$1 == 'c0' && c.$2 == 1),
    );
    expect(find.text('作品 c0 第1页第1部'), findsOneWidget);

    // 放行旧的第 2 页请求（new 分类那份）：代际已顶掉，直接 return，
    // 不能把新分类的翻页标志留在 true。
    repository.page2Gate!.complete(
      CatalogPage(
        [
          for (var i = 1; i <= 30; i++)
            Drama(
              id: 'nvku:new-p2-$i',
              source: 'nvku',
              title: '作品 new 第2页第$i部',
              episodes: 1,
              category: '合成数据',
            ),
        ],
        page: 2,
        hasMore: true,
      ),
    );
    await _settleReal(tester);
    // 旧分类的第 2 页行不能混进新分类的列表。
    expect(find.text('作品 new 第2页第1部'), findsNothing);

    // 再滑到底：新分类的第 2 页必须还能取到（修前这里永远不发请求）。
    await scrollToBottom(tester);
    await _settleReal(
      tester,
      until: () =>
          repository.catalogCalls.where((c) => c.$2 == 2).length >= 2,
    );
    expect(
      repository.catalogCalls.where((c) => c.$2 == 2),
      hasLength(2),
      reason: '切分类后翻页标志若卡住，第 2 次第 2 页请求永远不发',
    );
    expect(find.text('作品 c0 第2页第1部'), findsOneWidget);
  });
}
