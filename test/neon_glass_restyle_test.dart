import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/category_sidebar.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/import_center_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/neon_glass_kit.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/source_picker_sheet.dart';
import 'package:moyi/source_status.dart';
import 'package:moyi/sources_screen.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'real_fixture.dart';

const _longName = '这是一个名字非常非常长的分类名称应当完整显示不截断';

class _StatusRepository extends FixtureRepository {
  @override
  bool get supportsSourceManagement => true;

  @override
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({
        'source': source,
        'count': 3,
        'page': 2,
        'hasMore': true,
      });
}

Future<LocalStore> _store([Map<String, Object> seeds = const {}]) async {
  SharedPreferences.setMockInitialValues(seeds);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<void> _pumpThemed(
  WidgetTester tester,
  AppThemeMode mode,
  Widget child, {
  Size size = const Size(390, 844),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppThemeConfig.forTheme(mode).toThemeData(),
      home: Scaffold(body: child),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// 带真实封面的界面不用 pumpAndSettle：封面加载失败重试会一直排帧，
/// 只手动泵几帧（数据 Future 在第一帧后就绪，标题与分类名已渲染）。
Future<void> _pumpCoverFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpScreen(
  WidgetTester tester,
  AppThemeMode mode,
  Widget screen, {
  Size size = const Size(390, 844),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppThemeConfig.forTheme(mode).toThemeData(),
      home: screen,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// 断言 [finder] 命中的每个 Text 都没有省略号截断。
void _expectNoEllipsis(Finder finder) {
  expect(finder, findsWidgets);
  for (final element in finder.evaluate()) {
    final text = element.widget as Text;
    expect(
      text.overflow,
      isNot(TextOverflow.ellipsis),
      reason: '“${text.data}” 不应被截断',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('霓虹玻璃套件随主题变色', () {
    Future<void> pumpKit(WidgetTester tester, AppThemeMode mode) =>
        _pumpThemed(
          tester,
          mode,
          Column(
            children: [
              const NeonGlassCard(child: Text('卡片')),
              NeonCapsule(label: '已选胶囊', selected: true, onTap: () {}),
              NeonCapsule(label: '未选胶囊', selected: false, onTap: () {}),
              NeonSwitch(value: true, onChanged: (_) {}),
            ],
          ),
        );

    testWidgets('紫蓝霓虹下卡片与胶囊取当前主题色', (tester) async {
      await pumpKit(tester, AppThemeMode.purpleNeon);
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      final cardContainer =
          tester.widget<Container>(
                find
                    .descendant(
                      of: find.byType(NeonGlassCard),
                      matching: find.byType(Container),
                    )
                    .first,
              );
      expect(
        (cardContainer.decoration as BoxDecoration?)?.color,
        config.surfaceColor,
      );
      final selectedCapsule =
          find.descendant(
            of: find.byType(NeonCapsule).first,
            matching: find.byType(AnimatedContainer),
          );
      final capsuleDecoration =
          tester.widget<AnimatedContainer>(selectedCapsule).decoration
              as BoxDecoration?;
      expect(capsuleDecoration?.gradient, neonSelectedGradient(config));
      final capsuleText = tester.widget<Text>(find.text('已选胶囊'));
      expect(capsuleText.style?.color, config.selectedText);
      final unselectedText = tester.widget<Text>(find.text('未选胶囊'));
      expect(unselectedText.style?.color, config.unselectedText);
      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.activeTrackColor, config.primaryColor);
    });

    testWidgets('浅色清爽下卡片与胶囊取浅色主题色', (tester) async {
      await pumpKit(tester, AppThemeMode.lightClean);
      final config = AppThemeConfig.forTheme(AppThemeMode.lightClean);
      final neon = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      expect(config.surfaceColor, isNot(neon.surfaceColor));
      final cardContainer =
          tester.widget<Container>(
                find
                    .descendant(
                      of: find.byType(NeonGlassCard),
                      matching: find.byType(Container),
                    )
                    .first,
              );
      expect(
        (cardContainer.decoration as BoxDecoration?)?.color,
        config.surfaceColor,
      );
      final capsuleDecoration =
          tester.widget<AnimatedContainer>(
                find.descendant(
                  of: find.byType(NeonCapsule).first,
                  matching: find.byType(AnimatedContainer),
                ),
              ).decoration
              as BoxDecoration?;
      // 浅色主题没有现成渐变，套件用主色→辅色合成渐变。
      expect(
        capsuleDecoration?.gradient,
        LinearGradient(colors: [config.primaryColor, config.secondaryColor]),
      );
      final capsuleText = tester.widget<Text>(find.text('已选胶囊'));
      expect(capsuleText.style?.color, config.selectedText);
    });
  });

  group('分类侧栏全显', () {
    testWidgets('8 套主题侧栏长分类名都不截断且可点', (tester) async {
      for (final mode in AppThemeMode.values) {
        String? selected;
        await _pumpThemed(
          tester,
          mode,
          CategorySidebar(
            config: AppThemeConfig.forTheme(mode),
            items: const [
              CategorySidebarItem(id: 'long', name: _longName),
              CategorySidebarItem(id: 'short', name: '短名'),
            ],
            selectedId: 'long',
            onSelect: (id) => selected = id,
          ),
        );
        _expectNoEllipsis(find.text(_longName));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('短名'));
        expect(selected, 'short');
      }
    });

    testWidgets('复古胶片折叠样式长筛选名不截断', (tester) async {
      const longFilter = '这是一个名字非常长的筛选条件应当完整显示';
      await _pumpThemed(
        tester,
        AppThemeMode.retroFilm,
        CategorySidebar(
          config: AppThemeConfig.forTheme(AppThemeMode.retroFilm),
          items: const [
            CategorySidebarItem(
              id: 'movie',
              name: '电影',
              filters: [
                CategorySidebarFilter(name: longFilter, value: 'v'),
              ],
            ),
          ],
          selectedId: 'movie',
          onSelect: (_) {},
        ),
      );
      expect(find.text('筛选'), findsOneWidget);
      _expectNoEllipsis(find.text(longFilter));
      expect(tester.takeException(), isNull);
    });
  });

  group('抽屉', () {
    Future<List<AppDrawerTool>> pumpDrawer(
      WidgetTester tester, {
      AppThemeMode appTheme = AppThemeMode.purpleNeon,
    }) async {
      final tools = <AppDrawerTool>[];
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(appTheme).toThemeData(),
          home: Scaffold(
            body: AppDrawer(
              zone: HomeZone.library,
              currentVersion: '1.0.1',
              appTheme: appTheme,
              onZoneSelected: (_) {},
              onWatchRoom: () {},
              onTool: tools.add,
              onMinorProtectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tools;
    }

    testWidgets('主题切换入口显示当前主题名，点按上报工具', (tester) async {
      final tools = await pumpDrawer(tester, appTheme: AppThemeMode.lightClean);
      expect(find.text('主题切换'), findsOneWidget);
      expect(find.text('当前：浅色清爽 · 8 套主题'), findsOneWidget);
      await tester.tap(find.text('主题切换'));
      expect(tools, [AppDrawerTool.themeSettings]);
    });

    testWidgets('抽屉内文字一律不截断', (tester) async {
      await pumpDrawer(tester);
      for (final element
          in find
              .descendant(
                of: find.byType(AppDrawer),
                matching: find.byType(Text),
              )
              .evaluate()) {
        final text = element.widget as Text;
        expect(
          text.overflow,
          isNot(TextOverflow.ellipsis),
          reason: '“${text.data}” 不应被截断',
        );
      }
    });

    testWidgets('架签选中态用主题渐变，未选中用玻璃底', (tester) async {
      await pumpDrawer(tester);
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      final containers = find.descendant(
        of: find.byKey(const ValueKey('drawer-shelf-tabs')),
        matching: find.byType(AnimatedContainer),
      );
      expect(containers, findsNWidgets(4));
      var gradientCount = 0;
      var glassCount = 0;
      for (final element in containers.evaluate()) {
        final decoration =
            (element.widget as AnimatedContainer).decoration as BoxDecoration?;
        if (decoration?.gradient != null) {
          gradientCount++;
          expect(decoration?.gradient, neonSelectedGradient(config));
        } else if (decoration?.color == config.unselectedBg) {
          glassCount++;
        }
      }
      expect(gradientCount, 1);
      expect(glassCount, 3);
    });
  });

  group('站点切换列表', () {
    testWidgets('长站名完整显示，选中瓦片用主题渐变', (tester) async {
      const longStation = '这是一个名字非常长的站点名称应当完整显示';
      const groups = [
        SourcePickerGroup(
          title: '内置短剧',
          entries: [
            SourcePickerEntry(id: 'long', name: longStation),
            SourcePickerEntry(id: 'b', name: 'B站'),
          ],
        ),
      ];
      final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
      await tester.pumpWidget(
        MaterialApp(
          theme: config.toThemeData(),
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed:
                          () => showSitePickerDialog(
                            context,
                            sectionName: '短剧',
                            currentId: 'long',
                            groups: groups,
                          ),
                      child: const Text('打开'),
                    ),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      _expectNoEllipsis(find.text(longStation));
      final containers = find.descendant(
        of: find.byKey(const ValueKey('site-picker-row-long')),
        matching: find.byType(Container),
      );
      expect(containers, findsWidgets);
      final hasGradient = containers.evaluate().any((element) {
        final decoration =
            (element.widget as Container).decoration as BoxDecoration?;
        return decoration?.gradient != null;
      });
      expect(hasGradient, isTrue);
    });
  });

  group('设置页', () {
    testWidgets('玻璃路径主题入口可点并到达主题选择界面', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      try {
        final store = await _store();
        await _pumpScreen(
          tester,
          AppThemeMode.purpleNeon,
          SettingsScreen(repository: FixtureRepository(), store: store),
          settle: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final entry = find.byKey(const ValueKey('theme-settings-entry'));
        expect(entry, findsOneWidget);
        await tester.ensureVisible(entry);
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byType(ThemeSettingsScreen), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('iOS 分支能构建且有主题入口', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      try {
        final store = await _store();
        await _pumpScreen(
          tester,
          AppThemeMode.purpleNeon,
          SettingsScreen(repository: FixtureRepository(), store: store),
          settle: false,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('theme-settings-entry')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('抽屉主题入口打开主题选择界面', (tester) async {
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('open-app-drawer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final entry = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('主题切换'),
    );
    expect(entry, findsOneWidget);
    await tester.ensureVisible(entry);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(ThemeSettingsScreen), findsOneWidget);
  }, skip: !allSourcesEnabled);

  group('主题卡片真实内容', () {
    testWidgets('卡片显示真实拉回的分类名与视频标题', (tester) async {
      final data = loadRealFixture();
      final store = await _store();
      await _pumpScreen(
        tester,
        AppThemeMode.purpleNeon,
        ThemeSettingsScreen(
          store: store,
          repository: RealFixtureRepository(data),
          sourceId: data.station,
        ),
        size: const Size(390, 1600),
        settle: false,
      );
      await _pumpCoverFrames(tester);
      expect(find.text(data.items.first.title), findsNWidgets(8));
      expect(find.text(data.categories[1].name), findsWidgets);
      expect(find.text('内容未加载'), findsNothing);
      expect(find.text('紫蓝霓虹'), findsOneWidget);
    });

    testWidgets('没有仓库时卡片只显示配色，不造内容', (tester) async {
      final data = loadRealFixture();
      final store = await _store();
      await _pumpScreen(
        tester,
        AppThemeMode.purpleNeon,
        ThemeSettingsScreen(store: store),
      );
      expect(find.text('紫蓝霓虹'), findsOneWidget);
      expect(find.text(data.items.first.title), findsNothing);
      expect(find.text('内容未加载'), findsNothing);
    });

    testWidgets('仓库拉取失败时卡片诚实显示未加载', (tester) async {
      final store = await _store();
      final repository = FixtureRepository()..fail = true;
      await _pumpScreen(
        tester,
        AppThemeMode.purpleNeon,
        ThemeSettingsScreen(
          store: store,
          repository: repository,
          sourceId: 'youzidj',
        ),
      );
      expect(find.text('紫蓝霓虹'), findsOneWidget);
      expect(find.text('内容未加载'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('频道侧栏与筛选胶囊', () {
    testWidgets('两套主题下选中胶囊渐变随主题走，长分类名不截断', (
      tester,
    ) async {
      final data = loadRealFixture();
      for (final mode in [AppThemeMode.purpleNeon, AppThemeMode.lightClean]) {
        final config = AppThemeConfig.forTheme(mode);
        await _pumpThemed(
          tester,
          mode,
          NeonChannelView(
            items: data.items,
            repository: RealFixtureRepository(data),
            categories: [
              CatalogCategory('long', _longName),
              const CatalogCategory('c1', '冒险'),
            ],
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
          settle: false,
        );
        await _pumpCoverFrames(tester);
        expect(find.text(data.stationName), findsOneWidget);
        final capsule = find.ancestor(
          of: find.text('热门').first,
          matching: find.byType(NeonCapsule),
        );
        final capsuleDecoration =
            tester.widget<AnimatedContainer>(
                  find.descendant(
                    of: capsule,
                    matching: find.byType(AnimatedContainer),
                  ),
                ).decoration
                as BoxDecoration?;
        expect(capsuleDecoration?.gradient, neonSelectedGradient(config));
        _expectNoEllipsis(find.text(_longName));
        expect(tester.takeException(), isNull);
      }
    });
  });

  testWidgets('站点列表分组卡取当前主题面色', (tester) async {
    final store = await _store();
    await _pumpScreen(
      tester,
      AppThemeMode.purpleNeon,
      SourcesScreen(repository: _StatusRepository(), store: store),
    );
    final config = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
    expect(find.byType(NeonGlassCard), findsWidgets);
    final cardContainer =
        tester.widget<Container>(
              find
                  .descendant(
                    of: find.byType(NeonGlassCard).first,
                    matching: find.byType(Container),
                  )
                  .first,
            );
    expect(
      (cardContainer.decoration as BoxDecoration?)?.color,
      config.surfaceColor,
    );
  });

  testWidgets('导入中心分区标题与导入入口齐全', (tester) async {
    final store = await _store();
    await _pumpScreen(
      tester,
      AppThemeMode.purpleNeon,
      ImportCenterScreen(repository: FixtureRepository(), store: store),
    );
    expect(find.text('TVBox 配置（0）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('import-center-file')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('import-center-url')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
