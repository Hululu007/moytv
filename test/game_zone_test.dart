// 游戏区（用户 2026-11-19 令）：底部标签第 8 位（演员库之后）、
// Win7/XP 开始菜单末尾单叶、区里红警2/拳皇97 两张卡；点卡进游戏
// 自动全屏——系统栏 + 底部标签栏/任务栏一起藏，退出时全部恢复。
// WebView 用假平台实现（与 kof_game_test 同一套做法），只覆盖
// 页面自身的逻辑；真机全屏与触控手感不在这里验。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/game_zone_page.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/web_game_page.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fixtures.dart';

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  final loadedUrls = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUrls.add(params.uri.toString());
  }

  @override
  Future<void> reload() async {}
}

class _FakePlatformWidget extends PlatformWebViewWidget {
  _FakePlatformWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: ValueKey('game-webview-placeholder'),
      color: Colors.black,
      child: Center(
        child: Text('游戏画面占位', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}

  @override
  Future<void> setOnHttpAuthRequest(
    HttpAuthRequestCallback onHttpAuthRequest,
  ) async {}

  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return _FakePlatformController(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformWidget(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _FakeNavigationDelegate(params);
  }
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

Future<LocalStore> _pumpHome(
  WidgetTester tester, {
  required AppThemeMode mode,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({
    'source': 'huangdou',
    'hiddenSites': '[]',
    'appThemeMode': mode.storageValue,
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [homeRouteObserver],
      theme: AppThemeConfig.forTheme(mode).toThemeData(),
      home: HomeScreen(repository: FixtureRepository(), store: store),
    ),
  );
  await _settle(tester);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  group('游戏区两款游戏数据', () {
    test('红警2 与拳皇97 地址/主机/前缀各不相同', () {
      expect(GameZoneGame.values.length, 2);
      expect(GameZoneGame.ra2.title, '红警2');
      expect(GameZoneGame.ra2.url, 'https://game.ra2web.com/');
      expect(GameZoneGame.ra2.host, 'game.ra2web.com');
      expect(GameZoneGame.ra2.keyPrefix, 'ra2');
      expect(GameZoneGame.kof.title, '拳皇97');
      // 拳皇97 真地址是 play?id=5326（4481 是超级运动会，已纠正过）。
      expect(GameZoneGame.kof.url, 'https://www.yikm.net/play?id=5326');
      expect(GameZoneGame.kof.host, 'www.yikm.net');
      expect(GameZoneGame.kof.keyPrefix, 'kof');
      expect(GameZoneGame.ra2.url, isNot(GameZoneGame.kof.url));
    });

    test('游戏区窗口种类：标题游戏区、金色渐变、不进桌面图标表', () {
      const kind = Win7WindowKind.gameZone;
      expect(kind.title, '游戏区');
      expect(kind.icon, Icons.sports_esports);
      expect(
        kind.iconGradient,
        const [Color(0xFFEAB308), Color(0xFFA16207)],
      );
      // 桌面图标还是两个游戏各自的，游戏区只走底部标签与开始菜单。
      expect(win7DesktopIcons.contains(kind), isFalse);
      expect(win7DesktopIcons.length, 9);
    });
  });

  group('游戏区页', () {
    testWidgets('两张卡在位，点卡回传对应的游戏', (tester) async {
      final picked = <GameZoneGame>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GameZonePage(onGameSelected: picked.add),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('game-zone-card-ra2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('game-zone-card-kof')),
        findsOneWidget,
      );
      expect(find.text('红警2'), findsOneWidget);
      expect(find.text('拳皇97'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('game-zone-card-kof')));
      await tester.pump();
      expect(picked, [GameZoneGame.kof]);
      await tester.tap(find.byKey(const ValueKey('game-zone-card-ra2')));
      await tester.pump();
      expect(picked, [GameZoneGame.kof, GameZoneGame.ra2]);
    });
  });

  group('全屏游戏屏（普通壳）', () {
    testWidgets('进屏发沉浸式、退出钮在、点退出回上一页并恢复系统栏',
        (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const FullscreenGameScreen(
                      title: '拳皇97',
                      gameUrl: 'https://www.yikm.net/play?id=5326',
                      allowedHost: 'www.yikm.net',
                      keyPrefix: 'kof',
                    ),
                  ),
                ),
                child: const Text('进游戏'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('进游戏'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fullscreen-game-exit')), findsOneWidget);
      expect(find.byKey(const ValueKey('game-webview-placeholder')), findsOneWidget);
      // 进屏发沉浸式（系统状态栏 + 导航栏一起藏）。
      expect(
        calls.any(
          (c) =>
              c.method == 'SystemChrome.setEnabledSystemUIMode' &&
              c.arguments.toString().contains('immersiveSticky'),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('fullscreen-game-exit')));
      await _settle(tester);
      expect(find.text('进游戏'), findsOneWidget);
      // 退出恢复系统栏（与 main.dart 启动态一致）。
      expect(
        calls.any(
          (c) =>
              c.method == 'SystemChrome.setEnabledSystemUIMode' &&
              c.arguments.toString().contains('edgeToEdge'),
        ),
        isTrue,
      );
    });
  });

  group('普通壳：底部标签游戏区', () {
    testWidgets('点底部游戏区标签出两张卡，点卡进全屏、点退出回区里',
        (tester) async {
      await _pumpHome(tester, mode: AppThemeMode.purpleNeon);
      await tester.tap(find.text('游戏区').first);
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('game-zone-card-ra2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('game-zone-card-kof')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('game-zone-card-kof')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('fullscreen-game-exit')), findsOneWidget);
      expect(find.byKey(const ValueKey('game-webview-placeholder')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fullscreen-game-exit')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('game-zone-card-kof')),
        findsOneWidget,
      );
    });
  });

  group('Win7 桌面壳：进游戏全屏', () {
    testWidgets('点拳皇97桌面图标：任务栏与标题栏藏、退出钮在；点退出回桌面',
        (tester) async {
      await _pumpHome(tester, mode: AppThemeMode.win7);
      expect(find.byKey(const ValueKey('win7-taskbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('win7-desktop')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-kof')));
      await _settle(tester);
      // 三种栏里任务栏已藏（系统栏走沉浸式、标题栏强制藏）。
      expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
      expect(find.byKey(const ValueKey('win7-window-title')), findsNothing);
      expect(find.byKey(const ValueKey('win7-game-exit')), findsOneWidget);
      expect(find.byKey(const ValueKey('game-webview-placeholder')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('win7-game-exit')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('win7-taskbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('win7-desktop')), findsOneWidget);
      expect(find.byKey(const ValueKey('win7-game-exit')), findsNothing);
    });

    testWidgets('开始菜单末尾有游戏区单叶，点它开游戏区窗口', (tester) async {
      await _pumpHome(tester, mode: AppThemeMode.win7);
      await tester.tap(find.byKey(const ValueKey('win7-start-button')));
      await _settle(tester);
      expect(find.text('游戏区'), findsOneWidget);
      await tester.tap(find.text('游戏区'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('game-zone-card-kof')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('win7-taskbar-entry-gameZone')),
        findsOneWidget,
      );
      // 游戏区窗口里点卡开拳皇97窗、进全屏。
      await tester.tap(find.byKey(const ValueKey('game-zone-card-kof')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
      expect(find.byKey(const ValueKey('win7-game-exit')), findsOneWidget);
    });
  });

  group('XP 桌面壳：进游戏全屏', () {
    testWidgets('点拳皇97桌面图标：任务栏藏、退出钮在；点退出回桌面',
        (tester) async {
      await _pumpHome(tester, mode: AppThemeMode.xpWindows);
      expect(find.byKey(const ValueKey('xp-taskbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('xp-desktop')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('xp-desktop-icon-kof')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('xp-taskbar')), findsNothing);
      expect(find.byKey(const ValueKey('xp-window-title')), findsNothing);
      expect(find.byKey(const ValueKey('win7-game-exit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('win7-game-exit')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('xp-taskbar')), findsOneWidget);
      expect(find.byKey(const ValueKey('xp-desktop')), findsOneWidget);
    });
  });
}
