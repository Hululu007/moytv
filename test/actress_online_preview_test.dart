// 演员库 AvPlay 版式预览图（2026-11-26 用户发三张真机截图
// 定版，白底 + 酒红点缀）：
// - actress_av_home：作品列表屏——源切换条（女优库/123AV/
//   PH）+ 搜索框与影片库入口 + 入口行（全部/女优/排行榜/
//   收藏）+ 分类胶囊 + 三列作品卡（番号酒红、徽标、日期灰）
//   + 底部导航（首页/女优/收藏，「分类」已删）；
// - actress_av_search：搜索态（标题「“词”的搜索结果」）；
// - actress_av_actresses：演员列表屏——分类页签（红字下划
//   线）+ 三列方形照片卡（名字居中加粗 + 约 N 部）；
// - actress_av_detail：女优详情屏——大圆头像 + 本名/别名/
//   N 部影片 + 外链描边钮 + 「她的作品」三列卡；
// - actress_online_av123 / actress_online_ph：在线源列表
//   （注入假取数，样本按站上结构造）。
// 封面在测试环境走假网络取不到图，卡面回落底色，版式为准。
// PNG 落工作树 preview/ 下，报告 REPORT_actress_whos_ui.md 引用。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_generic_db.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/actress/actress_nvku_cache.dart';
import 'package:moyi/actress/actress_nvku_page.dart';
import 'package:moyi/actress/actress_online_sources.dart';
import 'package:moyi/actress/actress_online_view.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/actress/actress_online_lines.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/actress/javdb_view.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/whos_local_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir =
    '/home/hatch/workspace/moyi_actress_whos_ui_20261126/preview';

/// 预览仓库：两条站点分类 + 一页 6 部作品（第 1 部是本地库
/// 兜底作品——带绿字「有资源」；第 2 部带字幕分类——橙字
/// 「字幕」；其余是在线作品，只有番号 + 日期）。
class _PreviewRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    return const [
      CatalogCategory('new', '最新上架'),
      CatalogCategory('c0', '有码 · 100'),
      CatalogCategory('c1', '无码 · 50'),
    ];
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    if (page > 1) return CatalogPage(const [], page: 2, hasMore: false);
    return CatalogPage(
      [
        Drama(
          id: 'whoslocal:p1',
          source: 'nvku',
          sourceId: 'whoslocal:p1',
          title: '预览作品第一部',
          cover: 'https://example.com/cover1.jpg',
          episodes: 1,
          category: '有码',
          onlineDate: '2026-11-03',
          tags: ['SSIS-001'],
        ),
        Drama(
          id: 'nvku:prev-2',
          source: 'nvku',
          title: '预览作品第二部',
          cover: 'https://example.com/cover2.jpg',
          episodes: 1,
          category: '中文字幕',
          onlineDate: '2026-11-24',
          tags: ['HUNTC-002'],
        ),
        for (var i = 3; i <= 6; i++)
          Drama(
            id: 'nvku:prev-$i',
            source: 'nvku',
            title: '预览作品第 $i 部',
            cover: 'https://example.com/cover$i.jpg',
            episodes: 1,
            category: '有码',
            onlineDate: '2026-12-0$i',
            tags: ['RCTD-77$i'],
          ),
      ],
      page: 1,
      hasMore: false,
    );
  }
}

/// 假影视库服务：两个标签，其余回空。
class _PreviewFilmService extends FilmLibraryService {
  _PreviewFilmService({required super.database});

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
  }) async => const [('成人影片', 100)];

  @override
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async => const {};

  @override
  Future<({String key, List<(String, int)> values})> tags() async {
    return (
      key: 'video_tag.tag_name',
      values: const [('剧情', 321), ('高清', 210)],
    );
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

/// 预览人物：6 位女优 + 各自作品（第一位带别名与 Twitter
/// 外链——详情页描边钮按资料里有无外链决定放不放）。
Future<void> _seedActresses(MemoryActressDatabase db) async {
  const names = ['预览女优一', '预览女优二', '预览女优三', '预览女优四', '预览女优五', '预览女优六'];
  const counts = [6, 12, 30, 5, 21, 3];
  for (var i = 0; i < names.length; i++) {
    final person = await db.upsertRosterPerson(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'PV-$i',
        name: names[i],
        sex: 'female',
        avatarUrl: 'https://example.com/avatar$i.jpg',
        aliases: i == 0 ? const ['别名一'] : const [],
        about: i == 0
            ? const {'twitter': 'https://twitter.com/example'}
            : const {},
      ),
    );
    await db.upsertWorks(person!.localId, [
      for (var w = 1; w <= counts[i]; w++)
        RosterFilm(
          code: 'SSIS-10$w',
          title: '作品标题 $w',
          date: '2026-1$w-01',
          coverUrl: 'https://example.com/work$i-$w.jpg',
          category: '有码',
        ),
    ], site: 'chaoliu');
  }
}

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(
    AppThemeMode.purpleNeon,
  ).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

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

Future<GlobalKey> _pumpPage(
  WidgetTester tester,
  Widget home, {
  Size size = const Size(1170, 2532),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(),
        home: home,
      ),
    ),
  );
  return key;
}

Future<void> _snap(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  Widget home, {
  bool Function()? until,
}) async {
  final key = await _pumpPage(tester, home);
  await _settleReal(tester, until: until);
  await _snap(tester, key, name);
}

const _av123ListHtml = '''
<div class="card">
  <a class="card__cover" href="/cn/v/ssis-001"><img class="card__img" data-src="https://icdn.123av.com/p1.jpg" alt=""></a>
  <div class="card__title">SSIS-001 预览标题一</div>
  <span class="card__dur">120分钟</span>
</div>
<div class="card">
  <a class="card__cover" href="/cn/v/madv-647"><img class="card__img" data-src="https://icdn.123av.com/p2.jpg" alt=""></a>
  <div class="card__title">MADV-647 预览标题二</div>
  <span class="card__dur">98分钟</span>
</div>
<div class="card">
  <a class="card__cover" href="/cn/v/ipx-999"><img class="card__img" data-src="https://icdn.123av.com/p3.jpg" alt=""></a>
  <div class="card__title">IPX-999 预览标题三</div>
  <span class="card__dur">150分钟</span>
</div>
''';

const _phListHtml = '''
<div class="wrap">
  <a href="/view_video.php?viewkey=abc123" data-poster="https://ci.phncdn.com/p1.jpg"><img src="https://ci.phncdn.com/t1.jpg" alt="PH 预览标题一"></a>
  <span class="duration">12:34</span>
</div>
<div class="wrap">
  <a href="/view_video.php?viewkey=def456" data-poster="https://ci.phncdn.com/p2.jpg"><img src="https://ci.phncdn.com/t2.jpg" alt="PH 预览标题二"></a>
  <span class="duration">3:05</span>
</div>
<div class="wrap">
  <a href="/view_video.php?viewkey=ghi789" data-poster="https://ci.phncdn.com/p3.jpg"><img src="https://ci.phncdn.com/t3.jpg" alt="PH 预览标题三"></a>
  <span class="duration">45:10</span>
</div>
''';

/// 假取数：第 1 页回样本，后续页回空页（停翻页）。
ActressOnlineFetch _fakeFetch(String html) {
  return (url, headers) async =>
      url.contains('page=2') || url.contains('page=3')
      ? '<html></html>'
      : html;
}

void main() {
  late LocalStore store;
  late MemoryActressDatabase db;

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NvkuEntryCache.clearForTest();
    store = LocalStore(await SharedPreferences.getInstance());
    db = MemoryActressDatabase();
    await _seedActresses(db);
    await ActressMytvBind.instance.ensureBound();
    await WhosLocalLibrary.shared.ensureLoaded();
  });

  ActressNvkuPage page() => ActressNvkuPage(
    repository: _PreviewRepository(),
    store: store,
    database: db,
    filmService: _PreviewFilmService(database: db),
  );

  testWidgets('preview av home works list', (tester) async {
    await _capture(
      tester,
      'actress_av_home',
      page(),
      until: () => find.text('预览作品第一部').evaluate().isNotEmpty,
    );
  });

  testWidgets('preview av search state', (tester) async {
    final key = await _pumpPage(tester, page());
    await _settleReal(
      tester,
      until: () => find.text('预览作品第一部').evaluate().isNotEmpty,
    );
    await tester.enterText(
      find.byKey(const ValueKey('nvku-search')),
      'SSIS',
    );
    tester.testTextInput.receiveAction(TextInputAction.search);
    await _settleReal(
      tester,
      until: () =>
          find.text('“SSIS”的搜索结果').evaluate().isNotEmpty,
    );
    await _snap(tester, key, 'actress_av_search');
  });

  testWidgets('preview av actress list', (tester) async {
    final key = await _pumpPage(tester, page());
    await _settleReal(
      tester,
      until: () => find.text('预览作品第一部').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('nvku-entrance-actress')));
    await _settleReal(
      tester,
      until: () => find.text('预览女优一').evaluate().isNotEmpty,
    );
    await _snap(tester, key, 'actress_av_actresses');
  });

  testWidgets('preview av actress detail', (tester) async {
    final key = await _pumpPage(tester, page());
    await _settleReal(
      tester,
      until: () => find.text('预览作品第一部').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('nvku-entrance-actress')));
    await _settleReal(
      tester,
      until: () => find.text('预览女优一').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('预览女优一'));
    await _settleReal(
      tester,
      until: () => find.text('她的作品').evaluate().isNotEmpty,
    );
    // 转场动画在慢渲染下要多沉降几轮，不然截到半途（底层列表透出）。
    await _settleReal(tester, rounds: 12);
    await tester.pump(const Duration(milliseconds: 400));
    await _snap(tester, key, 'actress_av_detail');
  });

  testWidgets('preview online 123av list', (tester) async {
    await _capture(
      tester,
      'actress_online_av123',
      Scaffold(
        body: SafeArea(
          child: ActressOnlineSourceView(
            source: const Av123ActressSource(),
            repository: FixtureRepository(),
            store: store,
            fetch: _fakeFetch(_av123ListHtml),
          ),
        ),
      ),
      until: () => find.text('SSIS-001 预览标题一').evaluate().isNotEmpty,
    );
  });

  testWidgets('preview online ph list', (tester) async {
    await _capture(
      tester,
      'actress_online_ph',
      Scaffold(
        body: SafeArea(
          child: ActressOnlineSourceView(
            source: const PhActressSource(),
            repository: FixtureRepository(),
            store: store,
            fetch: _fakeFetch(_phListHtml),
          ),
        ),
      ),
      until: () => find.text('PH 预览标题一').evaluate().isNotEmpty,
    );
  });

  // 作品详情页（2026-11-26 照 AvPlay 详情截图补演员/剧照）：
  // PESS-012 真番号让演员卡走真元数据；仓库详情回空集，
  // DetailScreen 落 initialDetail（信息卡/剧照/分类胶囊）。
  // 画布拉高到 1100 逻辑高，让信息卡+演员排+剧照排同框。
  testWidgets('preview av work detail page', (tester) async {
    // 潮流是 py 导入站，详情页 allowsSource 门要先有登记。
    SourceSite.importedSites['chaoliu'] = const SourceSite(
      'chaoliu',
      '潮流',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'py',
    );
    addTearDown(() => SourceSite.importedSites.remove('chaoliu'));
    const drama = Drama(
      id: 'chaoliu:PESS-012',
      source: 'chaoliu',
      title: 'PESS-012 样本影片标题预览',
      category: '成人影片',
      cover: 'https://picsum.photos/seed/moyi-detail-cover/640/360',
      onlineDate: '2024-06-15',
      tags: ['PESS-012'],
      episodes: 1,
    );
    final initial = DramaDetail(
      drama,
      [
        Episode({'id': 'x', 'title': '正片', 'direct': true}, 1),
      ],
      stills: [
        for (var i = 1; i <= 6; i++)
          'https://picsum.photos/seed/moyi-still$i/640/400',
      ],
      tags: const [
        DetailTag(id: '秘书', name: '秘书'),
        DetailTag(id: '巨乳', name: '巨乳'),
        DetailTag(id: '单体作品', name: '单体作品'),
      ],
      extraInfo: const [
        ('发行日期', '2024-06-15'),
        ('长度', '118 分钟'),
        ('制作商', '示例片商'),
      ],
    );
    final key = await _pumpPage(
      tester,
      DetailScreen(
        drama: drama,
        repository: _DetailPreviewRepository(),
        store: store,
        initialDetail: initial,
      ),
      size: const Size(1170, 3300),
    );
    await _settleReal(
      tester,
      rounds: 40,
      until: () =>
          find.byKey(const ValueKey('cast-岸和水')).evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey('detail-info-card'))
              .evaluate()
              .isNotEmpty,
    );
    await _snap(tester, key, 'actress_av_work_detail');
  });

  // 管理弹层预览（2026-11-26 16:55「设置不能少」）：点顶栏
  // 管理钮，弹层三项入口全展开的样子。
  testWidgets('preview av manage sheet', (tester) async {
    final key = await _pumpPage(tester, page());
    await _settleReal(tester);
    await tester.tap(find.byKey(const ValueKey('nvku-manage-open')));
    await _settleReal(tester, rounds: 6);
    await _snap(tester, key, 'actress_av_manage_sheet');
  });

  // 详情页线路行预览（示意）：数据库线路在上、在线线路区在
  // 下（123AV 假取数命中番号 = 已找到，PH 标题不含番号 =
  // 未找到）——在线行是假数据演示的未验状态，真实状态以出
  // 口验通为准（报告注明）。
  testWidgets('preview av detail lines', (tester) async {
    Future<String> fakeFetch(String url, Map<String, String> headers) async {
      if (url.contains('pornhub.com')) return _phListHtml;
      if (url.contains('123av.com')) return _av123ListHtml;
      return '<html></html>';
    }

    final key = await _pumpPage(
      tester,
      Scaffold(
        backgroundColor: const Color(0xFF1B1B1F),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  '播放线路',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const ListTile(
                leading: Icon(Icons.play_circle_fill, color: Colors.white),
                title: Text(
                  '数据库线路',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  '正片 · 库内直链（默认线路）',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              ActressOnlineLinesSection(
                code: 'SSIS-001',
                fetch: fakeFetch,
                onPlay: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await _settleReal(
      tester,
      rounds: 20,
      until: () => find.textContaining('已找到').evaluate().isNotEmpty,
    );
    await _snap(tester, key, 'actress_av_detail_lines');
  });

  // JavDB 源预览（假接口数据演示版式；真实接口未验，见报告）：
  // 演员页签三列方形头像卡 + 未验标。
  testWidgets('preview av javdb actors', (tester) async {
    final client = JavdbApiClient(
      fetch: (url) async {
        if (url.contains('/actors')) {
          return '{"success":true,"data":{"actors":['
              '{"id":"a1","name":"三上悠亚","avatar_url":"","gender":0},'
              '{"id":"a2","name":"桥本有菜","avatar_url":"","gender":0},'
              '{"id":"a3","name":"河北彩花","avatar_url":"","gender":0},'
              '{"id":"a4","name":"桃乃木香奈","avatar_url":"","gender":0},'
              '{"id":"a5","name":"枫可怜","avatar_url":"","gender":0},'
              '{"id":"a6","name":"小宵虎南","avatar_url":"","gender":0}'
              ']}}';
        }
        return '{"success":true,"data":{"movies":[]}}';
      },
    );
    final key = await _pumpPage(
      tester,
      Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(child: JavdbSourceView(client: client)),
      ),
    );
    await _settleReal(
      tester,
      rounds: 20,
      until: () => find.text('三上悠亚').evaluate().isNotEmpty,
    );
    await _snap(tester, key, 'actress_av_javdb');
  });
}

/// 详情预览仓库：detail 回空集，让 DetailScreen 落 initialDetail。
class _DetailPreviewRepository extends _PreviewRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, const []);
}
