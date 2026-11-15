import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/theme_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _makeStore([Map<String, Object> seeds = const {}]) async {
  SharedPreferences.setMockInitialValues(seeds);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('列表样式固定映射：紫蓝霓虹是方块，其余主题是普通', () {
    const expected = <AppThemeMode, SiteListStyle>{
      AppThemeMode.purpleNeon: SiteListStyle.cube,
      AppThemeMode.lightClean: SiteListStyle.normal,
      AppThemeMode.goldVip: SiteListStyle.normal,
      AppThemeMode.cyberBlue: SiteListStyle.normal,
      AppThemeMode.kidFamily: SiteListStyle.normal,
      AppThemeMode.minimalCard: SiteListStyle.normal,
      AppThemeMode.retroFilm: SiteListStyle.normal,
      AppThemeMode.tvBigScreen: SiteListStyle.normal,
      AppThemeMode.leftCategories: SiteListStyle.normal,
      AppThemeMode.cyanCyberNeon: SiteListStyle.normal,
      AppThemeMode.redBlackNeon: SiteListStyle.normal,
      AppThemeMode.pinkPurpleNeon: SiteListStyle.normal,
    };
    expect(expected.keys.toSet(), AppThemeMode.values.toSet());
    for (final mode in AppThemeMode.values) {
      expect(
        siteListStyleForTheme(mode),
        expected[mode],
        reason: mode.name,
      );
    }
  });

  test('导航样式固定映射：紫蓝霓虹底部标签、其余抽屉', () {
    for (final mode in AppThemeMode.values) {
      expect(
        navStyleForTheme(mode),
        mode == AppThemeMode.purpleNeon
            ? NavStyle.bottomTabs
            : NavStyle.drawer,
        reason: mode.name,
      );
    }
  });

  testWidgets('旧存储值解析兼容：导航段被忽略、内容档正确、不崩', (
    tester,
  ) async {
    final store = await _makeStore({
      'themeScheme_purpleNeon': 'drawer:manhua',
      'themeScheme_lightClean': 'bottomTabs',
      'themeScheme_goldVip': 'bogus:xx',
      'themeScheme_cyberBlue': 'drawer:adult',
      'themeScheme_kidFamily': '',
      'themeScheme_minimalCard': 'bottomTabs:adult:extra',
    });
    expect(
      store.displayScheme(AppThemeMode.purpleNeon),
      const ThemeDisplayScheme(
        navStyle: NavStyle.bottomTabs,
        contentTier: ContentTier.manhua,
      ),
    );
    expect(
      store.displayScheme(AppThemeMode.lightClean),
      const ThemeDisplayScheme.defaults(),
    );
    expect(
      store.displayScheme(AppThemeMode.goldVip),
      const ThemeDisplayScheme.defaults(),
    );
    expect(
      store.displayScheme(AppThemeMode.cyberBlue),
      const ThemeDisplayScheme(
        navStyle: NavStyle.drawer,
        contentTier: ContentTier.adult,
      ),
    );
    expect(
      store.displayScheme(AppThemeMode.kidFamily),
      const ThemeDisplayScheme.defaults(),
    );
    expect(
      store.displayScheme(AppThemeMode.minimalCard),
      const ThemeDisplayScheme(
        navStyle: NavStyle.drawer,
        contentTier: ContentTier.adult,
      ),
    );
    // 没存过值的主题同样回默认。
    expect(
      store.displayScheme(AppThemeMode.retroFilm),
      const ThemeDisplayScheme.defaults(),
    );
    // 存储解析器本身也忽略导航段。
    expect(
      ThemeDisplayScheme.fromStorageValue('bottomTabs:manhua'),
      const ThemeDisplayScheme(
        navStyle: NavStyle.drawer,
        contentTier: ContentTier.manhua,
      ),
    );
  });

  testWidgets('写显示方案时导航写值被固定值覆盖，内容档照常按主题存取', (
    tester,
  ) async {
    final store = await _makeStore();
    await store.setDisplayScheme(
      AppThemeMode.purpleNeon,
      const ThemeDisplayScheme(
        navStyle: NavStyle.drawer,
        contentTier: ContentTier.manhua,
      ),
    );
    expect(
      store.displayScheme(AppThemeMode.purpleNeon),
      const ThemeDisplayScheme(
        navStyle: NavStyle.bottomTabs,
        contentTier: ContentTier.manhua,
      ),
    );
    // 其它主题不受影响。
    expect(
      store.displayScheme(AppThemeMode.lightClean),
      const ThemeDisplayScheme.defaults(),
    );
    // 内容档改法不动：copyWith 只改内容档，导航仍是固定值。
    final scheme = store.displayScheme(AppThemeMode.purpleNeon);
    await store.setDisplayScheme(
      AppThemeMode.purpleNeon,
      scheme.copyWith(contentTier: ContentTier.adult),
    );
    expect(
      store.displayScheme(AppThemeMode.purpleNeon).contentTier,
      ContentTier.adult,
    );
    expect(
      store.displayScheme(AppThemeMode.purpleNeon).navStyle,
      NavStyle.bottomTabs,
    );
  });

  testWidgets('设置页没有独立的导航样式与列表样式控件', (tester) async {
    final store = await _makeStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData(),
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 页面本身正常泵出：外观主题入口还在。
    expect(find.text('外观主题'), findsOneWidget);
    expect(find.text('导航样式'), findsNothing);
    expect(find.byKey(const ValueKey('nav-style-entry')), findsNothing);
    expect(find.text('列表样式'), findsNothing);
  });

  testWidgets('主题设置页没有独立的导航样式与列表样式控件，内容档选择保留', (
    tester,
  ) async {
    final store = await _makeStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData(),
        home: ThemeSettingsScreen(store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('紫蓝霓虹'), findsOneWidget);
    expect(find.text('导航样式'), findsNothing);
    expect(find.text('列表样式'), findsNothing);
    expect(find.text('底部标签'), findsNothing);
    // 每张主题卡的内容档选择行保留。
    expect(find.text('显示内容：全部内容'), findsWidgets);
  });
}
