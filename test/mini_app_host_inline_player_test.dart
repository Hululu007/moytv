import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/mini_app_host_page.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_runtime.dart';
import 'package:moyi/miniapp/mini_app_server.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:moyi/miniapp/mini_app_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'player_fixtures.dart';

/// 小程序宿主详情页内嵌播放 widget 测试：player.open 不再推播放页，
/// 而是在宿主页面内嵌播放器（播放器在上、详情 WebView 在下）；选集
/// 换源经控制器递送、不重建播放器；关闭/返回键先收播放器再退页；
/// 桥事件 player.stateChange / player.close 与状态快照保持可用。
///
/// WebView 用假平台实现（宿主只调控制器上少数几个方法），播放器用
/// ScriptedPlayer + 假画面（与海阔内嵌播放测试同一套注入方式）。

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  void Function(JavaScriptMessage)? channelHandler;
  final scripts = <String>[];
  final loadedUrls = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channelHandler = params.onMessageReceived;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loadedUrls.add(params.uri.toString());
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
  }

  @override
  Future<void> reload() async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}
}

class _FakePlatformWidget extends PlatformWebViewWidget {
  _FakePlatformWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      key: ValueKey('miniapp-webview-placeholder'),
      color: Color(0xFF1A1030),
      child: Center(
        child: Text('详情页占位', style: TextStyle(color: Colors.white)),
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
  _FakePlatformController? lastController;

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
    return _FakeNavigationDelegate(params);
  }
}

class _FakeRuntime extends MiniAppRuntime {
  _FakeRuntime({
    required super.store,
    required super.settings,
    required this.instance,
  });

  final MiniAppInstance instance;

  @override
  Future<MiniAppInstance> ensureRunning(MiniAppManifest manifest) async =>
      instance;

  @override
  Future<String?> resolveUrl(String appId) async => null;

  @override
  void markBackground(String appId) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late MiniAppServer server;
  late _FakeWebViewPlatform fakePlatform;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    fakePlatform = _FakeWebViewPlatform();
    WebViewPlatform.instance = fakePlatform;
    tempDir = await Directory.systemTemp.createTemp('miniapp_inline_test_');
    File('${tempDir.path}/index.html').writeAsStringSync('<html></html>');
    server = await MiniAppServer.start(
      root: tempDir,
      entry: 'index.html',
      sdkScript: '',
      basePort: 0,
      usedPorts: {},
      lanShare: false,
    );
  });

  tearDown(() async {
    await server.close();
    await tempDir.delete(recursive: true);
  });

  Player buildPlayer(List<ScriptedPlayer> created) {
    final platform = ScriptedPlayer();
    created.add(platform);
    return Player(platformPlayer: platform);
  }

  Future<void> pumpHost(
    WidgetTester tester,
    List<ScriptedPlayer> created,
  ) async {
    final manifest = const MiniAppManifest(
      appId: 'test.inline',
      name: '内嵌测试',
      permissions: ['player', 'source'],
    );
    final instance = MiniAppInstance(
      manifest: manifest,
      server: server,
      dir: tempDir,
    );
    final runtime = _FakeRuntime(
      store: MiniAppStore(rootOverride: tempDir),
      settings: const MiniAppSettings(),
      instance: instance,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MiniAppHostPage(
          manifest: manifest,
          runtime: runtime,
          settings: const MiniAppSettings(),
          playerFactory: () => buildPlayer(created),
          videoBuilder: (_) => const ColoredBox(
            key: ValueKey('fake-video-surface'),
            color: Colors.black,
            child: Center(
              child: Text(
                '视频画面占位',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> sendChannelMessage(String raw) async {
    final handler = fakePlatform.lastController?.channelHandler;
    if (handler == null) fail('JS 通道未注册');
    handler(JavaScriptMessage(message: raw));
  }

  Future<void> playerOpen(
    WidgetTester tester, {
    required String url,
    required String title,
    int callId = 1,
  }) async {
    await sendChannelMessage(
      jsonEncode({
        'callId': callId,
        'api': 'player.open',
        'params': {'url': url, 'title': title},
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  // 控件层始终在树里，隐藏时靠 IgnorePointer 挡点按：按门的状态
  // 判断要不要先点一下画面把控件层唤出来。
  Future<void> ensureControlsVisible(
    WidgetTester tester,
    String tooltip,
  ) async {
    bool gated() {
      final gates = find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IgnorePointer),
      );
      return tester.widgetList<IgnorePointer>(gates).any((w) => w.ignoring);
    }

    if (gated()) {
      await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
      await tester.pump(const Duration(milliseconds: 350));
    }
    expect(gated(), isFalse);
  }

  testWidgets('player.open embeds inline, no pushed play page', (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpHost(tester, created);

    expect(
      find.byKey(const ValueKey('miniapp-webview-placeholder')),
      findsOneWidget,
    );
    expect(find.byType(HaikuoPlayerView), findsNothing);

    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '剧名 · 480P',
    );

    // 内嵌播放器在树里、单独播放页没推、详情页仍在。
    expect(find.byType(HaikuoPlayerView), findsOneWidget);
    expect(find.byType(HaikuoPlayPage), findsNothing);
    expect(
      find.byKey(const ValueKey('miniapp-webview-placeholder')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('fake-video-surface')), findsOneWidget);
    // 播放器在上、详情页在下。
    final playerTop = tester
        .getTopLeft(find.byType(HaikuoPlayerView))
        .dy;
    final webTop = tester
        .getTopLeft(find.byKey(const ValueKey('miniapp-webview-placeholder')))
        .dy;
    expect(playerTop, lessThan(webTop));
    expect(
      tester.getSize(find.byType(HaikuoPlayerView)).height,
      greaterThan(0),
    );
    // 只建了一个播放器、打开的是第 1 集地址。
    expect(created, hasLength(1));
    expect(created.single.opened, hasLength(1));
    expect(created.single.opened.single.uri, contains('ep1.m3u8'));
    // 状态变化事件已发给小程序侧。
    final scripts = fakePlatform.lastController!.scripts;
    expect(
      scripts.any((s) => s.contains('player.stateChange')),
      isTrue,
    );
  });

  testWidgets('second player.open delivers, same player, state snapshot flips',
      (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpHost(tester, created);
    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '剧名 · 480P',
    );
    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep2.m3u8',
      title: '剧名 · 720P',
      callId: 2,
    );

    // 换源不重建播放器：同一个 ScriptedPlayer 打开了两次。
    expect(created, hasLength(1));
    expect(created.single.opened, hasLength(2));
    expect(created.single.opened[1].uri, contains('ep2.m3u8'));
    expect(find.byType(HaikuoPlayerView), findsOneWidget);
    expect(find.byType(HaikuoPlayPage), findsNothing);

    // player.getState 读到的是新地址的快照。
    await sendChannelMessage(
      jsonEncode({'callId': 3, 'api': 'player.getState', 'params': {}}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final scripts = fakePlatform.lastController!.scripts;
    expect(
      scripts.any((s) => s.contains('ep2.m3u8') && s.contains('"opened":true')),
      isTrue,
    );
  });

  testWidgets('controls back closes inline player, emits player.close',
      (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpHost(tester, created);
    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '剧名 · 480P',
    );

    await ensureControlsVisible(tester, '返回');
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(HaikuoPlayerView), findsNothing);
    expect(
      find.byKey(const ValueKey('miniapp-webview-placeholder')),
      findsOneWidget,
    );
    final scripts = fakePlatform.lastController!.scripts;
    expect(scripts.any((s) => s.contains('player.close')), isTrue);

    await sendChannelMessage(
      jsonEncode({'callId': 9, 'api': 'player.getState', 'params': {}}),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      fakePlatform.lastController!.scripts
          .any((s) => s.contains('"opened":false')),
      isTrue,
    );
  });

  testWidgets('system back closes player first, then exits miniapp',
      (tester) async {
    final created = <ScriptedPlayer>[];
    // 宿主以“被推上来的路由”出现：第一次返回关播放器留详情页，
    // 第二次返回退回上一页（根路由本身 pop 不掉，故不用 home 直挂）。
    final manifest = const MiniAppManifest(
      appId: 'test.inline',
      name: '内嵌测试',
      permissions: ['player', 'source'],
    );
    final instance = MiniAppInstance(
      manifest: manifest,
      server: server,
      dir: tempDir,
    );
    final runtime = _FakeRuntime(
      store: MiniAppStore(rootOverride: tempDir),
      settings: const MiniAppSettings(),
      instance: instance,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => MiniAppHostPage(
                        manifest: manifest,
                        runtime: runtime,
                        settings: const MiniAppSettings(),
                        playerFactory: () => buildPlayer(created),
                        videoBuilder: (_) => const ColoredBox(
                          color: Colors.black,
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('打开小程序'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开小程序'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(MiniAppHostPage), findsOneWidget);

    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '剧名 · 480P',
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(HaikuoPlayerView), findsNothing);
    expect(find.byType(MiniAppHostPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    // 退栈转场 300ms：一次 pump 只起帧、路由仍在树里，走完转场才消失。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MiniAppHostPage), findsNothing);
    expect(find.text('打开小程序'), findsOneWidget);
  });

  testWidgets('fullscreen back exits fullscreen first, then closes player',
      (tester) async {
    final created = <ScriptedPlayer>[];
    await pumpHost(tester, created);
    await playerOpen(
      tester,
      url: 'https://cdn.example.com/ep1.m3u8',
      title: '剧名 · 480P',
    );

    await ensureControlsVisible(tester, '旋转与全屏');
    await tester.tap(find.byTooltip('旋转与全屏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // 全屏时宿主顶栏藏掉、播放器仍在。
    expect(find.text('内嵌测试'), findsNothing);
    expect(find.byType(HaikuoPlayerView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    // 第一次返回只退全屏：顶栏回来、播放器还在。
    expect(find.text('内嵌测试'), findsOneWidget);
    expect(find.byType(HaikuoPlayerView), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(HaikuoPlayerView), findsNothing);
    expect(find.byType(MiniAppHostPage), findsOneWidget);
  });
}
