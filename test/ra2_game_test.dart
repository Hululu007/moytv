import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/ra2_game_page.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fixtures.dart';

/// 红警2网页游戏：桌面图标定义、导航放行判定、游戏页加载/失败/
/// 重试与无网址界面、桌面图标点按开窗口接线。
///
/// WebView 用假平台实现（与 mini_app 内嵌播放测试同一套做法），
/// 只覆盖页面自身的逻辑；真机 WebGL/声音/联机不在这里验。

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  final loadedUrls = <String>[];
  var reloadCalls = 0;

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
  Future<void> reload() async {
    reloadCalls++;
  }
}

class _FakePlatformWidget extends PlatformWebViewWidget {
  _FakePlatformWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: ValueKey('ra2-webview-placeholder'),
      color: Colors.black,
      child: Center(
        child: Text('游戏画面占位', style: TextStyle(color: Colors.white)),
      ),
    );
  }
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    this.onNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }

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
  _FakePlatformController? lastController;
  _FakeNavigationDelegate? lastDelegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return lastController = _FakePlatformController(params);
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
    return lastDelegate = _FakeNavigationDelegate(params);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebViewPlatform fakePlatform;

  setUp(() {
    fakePlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = fakePlatform;
  });

  group('game 窗口种类定义', () {
    test('title/icon/gradient 非空且符合约定', () {
      const kind = Win7WindowKind.game;
      expect(kind.title, '红警2');
      expect(kind.title, isNotEmpty);
      expect(kind.icon, Icons.sports_esports);
      expect(
        kind.iconGradient,
        const [Color(0xFFB91C1C), Color(0xFF7F1D1D)],
      );
      expect(kind.iconGradient.length, 2);
    });

    test('默认图标表含 game、multimedia 与 kof，mine 置顶第一位，kof 在末尾', () {
      expect(win7DesktopIcons.length, 9);
      expect(win7DesktopIcons, contains(Win7WindowKind.game));
      expect(win7DesktopIcons, contains(Win7WindowKind.multimedia));
      expect(win7DesktopIcons, contains(Win7WindowKind.kof));
      expect(win7DesktopIcons.first, Win7WindowKind.mine);
      expect(win7DesktopIcons.last, Win7WindowKind.kof);
    });

    test('已存顺序缺 game 时 resolve 会追加', () {
      // 老用户存下来的 7 个图标顺序（没 game、没 multimedia、没 kof）：
      // game、multimedia、kof 按默认相对顺序追加到末尾，不丢已有顺序。
      final resolved = resolveDesktopIconOrder([
        'mine',
        'actress',
        'library',
        'live',
        'audio',
        'novel',
        'miniApp',
      ]);
      expect(resolved.length, 9);
      expect(resolved.last, Win7WindowKind.kof);
      expect(resolved[resolved.length - 2], Win7WindowKind.multimedia);
      expect(resolved[resolved.length - 3], Win7WindowKind.game);
      expect(resolved.first, Win7WindowKind.mine);
    });
  });

  group('ra2NavigationAllowed', () {
    test('本站主机放行', () {
      expect(ra2NavigationAllowed('https://game.ra2web.com/'), isTrue);
      expect(
        ra2NavigationAllowed('https://game.ra2web.com/play?room=1'),
        isTrue,
      );
      expect(ra2NavigationAllowed('http://game.ra2web.com/'), isTrue);
    });

    test('站外与仿冒主机一律拦截', () {
      expect(ra2NavigationAllowed('https://evil.com/'), isFalse);
      expect(
        ra2NavigationAllowed('https://game.ra2web.com.evil.com/'),
        isFalse,
      );
      expect(ra2NavigationAllowed('https://www.game.ra2web.com/'), isFalse);
      expect(ra2NavigationAllowed('https://ra2web.com/'), isFalse);
      expect(ra2NavigationAllowed(''), isFalse);
      expect(ra2NavigationAllowed('not a url'), isFalse);
    });
  });

  group('Ra2GamePage', () {
    Future<void> pumpGame(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Ra2GamePage())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('加载游戏地址，界面上没有任何网址字串', (tester) async {
      await pumpGame(tester);
      expect(
        fakePlatform.lastController?.loadedUrls,
        ['https://game.ra2web.com/'],
      );
      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(find.byKey(const ValueKey('ra2-loading')), findsOneWidget);
      expect(find.textContaining('ra2web'), findsNothing);
      expect(find.textContaining('http'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('页面加载完成后面板消失', (tester) async {
      await pumpGame(tester);
      fakePlatform.lastDelegate?.onPageFinished?.call(
        'https://game.ra2web.com/',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ra2-loading')), findsNothing);
      expect(find.byKey(const ValueKey('ra2-retry-panel')), findsNothing);
    });

    testWidgets('主框架加载失败显示重试面板，点重试重新加载', (tester) async {
      await pumpGame(tester);
      fakePlatform.lastDelegate?.onWebResourceError?.call(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_NAME_NOT_RESOLVED',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ra2-retry-panel')), findsOneWidget);
      expect(find.textContaining('ra2web'), findsNothing);
      expect(find.textContaining('http'), findsNothing);
      expect(find.text('游戏加载失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ra2-retry-button')));
      await tester.pump();
      expect(fakePlatform.lastController?.reloadCalls, 1);
      expect(find.byKey(const ValueKey('ra2-retry-panel')), findsNothing);
      expect(find.byKey(const ValueKey('ra2-loading')), findsOneWidget);
    });

    testWidgets('子资源失败不弹重试面板', (tester) async {
      await pumpGame(tester);
      fakePlatform.lastDelegate?.onWebResourceError?.call(
        const WebResourceError(
          errorCode: 404,
          description: 'not found',
          isForMainFrame: false,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ra2-retry-panel')), findsNothing);
    });

    testWidgets('导航回调：站内放行、站外拦截', (tester) async {
      await pumpGame(tester);
      final callback = fakePlatform.lastDelegate?.onNavigationRequest;
      expect(callback, isNotNull);
      Future<NavigationDecision> decide(String url) async =>
          await callback!(
            NavigationRequest(url: url, isMainFrame: true),
          );
      expect(
        await decide('https://game.ra2web.com/play'),
        NavigationDecision.navigate,
      );
      expect(
        await decide('https://evil.com/'),
        NavigationDecision.prevent,
      );
      expect(
        await decide('https://game.ra2web.com.evil.com/'),
        NavigationDecision.prevent,
      );
    });
  });

  testWidgets('点游戏图标开红警2窗口：进全屏（任务栏与标题栏藏、退出钮在）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'source': 'huangdou',
      'hiddenSites': '[]',
      'appThemeMode': 'win7',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [homeRouteObserver],
        theme: AppThemeConfig.forTheme(AppThemeMode.win7).toThemeData(),
        home: HomeScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('win7-desktop-icon-game')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('win7-desktop')), findsNothing);
    // 进游戏即全屏（用户 2026-11-19 令）：标题栏与任务栏都藏，
    // 右上角悬浮退出钮；游戏页照常加载。
    expect(find.byKey(const ValueKey('win7-window-title')), findsNothing);
    expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
    expect(find.byKey(const ValueKey('win7-game-exit')), findsOneWidget);
    expect(find.byType(Ra2GamePage), findsOneWidget);
    expect(
      fakePlatform.lastController?.loadedUrls,
      ['https://game.ra2web.com/'],
    );
  });
}
