// 文件夹视频加载失败不再一直转圈（2026-11-25 转圈死锁修复）：
// _loadFolderWorks 原来无 try/catch，查询一抛错 _folderLoading
// 永久为真、页面永远显示“加载中…”；现在失败记 _folderError，
// 界面显示“加载失败，点下面重试”+ 重试钮，点重试能重跑。
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

/// 会抛错的假影视库服务：listFilms 按开关抛错（模拟 database is locked），
/// 其余查询正常返回。文件夹 1 个（成人影片 1 部）。
class _FailingFilmService extends FilmLibraryService {
  _FailingFilmService({required super.database});

  /// 为真时 listFilms 抛错；置假后重试能成功。
  var failListFilms = true;

  var listFilmsCalls = 0;

  final works = <FilmLibraryEntry>[
    const FilmLibraryEntry(
      vodId: 'mida-619',
      title: '测试作品一',
      code: 'MIDA-619',
      coverUrl: 'https://example.test/mida619.jpg',
      playUrl: 'https://example.test/mida619.m3u8',
      typeName: '成人影片',
    ),
  ];

  @override
  Future<FilmLibraryOpenResult> open() async {
    return const FilmLibraryOpenResult(
      dbPath: '/fake/MYTV/db/女优库.db',
      displayPath: 'MYTV/db/女优库.db',
      strict: true,
      total: 1,
      schema: GenericDbSchema(tables: [], fingerprint: 'test'),
      domain: '',
    );
  }

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    return (key: '', values: const <(String, int)>[]);
  }

  @override
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    return const [('成人影片', 1)];
  }

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    return const <String, String>{};
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
    listFilmsCalls++;
    if (failListFilms) throw StateError('database is locked');
    return works.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
  }) async {
    return works.length;
  }
}

/// 计数假仓库：分类调用可查，目录沿用 FixtureRepository（记 requests）。
class _FailingRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
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

/// 真时间沉降：_boot 链里有真异步，用 runAsync 给真时间 + pump 帧 +
/// 查条件轮询，直到条件成立或 10 秒用完。
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
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required _FailingFilmService service,
    required _FailingRepository repository,
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
    await _settleReal(
      tester,
      until: () => repository.requests.isNotEmpty,
    );
  }

  /// 切到分类页、点开“成人影片”文件夹，等加载结束。
  Future<void> openFolder(WidgetTester tester) async {
    await tester.tap(find.text('分类'));
    await tester.pump(const Duration(milliseconds: 100));
    await _settleReal(
      tester,
      until: () => find.text('成人影片').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('成人影片'));
    await _settleReal(
      tester,
      until: () =>
          find.text('加载失败，点下面重试').evaluate().isNotEmpty ||
          find.text('测试作品一').evaluate().isNotEmpty,
    );
  }

  group('文件夹视频加载失败', () {
    testWidgets('查询抛错：显示失败 + 重试钮，不再永远转圈', (tester) async {
      final service = _FailingFilmService(database: db);
      final repo = _FailingRepository();
      await pumpPage(tester, service: service, repository: repo);

      await openFolder(tester);

      expect(service.listFilmsCalls, greaterThanOrEqualTo(1));
      expect(find.text('加载失败，点下面重试'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('folder-retry')),
        findsOneWidget,
      );
      expect(find.text('成人影片 · 加载失败'), findsOneWidget);
      expect(find.text('成人影片 · 加载中…'), findsNothing);
    });

    testWidgets('点重试：失败原因消失后能加载出作品', (tester) async {
      final service = _FailingFilmService(database: db);
      final repo = _FailingRepository();
      await pumpPage(tester, service: service, repository: repo);

      await openFolder(tester);
      expect(find.text('加载失败，点下面重试'), findsOneWidget);

      service.failListFilms = false;
      await tester.tap(find.byKey(const ValueKey('folder-retry')));
      await _settleReal(
        tester,
        until: () => find.text('测试作品一').evaluate().isNotEmpty,
      );

      expect(find.text('测试作品一'), findsOneWidget);
      expect(find.text('加载失败，点下面重试'), findsNothing);
      expect(find.text('成人影片 · 共1条'), findsOneWidget);
    });
  });
}
