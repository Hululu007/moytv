import 'package:moyi/app_theme.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:moyi/player_screen.dart';
import 'package:moyi/settings_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  void phone(WidgetTester tester, [double width = 390]) {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
  }

  test(
    'theme survives restart',
    () async {
      final store = await localStore();
      expect(store.appTheme, AppThemeMode.purpleNeon);
      await store.setAppTheme(AppThemeMode.lightClean);
      final restored = LocalStore(store.preferences);
      expect(restored.appTheme, AppThemeMode.lightClean);
      store.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'default theme is purple neon and switching applies without restart',
    (tester) async {
      phone(tester);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final repository = FixtureRepository();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(MoyiApp(repository: repository));
      await tester.pump();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      final store = await localStore();
      await tester.pumpWidget(MoyiApp(repository: repository, store: store));
      await tester.pumpAndSettle();
      // 系统亮暗不影响主题：亮暗由主题自身底色定。
      for (final brightness in [Brightness.dark, Brightness.light]) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(HomeScreen))).brightness,
          Brightness.dark,
        );
      }
      await store.setAppTheme(AppThemeMode.lightClean);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(HomeScreen))).brightness,
        Brightness.light,
      );
      expect(
        LocalStore(store.preferences).appTheme,
        AppThemeMode.lightClean,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      // 让收尾时挂起的单次定时器（如 100ms 缓存刷新）在测试结束前跑完，
      // 否则框架会报仍有定时器挂起；回调都有 mounted 守卫，跑完即干净。
      await tester.pump(const Duration(seconds: 10));
      store.dispose();
    },
  );

  testWidgets('settings theme entry opens the picker and reflects the choice', (
    tester,
  ) async {
    phone(tester);
    final store = await localStore();
    final repository = FixtureRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(store.appTheme).toThemeData(),
        home: SettingsScreen(repository: repository, store: store),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('theme-settings-entry'));
    await tester.dragUntilVisible(
      entry,
      find.byType(Scrollable).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('紫蓝霓虹'), findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final themeCard = find.byKey(const ValueKey('app-theme-lightClean'));
    await tester.dragUntilVisible(
      themeCard,
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(themeCard);
    await tester.pumpAndSettle();
    expect(store.appTheme, AppThemeMode.lightClean);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('浅色清爽'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    store.dispose();
  });

  for (final count in [3, 4]) {
    testWidgets(
      '$count navigation destinations support large text and keyboard input',
      (tester) async {
        phone(tester, 320);
        final semantics = tester.ensureSemantics();
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: StatefulBuilder(
              builder: (context, setState) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  bottomNavigationBar: NavigationBar(
                    selectedIndex: selected,
                    onDestinationSelected: (value) =>
                        setState(() => selected = value),
                    destinations: [
                      const NavigationDestination(
                        icon: Icon(Icons.explore_outlined),
                        label: '发现',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.bookmark_border),
                        label: '追剧',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.history),
                        label: '最近观看',
                      ),
                      if (count == 4)
                        const NavigationDestination(
                          icon: Icon(Icons.download_outlined),
                          label: '下载',
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        final icons = [
          Icons.explore_outlined,
          Icons.bookmark_border,
          Icons.history,
          if (count == 4) Icons.download_outlined,
        ];
        for (var i = 0; i < count; i++) {
          await tester.tap(find.byIcon(icons[i]));
          await tester.pumpAndSettle();
          expect(selected, i);
        }
        for (var i = 0; i < count; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(selected, i);
        }
        expect(find.text('最近观看'), findsOneWidget);
        semantics.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'player shell follows light theme while video controls stay dark',
    (tester) async {
      phone(tester);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = await localStore();
      await store.setAppTheme(AppThemeMode.lightClean);
      final repository = RouteRepository();
      final platform = ScriptedPlayer();
      final detail = await repository.detail(FixtureRepository.free);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: PlayerScreen(
            detail: detail,
            initialIndex: 0,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: platform),
            videoBuilder: (controls) =>
                SizedBox(key: const ValueKey('video-theme'), child: controls),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('video-theme'))),
        ).brightness,
        Brightness.dark,
      );
      expect(
        Theme.of(tester.element(find.byType(PlayerScreen))).brightness,
        Brightness.light,
      );
      expect(
        SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
        Brightness.dark,
      );
      expect(
        SystemChrome.latestStyle?.systemNavigationBarContrastEnforced,
        isFalse,
      );
      expect(find.text('选集'), findsOneWidget);
      expect(find.byKey(const ValueKey('episode-chip-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      // 不查播放器是否释放：释放走异步链，在测试环境里跑不完，
      // 是播放器既有的释放链问题（player_screen_test 已 0/10 在先），
      // 与主题无关，释放覆盖归播放器测试管。
      expect(tester.takeException(), isNull);
      store.dispose();
    },
  );
}
