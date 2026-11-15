import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/app_drawer.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/settings_screen.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 站点区/频道页与全局界面跟主题测试：切主题后卡片边框/角标/副标题
///
/// 色、抽屉底色、设置页与详情页外壳底色确实变了。只写代码不运行，
/// 由父代理统一验证。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelItems = [
    Drama(
      id: 's1:1',
      source: 's1',
      title: '频道剧甲',
      cover: 'https://x.test/a.jpg',
      episodes: 12,
      tags: ['动作', '爱情'],
    ),
    Drama(
      id: 's1:2',
      source: 's1',
      title: '频道剧乙',
      cover: 'https://x.test/b.jpg',
      episodes: 8,
      tags: ['喜剧'],
    ),
    Drama(
      id: 's1:3',
      source: 's1',
      title: '频道剧丙',
      cover: 'https://x.test/c.jpg',
      episodes: 20,
    ),
  ];

  Future<void> mountChannel(
    WidgetTester tester, {
    required AppThemeMode mode,
    void Function(Drama)? onOpen,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(mode).toThemeData(),
        home: Scaffold(
          body: NeonChannelView(
            items: channelItems,
            repository: FixtureRepository(),
            categories: const [CatalogCategory.all],
            selectedCategory: '',
            onCategory: (_) {},
            onOpen: onOpen ?? (_) {},
            onBack: () {},
            onSearch: () {},
            onFilter: () {},
            onRankings: () {},
          ),
        ),
      ),
    );
    // 换主题走 AnimatedTheme 约 200ms 插值动画：单帧 pump 时新主题
    // 还没插值到位（AppThemeConfig.of 仍读旧主题），须泵够时长。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Color firstPosterBorder(WidgetTester tester) {
    final box = find.descendant(
      of: find.byType(NeonPoster).first,
      matching: find.byType(Container),
    );
    final decoration =
        tester.widget<Container>(box.first).decoration! as BoxDecoration;
    return decoration.border!.top.color;
  }

  testWidgets('频道页卡片边框与角标跟主题变', (tester) async {
    await mountChannel(tester, mode: AppThemeMode.purpleNeon);
    final purple = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
    expect(firstPosterBorder(tester), purple.cardBorderColor);
    // 角标：HD 取辅色，NEW 取点缀色。
    expect(
      tester.widget<NeonBadge>(find.widgetWithText(NeonBadge, 'HD')).color,
      purple.secondaryColor,
    );
    expect(
      tester.widget<NeonBadge>(find.widgetWithText(NeonBadge, 'NEW')).color,
      purple.accentColor,
    );
    final purpleSubtitle = tester
        .widget<Text>(find.text('动作 · 爱情'))
        .style!
        .color;
    expect(purpleSubtitle, purple.textSecondary);

    await mountChannel(tester, mode: AppThemeMode.lightClean);
    final light = AppThemeConfig.forTheme(AppThemeMode.lightClean);
    expect(firstPosterBorder(tester), light.cardBorderColor);
    expect(firstPosterBorder(tester), isNot(purple.cardBorderColor));
    expect(
      tester.widget<NeonBadge>(find.widgetWithText(NeonBadge, 'HD')).color,
      light.secondaryColor,
    );
    expect(
      tester.widget<NeonBadge>(find.widgetWithText(NeonBadge, 'NEW')).color,
      light.accentColor,
    );
    expect(
      tester.widget<Text>(find.text('动作 · 爱情')).style!.color,
      light.textSecondary,
    );
    expect(
      tester.widget<Text>(find.text('动作 · 爱情')).style!.color,
      isNot(purpleSubtitle),
    );
  });

  testWidgets('频道页点卡进详情回调、集数标签不重影', (tester) async {
    final opened = <Drama>[];
    await mountChannel(tester, mode: AppThemeMode.purpleNeon, onOpen: opened.add);
    // 封面集数标已压住，只剩副标题一处“20 集”。
    expect(find.text('20 集'), findsOneWidget);
    // 点卡片左上角：桩仓库的封面一律失败，卡片中心是失败重试钮，
    // 点中心只触发重试、不会进详情（既有行为）；点卡片其余位置进详情。
    final tile = find.byKey(const ValueKey('neon-tile-s1:3'));
    await tester.tapAt(tester.getTopLeft(tile) + const Offset(20, 20));
    expect(opened.map((d) => d.id).toList(), ['s1:3']);
  });

  testWidgets('抽屉底色跟主题变', (tester) async {
    final previousMode = appThemeNotifier.value;
    addTearDown(() => appThemeNotifier.value = previousMode);
    Future<Color?> drawerBg(AppThemeMode mode) async {
      // 抽屉霓虹分支读全局 appThemeNotifier，只换 ThemeData 不够。
      appThemeNotifier.value = mode;
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(mode).toThemeData(),
          home: Scaffold(
            body: AppDrawer(
              zone: HomeZone.library,
              currentVersion: '1.0.1',
              appTheme: mode,
              onZoneSelected: (_) {},
              onWatchRoom: () {},
              onTool: (_) {},
              onMinorProtectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.widget<Drawer>(find.byType(Drawer)).backgroundColor;
    }

    // 非霓虹主题：抽屉底 = 主题背景色，两套主题值不同。
    final lightBg = await drawerBg(AppThemeMode.lightClean);
    expect(
      lightBg,
      AppThemeConfig.forTheme(AppThemeMode.lightClean).backgroundColor,
    );
    final goldBg = await drawerBg(AppThemeMode.goldVip);
    expect(
      goldBg,
      AppThemeConfig.forTheme(AppThemeMode.goldVip).backgroundColor,
    );
    expect(goldBg, isNot(lightBg));
  });

  testWidgets('设置页与详情页外壳底色跟主题变', (tester) async {
    Future<LocalStore> freshStore() async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      return store;
    }

    Future<Color> settingsShellBg(AppThemeMode mode) async {
      final store = await freshStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(mode).toThemeData(),
          home: SettingsScreen(
            repository: FixtureRepository(),
            store: store,
          ),
        ),
      );
      // 换主题走 AnimatedTheme 约 200ms 插值动画，泵够时长再读底色。
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 设置页 Scaffold 不写死底色，生效底色即主题 scaffoldBackgroundColor。
      return Theme.of(
        tester.element(find.byType(SettingsScreen)),
      ).scaffoldBackgroundColor;
    }

    Future<Color> detailShellBg(AppThemeMode mode) async {
      final store = await freshStore();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemeConfig.forTheme(mode).toThemeData(),
          home: DetailScreen(
            drama: FixtureRepository.free,
            repository: FixtureRepository(),
            store: store,
            playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // 详情页主 Scaffold 不写死底色，生效底色即主题 scaffoldBackgroundColor。
      return Theme.of(
        tester.element(find.byType(DetailScreen)),
      ).scaffoldBackgroundColor;
    }

    final purple = AppThemeConfig.forTheme(AppThemeMode.purpleNeon);
    final light = AppThemeConfig.forTheme(AppThemeMode.lightClean);
    expect(await settingsShellBg(AppThemeMode.purpleNeon), purple.backgroundColor);
    expect(await settingsShellBg(AppThemeMode.lightClean), light.backgroundColor);
    expect(await detailShellBg(AppThemeMode.purpleNeon), purple.backgroundColor);
    expect(await detailShellBg(AppThemeMode.lightClean), light.backgroundColor);
    expect(purple.backgroundColor, isNot(light.backgroundColor));
  });
}
