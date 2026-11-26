// 演员库入口恢复回归测试（2026-11-26 用户令：恢复原生 who's
// 界面、撤合并网页、底部导航删「分类」、123AV/PH 只进源切换）：
// - 合并页资源 actress_library.html 已从包里撤登记，rootBundle
//   再也读不到它（防合并页被重新接回包里）；
// - 原生页顶部有源切换条（女优库 / 123AV / PH），底部导航只剩
//   首页 / 女优 / 收藏三项、没有「分类」，影片库入口照旧在
//   搜索框旁；
// - 切到 PH：在线视图出现；测试环境没真网络，取数失败必须落
//   到人话错误态 + 重试钮，不许假装有数据；
// - 切回女优库：底部导航与作品都还在。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 空影视库服务：文件夹/标签回空，作品只走仓库那路（与作品
/// 分页标志测试同款假服务）。
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
  int rounds = 24,
}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (until != null && until()) return;
    if (until == null && i >= 1) return;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('合并页资源已撤：包里读不到 actress_library.html', () async {
    await expectLater(
      rootBundle.loadString('assets/actress_library.html'),
      throwsA(anything),
    );
  });

  group('原生页源切换与底部导航', () {
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

    testWidgets('源切换条齐全、底部导航删分类；切 PH 出在线报错态，切回恢复',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(AppThemeMode.purpleNeon),
          home: ActressNvkuPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            filmService: _EmptyFilmService(database: db),
          ),
        ),
      );
      await _settleReal(tester);

      // 源切换条三段 + 影片库入口（原 UI 位置）都在。
      expect(
        find.byKey(const ValueKey('actress-source-nvku')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('actress-source-av123')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('actress-source-ph')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nvku-open-film-library')),
        findsOneWidget,
      );
      // 底部导航只剩三项，「分类」已删、其余顺移补齐。
      // （2026-11-26 入口行也有「女优/收藏」字样，断言按底部
      // 页签的键逐项核对，不用裸文字找。）
      expect(find.byKey(const ValueKey('nvku-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('nvku-tab-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('nvku-tab-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nvku-tab-0')),
          matching: find.text('首页'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nvku-tab-1')),
          matching: find.text('女优'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('nvku-tab-2')),
          matching: find.text('收藏'),
        ),
        findsOneWidget,
      );
      expect(find.text('分类'), findsNothing);

      // 切到 PH：在线视图挂上；没真网络 → 人话错误态 + 重试钮
      // （不许白屏、不许假数据）。底部导航不被在线源顶替。
      await tester.tap(find.byKey(const ValueKey('actress-source-ph')));
      await _settleReal(
        tester,
        until: () =>
            find
                .byKey(const ValueKey('online-ph-retry'))
                .evaluate()
                .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('online-ph-retry')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('nvku-tab-0')), findsOneWidget);
      expect(find.text('分类'), findsNothing);

      // 切回女优库：底部导航照旧。
      await tester.tap(find.byKey(const ValueKey('actress-source-nvku')));
      await _settleReal(tester);
      expect(find.byKey(const ValueKey('nvku-tab-1')), findsOneWidget);
      expect(find.text('分类'), findsNothing);
    });
  });
}
