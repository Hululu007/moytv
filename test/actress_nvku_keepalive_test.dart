// 进库不重载测试（2026-11-24 用户令：每次进演员库所有数据都要
// 重新加载，这个要修复）。
// - 第二次进库（全新页实例 + 全新假服务/假仓库）不再重查：文件夹、
//   标签、封面、分类、作品第一页全走会话缓存，假服务与假仓库的
//   调用计数不再涨。
// - 手动刷新（顶栏刷新钮）清缓存、重查一遍。
// - 女优 tab 切走再回来不重建：列表页 State 是同一个对象（切走时
//   仍挂在树里，只是藏起来），不再重跑 _bootstrap。
// 不碰真库、不走网络：假影视库服务 + 假仓库 + 内存库。
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

/// 计数假影视库服务：调用次数可查，数据固定。
/// 文件夹 3 个（成人影片 3 部、国产精品 2 部、无码专区 1 部）；
/// 标签 2 个；封面取每类型第一条视频的 pic_url。
class _CountingFilmService extends FilmLibraryService {
  _CountingFilmService({required super.database});

  var openCalls = 0;
  var tagsCalls = 0;
  var foldersCalls = 0;
  var coversCalls = 0;

  var folders = <(String, int)>[
    ('成人影片', 3),
    ('国产精品', 2),
    ('无码专区', 1),
  ];

  var tagList = <(String, int)>[('中文字幕', 3), ('ハイビジョン', 2)];

  final works = <String, List<FilmLibraryEntry>>{
    '成人影片': [
      const FilmLibraryEntry(
        vodId: 'mida-619',
        title: '测试作品一',
        code: 'MIDA-619',
        coverUrl: 'https://example.test/mida619.jpg',
        playUrl: 'https://example.test/mida619.m3u8',
        typeName: '成人影片',
      ),
    ],
    '国产精品': [
      const FilmLibraryEntry(
        vodId: 'guo-001',
        title: '国产测试一',
        code: 'GUO-001',
        coverUrl: 'https://example.test/guo001.jpg',
        playUrl: 'https://example.test/guo001.m3u8',
        typeName: '国产精品',
      ),
    ],
    '无码专区': [
      const FilmLibraryEntry(
        vodId: 'wuma-001',
        title: '无码测试一',
        code: 'WUMA-001',
        playUrl: 'https://example.test/wuma001.m3u8',
        typeName: '无码专区',
      ),
    ],
  };

  @override
  Future<FilmLibraryOpenResult> open() async {
    openCalls++;
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 6,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    tagsCalls++;
    return (key: 'video_tag.tag_name', values: tagList);
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    foldersCalls++;
    return folders;
  }

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    coversCalls++;
    final covers = <String, String>{};
    for (final name in typeNames) {
      final first = await listFilms(
        typeName: name,
        videoTag: videoTag,
        category: category,
        genericTagKey: genericTagKey,
        offset: 0,
        limit: 1,
      );
      covers[name] = first.isEmpty ? '' : first.first.coverUrl;
    }
    return covers;
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
    int offset = 0,
    int limit = 60,
  }) async {
    final rows = works[typeName] ?? const <FilmLibraryEntry>[];
    return rows.skip(offset).take(limit).toList();
  }
}

/// 计数假仓库：分类调用可查，目录沿用 FixtureRepository（记 requests）。
class _CountingRepository extends FixtureRepository {
  var categoriesCalls = 0;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categoriesCalls++;
    return const [
      CatalogCategory('c0', '有码 · 100'),
      CatalogCategory('c1', '无码 · 50'),
    ];
  }
}

ThemeData _testTheme(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

/// 真时间沉降：_boot 链里有真异步（本地库 ensureLoaded 等），假时间
/// pump 等不到它——用 runAsync 给真时间 + pump 帧 + 查条件轮询，
/// 直到条件成立或 10 秒用完（AGENTS.md 教训：pumpAndSettle 不等
/// 真异步 Future）。条件不传时只等一轮（给点按后的重建留时间）。
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NvkuEntryCache.clearForTest();
    store = LocalStore(await SharedPreferences.getInstance());
    db = MemoryActressDatabase();
    await ActressMytvBind.instance.ensureBound();
    // 预热本地库单例：_boot 里 WhosLocalLibrary.ensureLoaded() 首次
    // 跑要走真异步（开库/读目录），FakeAsync 下等不到它、_boot 会
    // 停在 _loadCategories、作品永不加载；setUp 在真异步区，先跑完
    // 一次、单例缓存住已完成的结果，页里再调立刻返回（真机上这步
    // 本来就是真异步、一次跑完就缓存，测试只是复现这个状态）。
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required _CountingFilmService service,
    required _CountingRepository repository,
  }) async {
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
    // 等 _boot 全跑完：标签/文件夹/封面都查过一遍、作品那一路已调过
    // catalog（2026-11-25：文件夹网格从首页移到分类页，首页不再有
    // “成人影片”文字，沉降条件改成查数计数，不再等文件夹上屏；
    // 文件夹上屏由调用方切到分类页后断言）。
    await _settleReal(
      tester,
      until: () =>
          service.tagsCalls >= 1 &&
          service.foldersCalls >= 1 &&
          service.coversCalls >= 1 &&
          repository.requests.isNotEmpty,
    );
  }

  /// 文件夹在分类页（2026-11-25 首页/分类归位）：切到分类页断言
  /// 文件夹在，再切回首页；切页不触发重查，计数断言不受影响。
  Future<void> expectFolderOnCategoryTab(WidgetTester tester) async {
    await tester.tap(find.text('分类'));
    await _settleReal(
      tester,
      until: () => find.text('成人影片').evaluate().isNotEmpty,
    );
    expect(find.text('成人影片'), findsOneWidget);
    await tester.tap(find.text('首页'));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 把作品卡滚进视口再断言：首张作品卡常在视口之下、GridView
  /// 懒加载没构建它，直接 find.text 找不到。
  /// 不能用 scrollUntilVisible（页里多个 Scrollable，它默认找唯一
  /// 的那个会抛 Too many elements），直接拖外层 ListView。
  Future<void> scrollToWorks(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      if (find.text('测试短剧').evaluate().isNotEmpty) return;
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('第二次进库不再全量重查', () {
    testWidgets('全新页实例 + 全新服务/仓库：文件夹/标签/分类/作品都不再查',
        (tester) async {
      final service1 = _CountingFilmService(database: db);
      final repo1 = _CountingRepository();
      await pumpPage(tester, service: service1, repository: repo1);
      await expectFolderOnCategoryTab(tester);
      await scrollToWorks(tester);
      expect(find.text('测试短剧'), findsOneWidget);
      expect(service1.tagsCalls, 1);
      expect(service1.foldersCalls, 1);
      expect(service1.coversCalls, 1);
      expect(repo1.categoriesCalls, 1);
      expect(repo1.requests, hasLength(1));

      // 离开演员库（页实例释放），再进一次：全新实例 + 全新服务/仓库。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settleReal(tester);
      final service2 = _CountingFilmService(database: db);
      final repo2 = _CountingRepository();
      await pumpPage(tester, service: service2, repository: repo2);

      // 数据立刻在（不用等重查），且第二份服务/仓库一次都没被调——
      // 开库本身每次都走（便宜的连接重开），查数据的几路全命中缓存。
      await expectFolderOnCategoryTab(tester);
      await scrollToWorks(tester);
      expect(find.text('测试短剧'), findsOneWidget);
      expect(service2.openCalls, 1);
      expect(service2.tagsCalls, 0);
      expect(service2.foldersCalls, 0);
      expect(service2.coversCalls, 0);
      expect(repo2.categoriesCalls, 0);
      expect(repo2.requests, isEmpty);
    });

    testWidgets('顶栏刷新钮清缓存、重查一遍', (tester) async {
      final service = _CountingFilmService(database: db);
      final repo = _CountingRepository();
      await pumpPage(tester, service: service, repository: repo);
      expect(service.tagsCalls, 1);
      expect(repo.categoriesCalls, 1);
      expect(repo.requests, hasLength(1));

      await tester.tap(find.byTooltip('刷新'));
      // 等刷新那一轮重查完成（标签计数涨到 2 才算查完）。
      await _settleReal(tester, until: () => service.tagsCalls >= 2);

      expect(service.tagsCalls, 2);
      expect(service.foldersCalls, 2);
      expect(service.coversCalls, 2);
      expect(repo.categoriesCalls, 2);
      expect(repo.requests, hasLength(2));
      await tester.tap(find.text('分类'));
      await _settleReal(
        tester,
        until: () => find.text('成人影片').evaluate().isNotEmpty,
      );
      expect(find.text('成人影片'), findsOneWidget);
    });
  });

  group('女优 tab 常驻不重建', () {
    testWidgets('切走再回来：列表页 State 是同一个对象', (tester) async {
      final service = _CountingFilmService(database: db);
      final repo = _CountingRepository();
      await pumpPage(tester, service: service, repository: repo);

      await tester.tap(find.text('女优'));
      await _settleReal(tester);
      // 切走后列表页藏在 IndexedStack 里（offstage、仍挂着），
      // 默认查找器会跳过藏起来的 widget，必须加 skipOffstage: false
      // 才能断言“常驻未卸载”；State 同一性是保活的直接证据。
      final listKey = find.byKey(
        const ValueKey('nvku-actress-list'),
        skipOffstage: false,
      );
      expect(listKey, findsOneWidget);
      final firstState = tester.state(listKey);

      // 切到首页再切回来：列表页仍挂在树里（只是藏起来），不是重建。
      await tester.tap(find.text('首页'));
      await _settleReal(tester);
      expect(listKey, findsOneWidget);
      await tester.tap(find.text('女优'));
      await _settleReal(tester);
      expect(listKey, findsOneWidget);
      final secondState = tester.state(listKey);
      expect(identical(firstState, secondState), isTrue);
    });
  });
}
