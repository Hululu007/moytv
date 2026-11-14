import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/bottom_tab_bar.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/import_center_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/sources_screen.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _pumpCoverFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _capture(
  WidgetTester tester, {
  required AppThemeMode mode,
  required Widget screen,
  required String name,
  required String label,
  bool androidOverride = false,
  bool coverFrames = false,
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
    if (coverFrames) {
      await _pumpCoverFrames(tester);
    }
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

  // 注意：本环境里调过 toImage 的测试在收尾时会挂起（旧
  // preview_screens_test 同样如此，PNG 已落地）。一测一张、超时杀掉
  // 只取 PNG；不要把多张放进同一个测试体（第 2 次 toImage 即挂）。
  for (final mode in [AppThemeMode.purpleNeon, AppThemeMode.lightClean]) {
    final suffix = mode.name;
    final themeName = AppThemeConfig.forTheme(mode).themeName;

    testWidgets('预览 设置页 $themeName', (tester) async {
      final data = loadRealFixture();
      final store = await _previewStore();
      await store.setAppTheme(mode);
      await _capture(
        tester,
        mode: mode,
        screen: SettingsScreen(
          repository: RealFixtureRepository(data),
          store: store,
        ),
        name: 'preview_settings_$suffix',
        label: '本页无站点数据，显示真实设置状态 · 安卓玻璃样式',
        androidOverride: true,
      );
    });

    testWidgets('预览 站点列表 $themeName', (tester) async {
      final data = loadRealFixture();
      final store = await _previewStore();
      await _capture(
        tester,
        mode: mode,
        screen: SourcesScreen(
          repository: RealFixtureRepository(data),
          store: store,
        ),
        name: 'preview_sources_$suffix',
        label: '站名/分组为真实内置登记 · 检测数据为未检测空态',
      );
    });

    testWidgets('预览 导入源 $themeName', (tester) async {
      final data = loadRealFixture();
      final store = await _previewStore();
      await _capture(
        tester,
        mode: mode,
        screen: ImportCenterScreen(
          repository: RealFixtureRepository(data),
          store: store,
        ),
        name: 'preview_import_$suffix',
        label: '未导入任何配置（真实空态）',
      );
    });

    testWidgets('预览 抽屉 $themeName', (tester) async {
      await _capture(
        tester,
        mode: mode,
        screen: AppDrawer(
          zone: HomeZone.library,
          currentVersion: '1.0.0+1',
          onZoneSelected: (_) {},
          onWatchRoom: () {},
          onTool: (_) {},
          onMinorProtectionChanged: (_) {},
          appTheme: mode,
        ),
        name: 'preview_drawer_$suffix',
        label: '抽屉导航 · 当前主题：$themeName',
      );
    });

    testWidgets('预览 频道侧栏 $themeName', (tester) async {
      final data = loadRealFixture();
      await _capture(
        tester,
        mode: mode,
        screen: NeonChannelView(
          items: data.items,
          repository: RealFixtureRepository(data),
          categories: data.categories,
          selectedCategory: '',
          onCategory: (_) {},
          onOpen: (_) {},
          onBack: () {},
          onSearch: () {},
          onFilter: () {},
          onRankings: () {},
          onSwitchSource: () {},
          sourceLabel: data.stationName,
        ),
        name: 'preview_channel_$suffix',
        label: '${data.sourceLabel} · 封面为测试环境占位',
        coverFrames: true,
      );
    });

    testWidgets('预览 底部导航 $themeName', (tester) async {
      final data = loadRealFixture();
      await _capture(
        tester,
        mode: mode,
        screen: Scaffold(
          body: NeonChannelView(
            items: data.items,
            repository: RealFixtureRepository(data),
            categories: data.categories,
            selectedCategory: '',
            onCategory: (_) {},
            onOpen: (_) {},
            onBack: () {},
            onSearch: () {},
            onFilter: () {},
            onRankings: () {},
            onSwitchSource: () {},
            sourceLabel: data.stationName,
          ),
          bottomNavigationBar: MoyiBottomTabBar(index: 0, onSelect: (_) {}),
        ),
        name: 'preview_bottomtab_$suffix',
        label: '${data.sourceLabel} · 底栏为新导航 · 片库选中 · 玻璃效果',
        coverFrames: true,
        androidOverride: true,
      );
    });

    testWidgets('预览 漫剧档空态 $themeName', (tester) async {
      // 6 个站实拉均无“漫剧”分类（柚子短剧 13 类、短剧窝、黑桃、
      // 金果等），漫剧档在此站的真实形态就是诚实空态，不造假数据。
      final data = loadRealFixture();
      final store = await _previewStore();
      await _capture(
        tester,
        mode: mode,
        screen: HongguoDramaHome(
          dramas: data.items,
          repository: RealFixtureRepository(data),
          store: store,
          onOpenDrama: (_) {},
          onOpenFeed: () {},
          onPickSource: () {},
          sourceLabel: data.stationName,
          feedEnabled: true,
          categories: data.categories,
          selectedCategory: '',
          onCategorySelected: (_) {},
          searchController: TextEditingController(),
          searchHint: '搜索',
          onSearchChanged: (_) {},
          onSearchSubmitted: (_) {},
          onOpenGlobalSearch: () {},
          onMenuPressed: () {},
          onFilterPressed: () {},
          onRankingsPressed: () {},
          onNewPressed: () {},
          filtersActive: false,
          newActive: false,
          onOpenSaved: ({required bool history}) {},
          contentTier: ContentTier.manhua,
          tierEmpty: true,
        ),
        name: 'preview_manhua_empty_$suffix',
        label: '${data.sourceLabel} · 实拉 13 个分类、无漫剧分类 · 漫剧档诚实空态',
      );
    });

    testWidgets('预览 主题选择 $themeName', (tester) async {
      final data = loadRealFixture();
      final store = await _previewStore();
      await store.setAppTheme(mode);
      await _capture(
        tester,
        mode: mode,
        screen: ThemeSettingsScreen(
          store: store,
          repository: RealFixtureRepository(data),
          sourceId: 'youzidj',
        ),
        name: 'preview_theme_$suffix',
        label: '${data.sourceLabel} · 每卡小预览为真实拉回内容 · 封面为测试环境占位',
        coverFrames: true,
      );
    });

    testWidgets('预览 抽屉主题行 $themeName', (tester) async {
      await _capture(
        tester,
        mode: mode,
        screen: AppDrawer(
          zone: HomeZone.library,
          currentVersion: '1.0.0+1',
          onZoneSelected: (_) {},
          onWatchRoom: () {},
          onTool: (_) {},
          onMinorProtectionChanged: (_) {},
          appTheme: mode,
        ),
        name: 'preview_drawer_theme_$suffix',
        label: '抽屉导航已向下滚动 · 主题切换行可见 · 当前主题：$themeName',
        beforeCapture: () async {
          await tester.drag(find.byType(ListView), const Offset(0, -520));
        },
      );
    });
  }
}
