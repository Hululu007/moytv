// 抽屉拆除批预览截图：只做测试内截图，不改业务代码。
// 全部假数据（FixtureRepository）；图标/emoji 在测试环境可能渲染为方块。
// 一测一张：调过 toImage 的测试在收尾时会挂起（旧预览测试同样如此，
// PNG 已落地），跑单测、看到 PNG 出现就杀掉；不要把多张放进同一个测试体。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:moyi/miniapp/mini_app_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

ThemeData _previewThemeFor(AppThemeMode mode) {
  final base = AppThemeConfig.forTheme(mode).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<LocalStore> _previewStore(Map<String, Object> seeds) async {
  SharedPreferences.setMockInitialValues(seeds);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 测试环境里 path_provider 没有平台实现，
/// getApplicationDocumentsDirectory() 永远不回，小程序页的播种链
/// 会一直转圈。只给预览测试 mock 一个真实临时目录，让页面的真实
/// 代码（读包内清单、解压内置包、列出已装）跑通；手机上有真实现，
/// 不受影响。
void _mockPathProvider() {
  const docsDir = '/tmp/moyi_preview_docs';
  Directory(docsDir).createSync(recursive: true);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          switch (call.method) {
            case 'getApplicationDocumentsDirectory':
            case 'getApplicationSupportDirectory':
            case 'getLibraryDirectory':
              return docsDir;
            case 'getTemporaryDirectory':
            case 'getCacheDirectory':
              return '/tmp';
            default:
              return null;
          }
        },
      );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
}

Future<void> _capturePng(
  WidgetTester tester, {
  required GlobalKey boundaryKey,
  required String name,
}) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GlobalKey> pumpShell(
    WidgetTester tester, {
    required String source,
    required String label,
    AppThemeMode mode = AppThemeMode.purpleNeon,
    bool androidOverride = false,
    Map<String, Object> extraSeeds = const {},
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appThemeNotifier.value = mode;
    if (androidOverride) {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    }
    final store = await _previewStore({
      'source': source,
      'hiddenSites': '[]',
      'appThemeMode': mode.name,
      ...extraSeeds,
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorObservers: [homeRouteObserver],
          theme: _previewThemeFor(mode),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Column(
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
                Expanded(
                  child: HomeScreen(
                    repository: FixtureRepository(),
                    store: store,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    return key;
  }

  testWidgets('预览 8标签霓虹胶囊栏', (tester) async {
    final key = await pumpShell(
      tester,
      source: 'huangdou',
      label: '预览·假数据 · 8 标签霓虹胶囊栏 · 小程序在第 6 位 · 游戏区在末尾 · 中间播放键开全屏流',
    );
    await _capturePng(tester, boundaryKey: key, name: 'shell_8tabs_neon');
  });

  testWidgets('预览 小程序标签页', (tester) async {
    // 预热静态快照：真设置 + 预览目录里已解好的 4 个内置包列出
    // 已装，走页面自带的热启动路径（手机上二次打开同一状态）。
    // 不预热时 _load 的文件 IO 在测试假异步区里永远不回、只转圈。
    await tester.runAsync(() async {
      final store = MiniAppStore(
        rootOverride: Directory('/tmp/moyi_preview_docs/miniapps'),
      );
      final installed = await store.listInstalled();
      MiniAppHomeCache.remember(
        settings: const MiniAppSettings(),
        installed: installed,
      );
    });
    addTearDown(MiniAppHomeCache.resetForTest);
    _mockPathProvider();
    final key = await pumpShell(
      tester,
      source: 'huangdou',
      label: '预览·假数据 · 小程序标签页 · 4 个内置小程序与导入入口',
      // 预览目录里 4 个内置包已按播种规则解好：prefs 记已播种，
      // 播种链跳过 59MB 大包的解压、直接列出已装（与手机上二次
      // 打开同一状态）。
      extraSeeds: {
        'moyi_miniapp_builtin_seeded_v1': true,
        'moyi_miniapp_builtin_seeded_ids_v1': [
          'com.ant.emby',
          'com.leospring.cms_t4_bridge',
          'com.leospring.source_t4_bridge',
          'com.leospring.drpy_node',
        ],
      },
    );
    // 小程序在第 4 位（2026-11-19 “我的”挪到最后一位后仍是 4；
    // 旧代码误点了 5 号“我的”，截图名却是小程序，随本次改对）。
    await tester.tap(find.byKey(const ValueKey('shell-tab-4')));
    await _settle(tester);
    await _capturePng(tester, boundaryKey: key, name: 'shell_miniapp_tab');
  });

  testWidgets('预览 单选择器频道页头', (tester) async {
    // missav 须先登记为导入站，否则站源落不到该站、进不了通用
    // 分支的玻璃顶栏（与 catalog_header_zones_test 同一口径）。
    SourceSite.importedSites['missav'] = SourceSite(
      'missav',
      'MissAV',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() => SourceSite.importedSites.remove('missav'));
    final key = await pumpShell(
      tester,
      source: 'missav',
      label: '预览·假数据 · 频道页头只有一个站源选择器 · 旧胶囊与下拉盒已删',
      androidOverride: true,
    );
    await _capturePng(tester, boundaryKey: key, name: 'shell_single_selector');
  });
}
