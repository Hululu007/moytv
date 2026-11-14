// 第十版反馈批界面改动预览截图：只做测试内截图，不改业务代码。
// 假数据说明：探活结果、网盘条目、TG 帖子、刮削元数据均为测试内
// 合成；封面为空占位；图标/emoji 在测试环境可能渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、超时杀掉只取 PNG；不要把两张放进同一个测试体。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/bottom_tab_bar.dart';
import 'package:moyi/crosssite_probe_section.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/multimedia_screen.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/tg_list_postprocess.dart';
import 'package:moyi/tmdb/tmdb_metadata.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewTheme() {
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
      subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: 'PreviewCJK'),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => base.filledButtonTheme.style?.textStyle
              ?.resolve(states)
              ?.copyWith(fontFamily: 'PreviewCJK'),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
  for (var i = 0; i < 10; i++) {
    try {
      if (tester.takeException() == null) break;
    } catch (_) {
      break;
    }
  }
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required String label,
  required Widget screen,
  Future<void> Function()? interact,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = AppThemeMode.purpleNeon;
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _previewTheme(),
        home: DefaultTextStyle(
          style: const TextStyle(fontFamily: 'PreviewCJK'),
          child: Scaffold(
            body: Column(
              children: [
                Container(
                  width: double.infinity,
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontFamily: 'PreviewCJK',
                    ),
                  ),
                ),
                Expanded(child: screen),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  if (interact != null) {
    await interact();
    await _settle(tester);
  }
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
  print('preview landed: $name');
}

Future<LocalStore> _previewStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

/// 预览仓库：封面返回空（占位），搜索/详情/目录走测试内合成数据。
class _PreviewRepository extends RouteRepository {
  Map<String, List<Drama>> searchResults = {};
  Map<String, DramaDetail> detailResults = {};
  Map<String, List<Drama>> catalogResults = {};
  Map<String, Duration> searchDelays = {};

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    final items = <Drama>[];
    for (final source in sources) {
      final delay = searchDelays[source];
      if (delay != null) await Future.delayed(delay);
      items.addAll(searchResults[source] ?? const []);
    }
    return CatalogPage(items);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    final fixed = detailResults['${drama.source}:${drama.id}'];
    if (fixed != null) return fixed;
    return DramaDetail(drama, const []);
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
    return CatalogPage(catalogResults[source] ?? const []);
  }
}

DramaDetail _detailWithFlags(String source, String id, List<String> flags) {
  final drama = Drama(id: id, source: source, title: id);
  return DramaDetail(drama, [
    for (var i = 0; i < flags.length; i++)
      Episode({
        'id': 'p$i',
        'title': '${flags[i]} · 正片',
        'flag': flags[i],
      }, i + 1),
  ]);
}

SourceSite _videoSite(String id, String name) =>
    SourceSite(id, name, '', section: SourceSite.sectionVideo);

void main() {
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

  // 1. 跨站选线路新版：胶囊容器 + 胶囊线路片 + “推荐”标记。
  // 假探活：JavMenu 最快探出 2 条线路（推荐）、AVDB/MemoJav/AV01
  // 也探出版本线路；示例站探过无线标 ×；Jable 点过懒查后探出；
  // MissAV 保持未点、显示“点击查询”。
  testWidgets('预览 跨站选线胶囊新版', (tester) async {
    final repository = _PreviewRepository()
      ..searchResults = {
        'javmenu': [
          const Drama(id: 'hmn-927', source: 'javmenu', title: 'HMN-927'),
        ],
        'avdb': [
          const Drama(id: 'hmn-927', source: 'avdb', title: 'HMN-927'),
        ],
        'memojav': [
          const Drama(id: 'hmn-927', source: 'memojav', title: 'HMN-927'),
        ],
        'jar:zakatv:zakav01': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'HMN-927',
          ),
          const Drama(
            id: 'hmn-927-lada',
            source: 'jar:zakatv:zakav01',
            title: 'HMN-927-LADA',
          ),
        ],
        'jar:zakatv:ZakaJable': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:ZakaJable',
            title: 'HMN-927',
          ),
        ],
        'jar:zakatv:ZakaMissav': [],
        'py:demo': [],
      }
      ..searchDelays = {
        'javmenu': const Duration(milliseconds: 5),
        'avdb': const Duration(milliseconds: 40),
        'memojav': const Duration(milliseconds: 80),
        'jar:zakatv:zakav01': const Duration(milliseconds: 120),
      }
      ..detailResults = {
        'javmenu:hmn-927': _detailWithFlags('javmenu', 'hmn-927', [
          '线路1',
          '线路2',
        ]),
        'avdb:hmn-927': _detailWithFlags('avdb', 'hmn-927', ['在线播放']),
        'memojav:hmn-927': _detailWithFlags('memojav', 'hmn-927', [
          '线路A',
          '线路B',
        ]),
        'jar:zakatv:zakav01:hmn-927': _detailWithFlags(
          'jar:zakatv:zakav01',
          'hmn-927',
          ['线路1', '线路2'],
        ),
        'jar:zakatv:zakav01:hmn-927-lada': _detailWithFlags(
          'jar:zakatv:zakav01',
          'hmn-927-lada',
          ['线路1'],
        ),
        'jar:zakatv:ZakaJable:hmn-927': _detailWithFlags(
          'jar:zakatv:ZakaJable',
          'hmn-927',
          ['Jable线路'],
        ),
      };
    final store = await _previewStore();
    await _capture(
      tester,
      name: 'crosssite_capsule_v2',
      label: '预览 · 假探活数据 · 胶囊容器+胶囊线路片 · 最快一家标“推荐” · 封面为占位',
      screen: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'HMN-927 测试片',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '详情页 · 选集区之后、简介之前',
                style: TextStyle(fontSize: 12),
              ),
            ),
            CrossSiteProbeSection(
              repository: repository,
              store: store,
              avId: 'HMN-927',
              currentSourceId: 'hongguo',
              onPlayLine: (_, __) {},
              candidateSites: [
                _videoSite('javmenu', '🔞JAV目錄大全'),
                _videoSite('avdb', '🔞AVDB'),
                _videoSite('memojav', '🔞MemoJav'),
                _videoSite('jar:zakatv:zakav01', '🔞AV01'),
                _videoSite('jar:zakatv:ZakaMissav', '🔞MissAV'),
                _videoSite('jar:zakatv:ZakaJable', '🔞Jable'),
                _videoSite('py:demo', '🔞示例站'),
              ],
            ),
          ],
        ),
      ),
      interact: () async {
        await tester.scrollUntilVisible(
          find.byKey(
            const ValueKey('crosssite-rowtap-jar:zakatv:ZakaJable'),
          ),
          200,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(
            const ValueKey('crosssite-rowtap-jar:zakatv:ZakaJable'),
          ),
        );
      },
    );
  });

  // 2. 多媒体屏：网盘聚合列表（假网盘数据）+ 假刮削补标题/年份。
  testWidgets('预览 多媒体网盘聚合', (tester) async {
    final repository = _PreviewRepository()
      ..catalogResults = {
        'cloud:115': [
          const Drama(
            id: 'fld-movies',
            source: 'cloud:115',
            title: '电影合集',
            kind: 'folder',
            folderId: 'fld1',
          ),
          const Drama(
            id: 'f1',
            source: 'cloud:115',
            title: '流浪地球2 2023 4K.mp4',
            category: '电影',
          ),
          const Drama(
            id: 'f2',
            source: 'cloud:115',
            title: '热辣滚烫 2024 HD.mp4',
            category: '电影',
          ),
          const Drama(
            id: 'f3',
            source: 'cloud:115',
            title: '庆余年 第12集.mp4',
            category: '剧集',
          ),
        ],
        'cloud:quark': [
          const Drama(
            id: 'q1',
            source: 'cloud:quark',
            title: '星际穿越 2014 蓝光.mp4',
            category: '电影',
          ),
          const Drama(
            id: 'q2',
            source: 'cloud:quark',
            title: '周杰伦演唱会 2023.mp4',
            category: '音乐',
          ),
        ],
      };
    final store = await _previewStore();
    await _capture(
      tester,
      name: 'multimedia_drives',
      label: '预览 · 假网盘数据 · 115+夸克聚合 · 刮削补标题/年份 · 封面为占位',
      screen: MultimediaScreen(
        repository: repository,
        store: store,
        driveSites: const [
          SourceSite('cloud:115', '115网盘', ''),
          SourceSite('cloud:quark', '夸克网盘', ''),
        ],
        onOpenDrama: (_) {},
        onOpenCloudLogin: () {},
        metadataFetcher:
            ({required String title, String? year, String? typeHint}) async {
              if (title.contains('流浪地球')) {
                return const TmdbMetadata(
                  title: '流浪地球2',
                  year: '2023',
                  mediaType: 'movie',
                  overview: '假刮削简介：太阳即将毁灭，人类开启流浪地球计划。',
                );
              }
              if (title.contains('热辣')) {
                return const TmdbMetadata(
                  title: '热辣滚烫',
                  year: '2024',
                  mediaType: 'movie',
                  overview: '假刮削简介：宅家多年的乐莹决心改变自己。',
                );
              }
              if (title.contains('庆余年')) {
                return const TmdbMetadata(
                  title: '庆余年',
                  year: '2019',
                  mediaType: 'tv',
                  overview: '假刮削简介：范闲的身世之谜与庆国风云。',
                );
              }
              if (title.contains('星际穿越')) {
                return const TmdbMetadata(
                  title: '星际穿越',
                  year: '2014',
                  mediaType: 'movie',
                  overview: '假刮削简介：穿越虫洞寻找人类新家园。',
                );
              }
              return null;
            },
      ),
    );
  });

  // 3. 多媒体屏未登录提示态。
  testWidgets('预览 多媒体未登录', (tester) async {
    final repository = _PreviewRepository();
    final store = await _previewStore();
    await _capture(
      tester,
      name: 'multimedia_logged_out',
      label: '预览 · 未登录任何网盘时的提示态',
      screen: MultimediaScreen(
        repository: repository,
        store: store,
        driveSites: const [],
        onOpenDrama: (_) {},
        onOpenCloudLogin: () {},
      ),
    );
  });

  // 4. 抽屉导航：分区键只剩影视/阅读/小程序（音乐已删）。
  testWidgets('预览 抽屉三分区', (tester) async {
    await _capture(
      tester,
      name: 'drawer_shelves_v2',
      label: '预览 · 抽屉导航 · 分区键只剩影视/阅读/小程序',
      screen: AppDrawer(
        zone: HomeZone.library,
        currentVersion: '1.0.0+1',
        onZoneSelected: (_) {},
        onWatchRoom: () {},
        onTool: (_) {},
        onMinorProtectionChanged: (_) {},
        appTheme: AppThemeMode.purpleNeon,
      ),
    );
  });

  // 5. 底部 Tab 栏 6 个：多媒体选中、硬盘图标。
  testWidgets('预览 底部Tab六个', (tester) async {
    await _capture(
      tester,
      name: 'bottomtab_6_v2',
      label: '预览 · 底部 Tab 6 个 · 多媒体选中（硬盘图标）· 图标在测试环境渲染为方块',
      screen: Scaffold(
        body: const Center(
          child: Text('多媒体页占位 · 底栏为本次预览主体'),
        ),
        bottomNavigationBar: MoyiBottomTabBar(index: 5, onSelect: (_) {}),
      ),
    );
  });

  // 6. 胶囊栏：中间播放三角钮 + 🎞️ 频道（频道选中）。
  testWidgets('预览 胶囊栏', (tester) async {
    await _capture(
      tester,
      name: 'capsule_bar_v2',
      label: '预览 · 胶囊栏 · 中间播放三角钮 · 频道为 🎞️（emoji 在测试环境可能显示为方块）',
      screen: Container(
        color: const Color(0xFF120E20),
        child: Column(
          children: [
            const Expanded(
              child: Center(
                child: Text(
                  '霓虹首页占位 · 胶囊栏为本次预览主体',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
            NeonBottomBar(index: 1, onSelect: (_) {}, onCenter: () {}),
          ],
        ),
      ),
    );
  });

  // 7. TG 频道列表：广告帖被滤、重复去重、同名 6 集归成一张卡。
  testWidgets('预览 TG频道过滤归拢', (tester) async {
    final raw = <Drama>[
      for (var i = 1; i <= 6; i++)
        Drama(
          id: 'duanjuPD|10$i',
          source: 'jar:zakatv:ZakaTg',
          title: '重生之都市狂龙 第$i集',
          category: '短剧',
          onlineDate: '11-14',
        ),
      const Drama(
        id: 'advpn|1',
        source: 'jar:zakatv:ZakaTg',
        title: '大佬都在用的VPN 高速稳定全球畅连',
        description: 'Hi快VPN 让连接手到擒来',
      ),
      const Drama(
        id: 'adseo|1',
        source: 'jar:zakatv:ZakaTg',
        title: 'Telegram必备的搜索引擎，极搜JISOU',
      ),
      const Drama(
        id: 'adpay|1',
        source: 'jar:zakatv:ZakaTg',
        title: '先说清楚：这是广告，我按月收钱',
      ),
      const Drama(
        id: 'dup|1',
        source: 'jar:zakatv:ZakaTg',
        title: '每日精选合集',
        cover: 'https://cdn.example.com/c1.jpg',
      ),
      const Drama(
        id: 'dup|2',
        source: 'jar:zakatv:ZakaTg',
        title: '每日精选合集',
        cover: 'https://cdn.example.com/c1.jpg',
      ),
      const Drama(
        id: 'solo|1',
        source: 'jar:zakatv:ZakaTg',
        title: '夏日海边写真特辑',
      ),
      const Drama(
        id: 'solo|2',
        source: 'jar:zakatv:ZakaTg',
        title: '猫咪治愈合集',
      ),
    ];
    final processed = tgPostProcessPage(
      CatalogPage(raw),
      className: tgAllAmnsClass,
      category: '',
    );
    final repository = _PreviewRepository();
    await _capture(
      tester,
      name: 'tg_channel_filtered_grouped',
      label:
          '预览 · 假数据 · 原${raw.length}条：广告滤掉3条、重复去重1条、6集归成1张卡 · 剩${processed.items.length}张卡',
      screen: NeonChannelView(
        items: processed.items,
        repository: repository,
        categories: const [
          CatalogCategory('all', '全部频道'),
          CatalogCategory('pic', '🖼 图片'),
          CatalogCategory('ch1', '时光网'),
          CatalogCategory('ch2', '日本精品av'),
        ],
        selectedCategory: 'all',
        onCategory: (_) {},
        onOpen: (_) {},
        onBack: () {},
        onSearch: () {},
        onFilter: () {},
        onRankings: () {},
        onSwitchSource: () {},
        sourceLabel: '📡TG频道',
      ),
    );
  });
}
