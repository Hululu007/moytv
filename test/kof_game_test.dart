import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/action_protocol.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/py_contract.dart';
import 'package:moyi/site_homepages.dart';
import 'package:moyi/web_game_page.dart';
import 'package:moyi/win7_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fixtures.dart';

/// 拳皇97 桌面图标 + 小霸王游戏源动作协议：kof 窗口种类定义、
// 桌面图标表与旧顺序合并、导航放行判定、动作 JSON 解析、
// PyContract 动作映射、通用游戏窗加载/失败/重试与无网址界面、
// 动作导航开游戏屏、桌面图标点按开拳皇97 窗口、yikm 内置注册。
///
/// WebView 用假平台实现（与 ra2_game_test 同一套做法），只覆盖
/// 页面自身的逻辑；真机触控手感与模拟器运行不在这里验。

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  final loadedUrls = <String>[];
  var lastHeaders = <String, String>{};
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
    lastHeaders = Map<String, String>.from(params.headers);
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
      key: ValueKey('kof-webview-placeholder'),
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

const _kofActionJson =
    '{"actionId":"browser","type":"browser","title":"拳皇97",'
    '"url":"https://www.yikm.net/play?id=5326",'
    '"header":{"User-Agent":"test-ua"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebViewPlatform fakePlatform;

  setUp(() {
    fakePlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = fakePlatform;
  });

  group('kof 窗口种类定义', () {
    test('title/icon/gradient 非空且与红警2区分', () {
      const kind = Win7WindowKind.kof;
      expect(kind.title, '拳皇97');
      expect(kind.icon, Icons.sports_esports);
      expect(kind.iconGradient, const [Color(0xFF14B8A6), Color(0xFF0F766E)]);
      expect(kind.iconGradient.length, 2);
      expect(kind.iconGradient, isNot(Win7WindowKind.game.iconGradient));
    });

    test('默认图标表 9 个，kof 在末尾（网盘之后）', () {
      expect(win7DesktopIcons.length, 9);
      expect(win7DesktopIcons.last, Win7WindowKind.kof);
      expect(
        win7DesktopIcons[win7DesktopIcons.length - 2],
        Win7WindowKind.multimedia,
      );
      expect(win7DesktopIcons.first, Win7WindowKind.mine);
    });

    test('已存 8 个顺序缺 kof 时 resolve 追加到末尾、不动已有顺序', () {
      final stored = [
        'mine',
        'listenRead',
        'library',
        'live',
        'miniApp',
        'actress',
        'game',
        'multimedia',
      ];
      final resolved = resolveDesktopIconOrder(stored);
      expect(resolved.length, 9);
      expect(resolved.sublist(0, 8).map((kind) => kind.name).toList(), stored);
      expect(resolved.last, Win7WindowKind.kof);
    });

    test('全部图标渐变色互不相同', () {
      final gradients = Win7WindowKind.values
          .map((kind) => kind.iconGradient.join(','))
          .toSet();
      expect(gradients.length, Win7WindowKind.values.length);
    });
  });

  group('webGameNavigationAllowed', () {
    test('本站主机放行（含 http 与大小写）', () {
      expect(
        webGameNavigationAllowed(
          'https://www.yikm.net/play?id=5326',
          'www.yikm.net',
        ),
        isTrue,
      );
      expect(
        webGameNavigationAllowed('http://www.yikm.net/nes', 'www.yikm.net'),
        isTrue,
      );
      expect(
        webGameNavigationAllowed('https://WWW.YIKM.NET/play', 'www.yikm.net'),
        isTrue,
      );
    });

    test('站外主机拦截（含后缀冒充与子域）', () {
      expect(
        webGameNavigationAllowed('https://evil.com/', 'www.yikm.net'),
        isFalse,
      );
      expect(
        webGameNavigationAllowed(
          'https://www.yikm.net.evil.com/',
          'www.yikm.net',
        ),
        isFalse,
      );
      expect(
        webGameNavigationAllowed('https://img.yikm.net/x.png', 'www.yikm.net'),
        isFalse,
      );
      expect(webGameNavigationAllowed('not a url', 'www.yikm.net'), isFalse);
    });
  });

  group('parseBrowserAction', () {
    test('合法动作 JSON 解析出标题/地址/请求头/放行主机', () {
      final action = parseBrowserAction(_kofActionJson);
      expect(action, isNotNull);
      expect(action!.title, '拳皇97');
      expect(action.url, 'https://www.yikm.net/play?id=5326');
      expect(action.headers, {'User-Agent': 'test-ua'});
      expect(action.allowedHost, 'www.yikm.net');
    });

    test('非法输入一律回 null', () {
      expect(parseBrowserAction(''), isNull);
      expect(parseBrowserAction('not json'), isNull);
      expect(parseBrowserAction('{"actionId":"browser"}'), isNull);
      expect(
        parseBrowserAction(
          '{"actionId":"other","type":"browser","url":"https://a.com/"}',
        ),
        isNull,
      );
      expect(
        parseBrowserAction(
          '{"actionId":"browser","type":"other","url":"https://a.com/"}',
        ),
        isNull,
      );
      expect(
        parseBrowserAction(
          '{"actionId":"browser","type":"browser","url":"ftp://a.com/"}',
        ),
        isNull,
      );
      expect(
        parseBrowserAction(
          '{"actionId":"browser","type":"browser","url":"https://"}',
        ),
        isNull,
      );
      expect(
        parseBrowserAction('{"actionId":"browser","type":"browser"}'),
        isNull,
      );
      expect(parseBrowserAction('[]'), isNull);
    });

    test('无 header 字段时请求头为空、标题缺省为空', () {
      final action = parseBrowserAction(
        '{"actionId":"browser","type":"browser","url":"http://a.com/x"}',
      );
      expect(action, isNotNull);
      expect(action!.title, '');
      expect(action.headers, isEmpty);
      expect(action.allowedHost, 'a.com');
    });
  });

  group('PyContract 动作映射', () {
    test("vod_tag='action' 映射为 kind='action'，sourceId 保留动作 JSON", () {
      final drama = PyContract.itemToDrama('yikm', {
        'vod_id': _kofActionJson,
        'vod_name': '拳皇97',
        'vod_pic': 'https://img.1990i.com/arcadepic/kof97.png',
        'vod_tag': 'action',
      });
      expect(drama.kind, 'action');
      expect(drama.isAction, isTrue);
      expect(drama.isFolder, isFalse);
      expect(drama.sourceId, _kofActionJson);
      expect(drama.title, '拳皇97');
      expect(parseBrowserAction(drama.sourceId), isNotNull);
    });

    test('folder 与 video 映射不受动作分支影响', () {
      final folder = PyContract.itemToDrama('yikm', {
        'vod_id': 'folder-1',
        'vod_name': '文件夹',
        'vod_tag': 'folder',
      });
      expect(folder.kind, 'folder');
      expect(folder.isAction, isFalse);
      final video = PyContract.itemToDrama('yikm', {
        'vod_id': 'v-1',
        'vod_name': '视频',
        'vod_tag': '',
      });
      expect(video.kind, 'video');
      expect(video.isAction, isFalse);
    });
  });

  group('yikm 内置注册', () {
    test('登记表含 yikm：显示名“小霸王游戏”、不带成人前缀', () {
      final entry = BuiltinPySites.entries.singleWhere(
        (e) => e.siteId == BuiltinPySites.yikmSiteId,
      );
      expect(entry.site.name, '小霸王游戏');
      expect(entry.site.name, isNot(contains('🔞')));
      expect(entry.assetPath, 'assets/py_spiders/yikm.py');
      expect(entry.fileId, 'builtin_yikm');
    });

    test('主页映射含 yikm', () {
      expect(pySiteHomepages['yikm'], 'https://www.yikm.net');
    });
  });

  group('WebGamePage（拳皇97 参数）', () {
    Future<void> pumpKof(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WebGamePage(
              gameUrl: kof97GameUrl,
              allowedHost: kof97GameHost,
              keyPrefix: 'kof',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('加载拳皇97 地址，界面上没有任何网址字串', (tester) async {
      await pumpKof(tester);
      expect(fakePlatform.lastController?.loadedUrls, [kof97GameUrl]);
      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(find.byKey(const ValueKey('kof-loading')), findsOneWidget);
      expect(find.textContaining('yikm'), findsNothing);
      expect(find.textContaining('http'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
    });

    testWidgets('页面加载完成后面板消失', (tester) async {
      await pumpKof(tester);
      fakePlatform.lastDelegate?.onPageFinished?.call(kof97GameUrl);
      await tester.pump();
      expect(find.byKey(const ValueKey('kof-loading')), findsNothing);
      expect(find.byKey(const ValueKey('kof-retry-panel')), findsNothing);
    });

    testWidgets('主框架加载失败显示重试面板，点重试重新加载', (tester) async {
      await pumpKof(tester);
      fakePlatform.lastDelegate?.onWebResourceError?.call(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_NAME_NOT_RESOLVED',
          isForMainFrame: true,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('kof-retry-panel')), findsOneWidget);
      expect(find.textContaining('yikm'), findsNothing);
      expect(find.textContaining('http'), findsNothing);
      expect(find.text('游戏加载失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('kof-retry-button')));
      await tester.pump();
      expect(fakePlatform.lastController?.reloadCalls, 1);
      expect(find.byKey(const ValueKey('kof-retry-panel')), findsNothing);
      expect(find.byKey(const ValueKey('kof-loading')), findsOneWidget);
    });

    testWidgets('子资源失败不弹重试面板', (tester) async {
      await pumpKof(tester);
      fakePlatform.lastDelegate?.onWebResourceError?.call(
        const WebResourceError(
          errorCode: 404,
          description: 'not found',
          isForMainFrame: false,
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('kof-retry-panel')), findsNothing);
    });

    testWidgets('导航回调：站内放行、站外拦截', (tester) async {
      await pumpKof(tester);
      final callback = fakePlatform.lastDelegate?.onNavigationRequest;
      expect(callback, isNotNull);
      Future<NavigationDecision> decide(String url) async =>
          await callback!(NavigationRequest(url: url, isMainFrame: true));
      expect(
        await decide('https://www.yikm.net/nes'),
        NavigationDecision.navigate,
      );
      expect(await decide('https://evil.com/'), NavigationDecision.prevent);
      expect(
        await decide('https://www.yikm.net.evil.com/'),
        NavigationDecision.prevent,
      );
    });

    testWidgets('首请求带动作自带请求头', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WebGamePage(
              gameUrl: kof97GameUrl,
              allowedHost: kof97GameHost,
              headers: {'User-Agent': 'test-ua'},
              keyPrefix: 'kof',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fakePlatform.lastController?.lastHeaders, {
        'User-Agent': 'test-ua',
      });
    });
  });

  group('WebGameScreen 与动作导航', () {
    testWidgets('WebGameScreen 标题栏只显示游戏名、不带网址', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: WebGameScreen(
            title: '拳皇97',
            gameUrl: kof97GameUrl,
            allowedHost: kof97GameHost,
            keyPrefix: 'kof',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.widgetWithText(AppBar, '拳皇97'), findsOneWidget);
      expect(find.textContaining('yikm'), findsNothing);
      expect(find.textContaining('http'), findsNothing);
      expect(find.byType(WebGamePage), findsOneWidget);
      expect(fakePlatform.lastController?.loadedUrls, [kof97GameUrl]);
    });

    testWidgets('openBrowserAction push 游戏屏、返回可退出', (tester) async {
      final action = parseBrowserAction(_kofActionJson)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const ValueKey('open-action'),
                onPressed: () => openBrowserAction(context, action),
                child: const Text('打开动作'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(WebGameScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, '拳皇97'), findsOneWidget);
      expect(fakePlatform.lastController?.loadedUrls, [kof97GameUrl]);
      expect(fakePlatform.lastController?.lastHeaders, {
        'User-Agent': 'test-ua',
      });
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(WebGameScreen), findsNothing);
      expect(find.byKey(const ValueKey('open-action')), findsOneWidget);
    });

    testWidgets('动作标题为空时标题栏回落“游戏”', (tester) async {
      const action = BrowserAction(title: '', url: kof97GameUrl);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const ValueKey('open-action'),
                onPressed: () => openBrowserAction(context, action),
                child: const Text('打开动作'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-action')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.widgetWithText(AppBar, '游戏'), findsOneWidget);
    });
  });

  testWidgets('点拳皇97 图标开拳皇97 窗口：进全屏（任务栏与标题栏藏、退出钮在）', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('win7-desktop-icon-kof')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('win7-desktop')), findsNothing);
    // 进游戏即全屏（用户 2026-11-19 令）：标题栏与任务栏都藏，
    // 右上角悬浮退出钮；游戏页照常加载。
    expect(find.byKey(const ValueKey('win7-window-title')), findsNothing);
    expect(find.byKey(const ValueKey('win7-taskbar')), findsNothing);
    expect(find.byKey(const ValueKey('win7-game-exit')), findsOneWidget);
    expect(find.byType(WebGamePage), findsOneWidget);
    expect(fakePlatform.lastController?.loadedUrls, [kof97GameUrl]);
  });
}
