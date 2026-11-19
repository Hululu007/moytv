// 顶栏/任务栏压缩后的尺寸断言（用户 16:18 + 16:25 令）。
// 标题栏 40→32、任务栏 56→48、导航行 60→54、站源头行 46→40、
// 小程序顶栏 48→42；点按目标不小于 40px（胶囊 48、任务栏条目除外）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/neon/neon_ui.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:moyi/xp_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

ThemeData _theme(AppThemeMode mode) =>
    AppThemeConfig.forTheme(mode).toThemeData();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('win7 title bar 32 and taskbar 48', (tester) async {
    const childKey = ValueKey('shrink-frame-child');
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.win7),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: Win7WindowFrame(
              kind: Win7WindowKind.library,
              onMinimize: () {},
              onClose: () {},
              child: Container(key: childKey),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 内容顶边 = 标题栏高。
    expect(tester.getTopLeft(find.byKey(childKey)).dy, 32);
    // 最小化/关闭钮仍 28px，整体在标题栏内。
    expect(
      tester.getSize(find.byKey(const ValueKey('win7-window-minimize'))).height,
      28,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('win7-window-close'))).height,
      28,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.win7),
        home: Scaffold(
          body: Win7Taskbar(
            openWindows: const [Win7WindowKind.library],
            foreground: Win7WindowKind.library,
            onStartTap: () {},
            onEntryTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('win7-taskbar'))).height,
      48,
    );
  });

  testWidgets('xp title bar 32 and taskbar 48', (tester) async {
    const childKey = ValueKey('shrink-frame-child');
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.xpWindows),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: XpWindowFrame(
              kind: Win7WindowKind.library,
              onMinimize: () {},
              onClose: () {},
              child: Container(key: childKey),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(childKey)).dy, 32);

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.xpWindows),
        home: Scaffold(
          body: XpTaskbar(
            openWindows: const [Win7WindowKind.library],
            foreground: Win7WindowKind.library,
            onStartTap: () {},
            onEntryTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('xp-taskbar'))).height, 48);
  });

  testWidgets('neon top bar 40', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.win7),
        home: Scaffold(
          body: NeonTopBar(
            brand: '魔蚁box',
            subtitle: '红果 (1)',
            actions: const [NeonIconButton(icon: Icons.search, onTap: null)],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.getSize(find.byType(NeonTopBar)).height, 40);
  });

  testWidgets('miniapp top bar 42, tabs fit without overflow', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(AppThemeMode.win7),
        home: const MiniAppHomePage(),
      ),
    );
    await tester.pump();
    final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
    expect(appBar.preferredSize.height, 42);
    // Tab 高 38 + 指示条 3 = 41，收进 42 顶栏。
    expect(tester.getSize(find.byType(TabBar)).height, 41);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drama merged top bar 54: brand + chips + actions one row', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'source': 'hongguo',
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        theme: _theme(AppThemeMode.win7),
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-library')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 霓虹首页页签：合并顶栏代替单独的页签行与滚动区内的品牌顶栏。
    final merged = find.byKey(const ValueKey('drama-merged-topbar'));
    expect(merged, findsOneWidget);
    expect(find.byKey(const ValueKey('drama-internal-nav')), findsNothing);
    expect(find.byType(NeonTopBar), findsNothing);
    // 合并行 54 = 上边距 4 + 芯片 48 + 下边距 2，与原页签行同高。
    expect(tester.getSize(merged).height, 54);
    expect(
      tester.widget<Padding>(merged).padding,
      const EdgeInsets.fromLTRB(12, 4, 12, 2),
    );
    final chip = find.byKey(const ValueKey('drama-nav-home'));
    expect(tester.getSize(chip), const Size(48, 48));
    expect(find.text('魔蚁TV'), findsOneWidget);
    expect(find.byKey(const ValueKey('neon-avatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('neon-top-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('neon-top-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('neon-top-refresh')), findsOneWidget);
    // 品牌、芯片、搜索钮纵向重叠 = 同在一排、齐平。
    final brandRect = tester.getRect(find.text('魔蚁TV'));
    final chipRect = tester.getRect(chip);
    final searchRect = tester.getRect(
      find.byKey(const ValueKey('neon-top-search')),
    );
    // 只比纵向区间：三者在同一行里左右并排，Rect.overlaps 要求横向
    // 也相交，恒假；纵向重叠 = 同在一排、齐平。
    bool verticalOverlap(Rect a, Rect b) =>
        a.top < b.bottom && b.top < a.bottom;
    expect(verticalOverlap(brandRect, chipRect), isTrue);
    expect(verticalOverlap(chipRect, searchRect), isTrue);
    // 切到频道页签：合并行撤下，单独的页签行回来。
    await tester.tap(find.byKey(const ValueKey('drama-nav-channel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('drama-merged-topbar')), findsNothing);
    expect(find.byKey(const ValueKey('drama-internal-nav')), findsOneWidget);
  });
}
