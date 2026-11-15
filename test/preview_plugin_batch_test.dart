// 插件批界面改动预览截图：只做测试内截图，不改业务代码。
// 全部假数据；图标/emoji 在测试环境可能渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG；不要把多张放进同一个测试体。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/custom_sources_screen.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/import_center_screen.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/left_category_layout.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_playback.dart';
import 'package:moyi/live_repository.dart';
import 'package:moyi/live_screen.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/live_store.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/plugin_market_screen.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/sources_screen.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';
import 'real_fixture.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewThemeFor(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
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
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: 'PreviewCJK',
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: 'PreviewCJK'),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.filledButtonTheme.style?.textStyle?.resolve(
            states,
          );
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.textButtonTheme.style?.textStyle?.resolve(states);
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStateProperty.resolveWith((states) {
          final style = base.outlinedButtonTheme.style?.textStyle?.resolve(
            states,
          );
          return style?.copyWith(fontFamily: 'PreviewCJK');
        }),
      ),
    ),
  );
}

Future<LocalStore> _previewStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
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
  required AppThemeMode mode,
  required Widget screen,
  required String name,
  required String label,
  bool androidOverride = false,
  Future<void> Function()? beforeCapture,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  appThemeNotifier.value = mode;
  if (androidOverride) {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  }
  final key = GlobalKey();
  try {
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewThemeFor(mode),
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
    if (beforeCapture != null) {
      await beforeCapture();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
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
  } finally {
    appThemeNotifier.value = AppThemeMode.purpleNeon;
    if (androidOverride) debugDefaultTargetPlatformOverride = null;
  }
}

/// 封面返回空（占位），其余走 FixtureRepository 的合成数据。
class _CoverlessRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

/// 详情页推荐区仓库：detail_recommended_test 的 _RecommendRepository 同款。
class _RecommendRepository extends FixtureRepository {
  bool emptyCatalog = false;

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('cat1', '合成数据'),
    CatalogCategory('cat2', '其他分类'),
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
    if (emptyCatalog) return CatalogPage([]);
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

/// 直播假仓库：live_layout_test 的 _LayoutLiveRepository 同款。
class _PreviewLiveRepository extends LiveRepository {
  @override
  Future<List<LivePlatform>> platforms(
    LiveSource source, {
    bool force = false,
  }) async => [
    const LivePlatform(id: 'g1', name: '央视频道', count: 3),
    const LivePlatform(id: 'g2', name: '卫视频道', count: 2),
    const LivePlatform(id: 'g3', name: '电影频道', count: 2),
  ];

  @override
  Future<List<LiveChannel>> channels(
    LiveSource source,
    LivePlatform platform, {
    int page = 1,
    bool force = false,
  }) async {
    if (platform.id == 'g2') {
      return [
        LiveChannel(
          key: 'w1',
          name: '东方卫视',
          urls: const ['https://example.com/df.m3u8'],
          number: '004',
          group: '卫视频道',
          source: source.id,
          subtitle: '新闻联播',
        ),
        LiveChannel(
          key: 'w2',
          name: '江苏卫视',
          urls: const ['https://example.com/js.m3u8'],
          number: '005',
          group: '卫视频道',
          source: source.id,
          subtitle: '综艺大赏',
        ),
      ];
    }
    if (platform.id == 'g3') {
      return [
        LiveChannel(
          key: 'm1',
          name: 'CHC影迷电影',
          urls: const ['https://example.com/chc.m3u8'],
          number: '006',
          group: '电影频道',
          source: source.id,
          subtitle: '哥斯拉大战金刚',
        ),
        LiveChannel(
          key: 'm2',
          name: 'CHC动作电影',
          urls: const ['https://example.com/chc2.m3u8'],
          number: '007',
          group: '电影频道',
          source: source.id,
          subtitle: '动作大片连播',
        ),
      ];
    }
    return [
      LiveChannel(
        key: 'k1',
        name: 'CCTV13新闻',
        urls: const [
          'https://example.com/a1.m3u8',
          'https://example.com/a2.m3u8',
        ],
        number: '001',
        group: '央视频道',
        source: source.id,
        subtitle: '新闻调查',
      ),
      LiveChannel(
        key: 'k2',
        name: 'CCTV14少儿',
        urls: const ['https://example.com/b.m3u8'],
        number: '002',
        group: '央视频道',
        source: source.id,
        subtitle: '动画乐园',
      ),
      LiveChannel(
        key: 'k3',
        name: 'CCTV15音乐',
        urls: const ['https://example.com/c.m3u8'],
        number: '003',
        group: '央视频道',
        source: source.id,
        subtitle: '音乐厅现场',
      ),
    ];
  }

  @override
  Future<LivePlayback> playback(
    LiveSource source,
    LiveChannel channel,
  ) async => LivePlayback(url: channel.url);
}

/// 直播播放控制器替身：live_layout_test 的 _LayoutFakePlayback 同款。
class _PreviewFakePlayback extends LivePlaybackController {
  _PreviewFakePlayback({required super.repository})
    : _player = Player(platformPlayer: ScriptedPlayer());

  final Player _player;
  LiveSource? _source;
  List<LiveChannel> _channels = const [];
  int _index = 0;
  int _route = 0;
  LiveDecoderMode _decoderMode = LiveDecoderMode.auto;

  @override
  Player get player => _player;

  @override
  VideoController? get controller => null;

  @override
  LiveSource? get source => _source;

  @override
  List<LiveChannel> get channels => _channels;

  @override
  LiveChannel? get channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];

  @override
  int get index => _index;

  @override
  int get count => _channels.length;

  @override
  bool get loading => false;

  @override
  bool get buffering => false;

  @override
  String? get error => null;

  @override
  bool get ready => true;

  @override
  double get aspectRatio => 16 / 9;

  @override
  int get route => _route;

  @override
  LiveDecoderMode get decoderMode => _decoderMode;

  @override
  Future<void> load(
    LiveSource source,
    List<LiveChannel> channels, {
    int index = 0,
    bool autoplay = true,
  }) async {
    _source = source;
    _channels = List.of(channels);
    _index = channels.isEmpty ? 0 : index.clamp(0, channels.length - 1);
    notifyListeners();
  }

  @override
  Future<void> play(int index, {bool reconnect = false}) async {
    if (_channels.isEmpty) return;
    _index = index.clamp(0, _channels.length - 1);
    notifyListeners();
  }

  @override
  Future<void> playRoute(int route) async {
    _route = route < 0 ? 0 : route;
    await play(_index);
  }

  @override
  Future<void> setDecoderMode(LiveDecoderMode mode) async {
    _decoderMode = mode;
    notifyListeners();
  }

  @override
  Future<bool> resetDefaults() async {
    final changed = _route != 0 || _decoderMode != LiveDecoderMode.auto;
    _route = 0;
    _decoderMode = LiveDecoderMode.auto;
    notifyListeners();
    return changed;
  }

  @override
  Future<void> retry() => play(_index, reconnect: true);

  @override
  void switchBy(int delta) {
    if (_channels.isEmpty) return;
    _index = (_index + delta).clamp(0, _channels.length - 1);
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

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

  // 1. 插件市场：滚到远程区，本地尾巴 + 远程地址框 + 未设地址诚实提示同屏。
  testWidgets('预览 插件市场', (tester) async {
    final store = await _previewStore();
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: PluginMarketScreen(
        store: store,
        repository: FixtureRepository(),
      ),
      name: 'plugin_market',
      label: '预览 · 假数据 · 插件市场：本地插件 + 远程插件（未设地址的诚实提示）',
      androidOverride: true,
      beforeCapture: () async {
        final target = find.text(
          '未设置远程地址。填入插件索引 JSON 地址并保存，即可浏览远程插件。',
        );
        for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 100));
        }
        // 缓存区会提前建出提示文本：再往上滚 300px，让远程区标题+地址框+
        // 按钮+诚实提示真正进屏，上方留本地插件尾巴。
        await tester.drag(find.byType(ListView), const Offset(0, -300));
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });

  // 2. 设置内站点列表：平铺网格 + 插件图标（jar 咖啡杯 / py 爬虫）。
  testWidgets('预览 站点列表平铺', (tester) async {
    // 假数据替身：jar/py 站只在真机运行时注册进列表，测试里注册表是
    // 空的；手动种 4 个导入站，走真实的 pluginIconForSource 链路渲染。
    SourceSite.importedSites['jar:zakatv:FakeA'] = const SourceSite(
      'jar:zakatv:FakeA',
      'A 假 jar 站甲',
      '',
      origin: SourceSite.originImport,
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedSites['py:fakea'] = const SourceSite(
      'py:fakea',
      'A 假 py 站甲',
      '',
      origin: SourceSite.originImport,
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedSites['py:fakeb'] = const SourceSite(
      'py:fakeb',
      'A 假 py 站乙',
      '',
      origin: SourceSite.originImport,
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedSites['py:fakec'] = const SourceSite(
      'py:fakec',
      'A 假 py 站丙',
      '',
      origin: SourceSite.originImport,
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedPyFiles['py:fakea'] = 'fakea.py';
    SourceSite.importedPyFiles['py:fakeb'] = 'fakeb.py';
    SourceSite.importedPyFiles['py:fakec'] = 'fakec.py';
    JarBridge.register(
      const JarSiteSpec(
        siteId: 'jar:zakatv:FakeA',
        configId: 'zakatv',
        name: 'A 假 jar 站甲',
        className: 'com.example.Fake',
        jarUrl: '',
        jarMd5: '',
        ext: '',
      ),
    );
    final data = loadRealFixture();
    final store = await _previewStore();
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: SourcesScreen(
        repository: RealFixtureRepository(data),
        store: store,
        // initialSource 排最前且所在组自动展开：jar 假站必为桶内首张卡。
        initialSource: 'jar:zakatv:FakeA',
      ),
      name: 'settings_sites_tiled',
      label: '预览 · 假数据 · 站点列表平铺网格 + 插件图标（jar 咖啡杯 / py 爬虫）· 桶内 4 站为假数据',
      androidOverride: true,
      beforeCapture: () async {
        // 滚到“导入 · A”组头贴顶：首张 jar 卡 + 其后 py 卡同屏。
        // （需 --dart-define=ALL_SOURCES=true 跑，内置列表才完整。）
        for (var i = 0; i < 10; i++) {
          final header = find.text('导入 · A');
          if (header.evaluate().isEmpty) break;
          if (tester.getTopLeft(header).dy <= 60) break;
          await tester.drag(find.byType(ListView), const Offset(0, -300));
          await tester.pump(const Duration(milliseconds: 100));
        }
      },
    );
  });

  // 3. 通用设置：并入的五项 + 插件市场入口，无小程序分组。
  testWidgets('预览 通用设置合并', (tester) async {
    final store = await _previewStore();
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: SettingsScreen(
        repository: FixtureRepository(),
        store: store,
        onHideAdult: () {},
      ),
      name: 'settings_merged',
      label: '预览 · 假数据 · 通用设置：播放设置/播放器选择/解析接口/未成年保护已并入（内容源管理在下方同页）· 无小程序分组',
      androidOverride: true,
    );
  });

  // 4. 详情页：选集帧缩小一档 + 下方推荐视频区。
  testWidgets('预览 详情选集推荐', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: DetailScreen(
        drama: FixtureRepository.free,
        repository: _RecommendRepository(),
        store: store,
        playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
      ),
      name: 'detail_episodes_recommend',
      label: '预览 · 假数据 · 详情页：选集帧缩小一档 + 推荐视频区（本站视频、排除当前这部）',
      androidOverride: true,
      beforeCapture: () async {
        // 先展开选集区，让缩小一档的选集帧露出来。
        await tester.tap(find.text('展开'));
        await tester.pump(const Duration(milliseconds: 300));
        final target = find.text('推荐视频');
        for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
          await tester.drag(
            find.byType(CustomScrollView).first,
            const Offset(0, -500),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        // 往下滚 150px：选集帧仍在屏内，推荐卡多露出来。
        await tester.drag(
          find.byType(CustomScrollView).first,
          const Offset(0, -150),
        );
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  });

  // 5. 导入中心（内容源管理页）：一行简述 + 可展开说明行，运行状态一行。
  // 压缩落点是 CustomSourcesScreen（含 ImportCenterSection），非 ImportCenterScreen。
  testWidgets('预览 导入中心紧凑', (tester) async {
    final store = await _previewStore();
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: CustomSourcesScreen(
        repository: FixtureRepository(),
        store: store,
      ),
      name: 'import_center_compact',
      label: '预览 · 假数据 · 导入中心：一行简述 + 可展开说明行 · 运行状态一行',
      androidOverride: true,
    );
  });

  // 6. 抽屉顶 Tab：影视 / 阅读 / 小程序 / 多媒体 四个。
  testWidgets('预览 抽屉多媒体Tab', (tester) async {
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: AppDrawer(
        zone: HomeZone.library,
        currentVersion: '1.0.0+1',
        onZoneSelected: (_) {},
        onWatchRoom: () {},
        onTool: (_) {},
        onMinorProtectionChanged: (_) {},
        onMultimediaRequested: () {},
        appTheme: AppThemeMode.purpleNeon,
      ),
      name: 'drawer_multimedia_tab',
      label: '预览 · 假数据 · 抽屉顶 Tab 四个：影视 / 阅读 / 小程序 / 多媒体',
    );
  });

  // 7. 紫蓝霓虹主题下 3D 方块站点列表（选站弹窗，方块样式只随主题出现）。
  testWidgets('预览 3D方块列表', (tester) async {
    const groups = [
      SourcePickerGroup(
        title: '内置短剧',
        entries: [
          SourcePickerEntry(id: 'a', name: '甲站'),
          SourcePickerEntry(id: 'b', name: '乙站'),
          SourcePickerEntry(id: 'c', name: '丙站'),
          SourcePickerEntry(id: 'd', name: '丁站'),
        ],
      ),
      SourcePickerGroup(
        title: '内置影视',
        entries: [
          SourcePickerEntry(id: 'e', name: '戊站'),
          SourcePickerEntry(id: 'f', name: '己站'),
        ],
      ),
    ];
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => unawaited(
                showSitePickerDialog(
                  context,
                  sectionName: '片库',
                  currentId: 'b',
                  groups: groups,
                  repository: FixtureRepository(),
                ),
              ),
              child: const Text('打开选站'),
            ),
          ),
        ),
      ),
      name: 'cube_list',
      label: '预览 · 假数据 · 紫蓝霓虹主题：3D 方块站点列表（方块=站点、面=海报或站名占位、点进站）',
      beforeCapture: () async {
        await tester.tap(find.text('打开选站'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
      },
    );
  });

  // 8. 第 9 主题左侧分类：左一级纵栏 + 右顶部二级 + 筛选行 + 中间 3D 翻页卡堆。
  testWidgets('预览 左侧分类主题', (tester) async {
    const categories = [
      CatalogCategory.all,
      CatalogCategory('real', '真人剧'),
      CatalogCategory('comic', '漫剧'),
      CatalogCategory('movie', '电影'),
    ];
    const subCategories = [
      CatalogCategory('comedy', '喜剧'),
      CatalogCategory('fantasy', '玄幻'),
      CatalogCategory('love', '爱情'),
    ];
    const filterGroups = [
      CatalogFilterGroup('type', '类型', [
        CatalogFilterOption('action', '动作'),
        CatalogFilterOption('love', '爱情'),
      ]),
      CatalogFilterGroup('area', '地区', [
        CatalogFilterOption('cn', '大陆'),
        CatalogFilterOption('hk', '香港'),
      ]),
    ];
    final stackItems = [
      const Drama(id: 's:1', source: 's', title: '假剧甲', episodes: 12),
      const Drama(id: 's:2', source: 's', title: '假剧乙', episodes: 8),
      const Drama(id: 's:3', source: 's', title: '假剧丙', episodes: 20),
    ];
    await _capture(
      tester,
      mode: AppThemeMode.leftCategories,
      screen: LeftCategoryLayout(
        categories: categories,
        selectedCategory: '',
        onCategory: (_) {},
        subCategories: subCategories,
        filterGroups: filterGroups,
        selectedFilters: const {'type': ''},
        onFilter: (_, __) {},
        stackItems: stackItems,
        repository: _CoverlessRepository(),
        onOpen: (_) {},
        body: GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.all(8),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.72,
          children: [
            for (var i = 1; i <= 6; i++)
              Container(
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('假剧 $i'),
              ),
          ],
        ),
      ),
      name: 'left_categories_theme',
      label: '预览 · 假数据 · 左侧分类主题：左一级纵栏 + 右顶部二级 + 筛选行 + 3D 翻页卡堆 + 下方网格',
    );
  });

  // 9. 直播区新布局：视频区 + 功能键排 + 当前频道卡 + 左右双栏。
  testWidgets('预览 直播新布局', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final liveStore = LiveStore(prefs, 'default')..load();
    addTearDown(liveStore.dispose);
    final repository = _PreviewLiveRepository();
    final playback = _PreviewFakePlayback(repository: repository);
    addTearDown(playback.dispose);
    await _capture(
      tester,
      mode: AppThemeMode.purpleNeon,
      screen: LiveScreen(
        repository: repository,
        store: liveStore,
        greenMode: false,
        playbackController: playback,
        videoBuilder: (_, _) => Container(
          color: const Color(0xFF1A2B4A),
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_outline, size: 44, color: Colors.white70),
              SizedBox(height: 6),
              Text(
                '视频画面占位（假数据）',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      name: 'live_new_layout',
      label: '预览 · 假数据 · 直播新布局：视频区 + 功能键排 + 当前频道卡 + 左右双栏（左分组右频道）',
      beforeCapture: () async {
        for (
          var i = 0;
          i < 30 && find.text('CCTV13新闻').evaluate().isEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        // 排空 AppNotice 气泡（3 秒自动消失），避免盖住画面。
        await tester.pump(const Duration(milliseconds: 3500));
      },
    );
  });

  // 10. 青绿赛博主题：发光卡片一屏。
  testWidgets('预览 青绿赛博主题', (tester) async {
    final items = [
      const Drama(id: 'n:1', source: 'n', title: '假剧青', episodes: 12),
      const Drama(id: 'n:2', source: 'n', title: '假剧绿', episodes: 8),
      const Drama(id: 'n:3', source: 'n', title: '假剧赛', episodes: 20),
      const Drama(id: 'n:4', source: 'n', title: '假剧博', episodes: 5),
      const Drama(id: 'n:5', source: 'n', title: '假剧霓', episodes: 16),
      const Drama(id: 'n:6', source: 'n', title: '假剧虹', episodes: 3),
    ];
    await _capture(
      tester,
      mode: AppThemeMode.cyanCyberNeon,
      screen: NeonChannelView(
        items: items,
        repository: _CoverlessRepository(),
        categories: const [
          CatalogCategory('all', '全部'),
          CatalogCategory('hot', '热门'),
          CatalogCategory('new', '最新'),
        ],
        selectedCategory: 'all',
        onCategory: (_) {},
        onOpen: (_) {},
        onBack: () {},
        onSearch: () {},
        onFilter: () {},
        onRankings: () {},
        onSwitchSource: () {},
        sourceLabel: '假站点',
      ),
      name: 'neon_cyber_theme',
      label: '预览 · 假数据 · 青绿赛博主题：发光卡片 + 霓虹配色',
    );
  });
}
