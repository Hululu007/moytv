// 海阔对标官方批预览图：小程序首页紧凑顶栏、海阔跑页无壳子顶栏。
// 一测一张：调过 toImage 的测试在收尾时会挂起
// （旧现象，PNG 已落地），跑单测、超时杀掉只取 PNG。
// 假数据：规则名来自内置包资源（真实包名），WebView 区为测试占位。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:moyi/miniapp/mini_app_builtin.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const _previewDir = '/home/hatch/workspace/moyi_previews';

Future<void> _loadPreviewFont() async {
  try {
    const path = String.fromEnvironment(
      'PREVIEW_FONT',
      defaultValue: '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    final loader = FontLoader('PreviewCJK')
      ..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
    await loader.load().timeout(const Duration(seconds: 30), onTimeout: () {});
  } catch (_) {}
}

Future<void> _snap(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  // 全部同步文件操作：测试体在假异步区里，await 真实 IO 永远不返回。
  final dir = Directory(_previewDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('${dir.path}/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  setUp(() {
    MiniAppHomeCache.resetForTest();
    tempDir = Directory.systemTemp.createTempSync('haikuo_preview');
    SharedPreferences.setMockInitialValues({
      MiniAppSettings.keyMarketUrl: 'http://127.0.0.1:1/market.json',
      // 预置播种标记：跳过 4 个内置小程序的首跑安装（59MB 解压在测试
      // 假异步区里跑不完，会拖住 _load、TabBarView 建不出来）；海阔网格
      // 另由真包预置。只影响测试脚手架，不动生产播种逻辑。
      MiniAppBuiltin.seededKey: true,
      MiniAppBuiltin.seededAppIdsKey: const [
        'com.ant.emby',
        'com.leospring.cms_t4_bridge',
        'com.leospring.source_t4_bridge',
        'com.leospring.drpy_node',
      ],
    });
  });

  tearDown(() async {
    MiniAppHomeCache.resetForTest();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
    }
  }

  /// 等某个 widget 出现（播种/加载完成）：每轮给真实 IO 时间并推进
  /// 假时钟（动画也要靠它走完）；到轮数上限还没出现也不报错，
  /// 直接截当前画面，预览图总能落地。
  Future<void> drainUntil(WidgetTester tester, Finder finder) async {
    // 150 轮：内置包播种含 59MB 解压，单线程下海阔播种要等它让出时间。
    for (var i = 0; i < 150; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  void sizeUp(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('preview miniapp home compact header', (tester) async {
    sizeUp(tester);
    await tester.runAsync(_loadPreviewFont);
    // 预置：进页面前先把真包播进页面默认仓库（runAsync 真异步区里
    // IO 能跑完）；页面 _load 命中当前版本标记后直接读库出网格，
    // 不在页面里走播种（测试假异步区里播种链跑不完，网格出不来）。
    final store = HaikuoStore(
      rootOverride: Directory(p.join(tempDir.path, 'haikuo')),
    );
    await tester.runAsync(() => store.ensureBuiltinRules());
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            textTheme: ThemeData().textTheme.apply(fontFamily: 'PreviewCJK'),
          ),
          home: const MiniAppHomePage(),
        ),
      ),
    );
    await drain(tester);
    await tester.tap(find.text('海阔'));
    // 带时长的 pump 推完标签切换动画（零时长 pump 下动画永远走不完，
    // 持续调帧会把 toImage 拖住）；再等海阔网格播种出规则瓦片。
    await tester.pump(const Duration(milliseconds: 400));
    await drainUntil(tester, find.text('🔞MissAV'));
    await tester.pump();
    await _snap(tester, key, 'haikuo_compact_header.png');
  });

  testWidgets('preview haikuo runner no shell bar', (tester) async {
    sizeUp(tester);
    await tester.runAsync(_loadPreviewFont);
    final store = HaikuoStore(
      rootOverride: Directory(p.join(tempDir.path, 'haikuo')),
    );
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '🔞MissAV',
            'url': 'hiker://empty##https://example.com',
            'find_rule': 'js:\nsetResult([]);',
          },
        ]),
        origin: '文件',
      ),
    );
    final program = (await tester.runAsync(() => store.list()))!.single;
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            textTheme: ThemeData().textTheme.apply(fontFamily: 'PreviewCJK'),
          ),
          home: HaikuoRunnerPage(program: program),
        ),
      ),
    );
    await drain(tester);
    await tester.pump();
    await _snap(tester, key, 'haikuo_runner_no_shell_bar.png');
  });
}

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setUserAgent(String? userAgent) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';

  @override
  Future<void> reload() async {}

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<String?> getTitle() async => '';
}

class _FakePlatformWidget extends PlatformWebViewWidget {
  _FakePlatformWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1030),
      alignment: Alignment.center,
      child: const Text(
        '规则页面占位\n（测试环境无真 WebView）',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white70, fontSize: 13),
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
