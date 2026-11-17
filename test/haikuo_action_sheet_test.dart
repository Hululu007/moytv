import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// 长按官方操作表：主表 9 项、子表 13 项的顺序与落地状态。
/// 云剪贴板 6 的真上传不走 widget 测试（真网），由
/// haikuo_cloud6_test.dart 用假传输覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
  });

  late Directory tempDir;
  late HaikuoStore store;

  /// 模拟剪贴板：widget 测试里没有真实剪贴板，不装 mock 处理器，
  /// Clipboard.setData 会等不到引擎回包（复制流程挂在半道）。
  String? mockClipboardText;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('haikuo_sheet_test');
    store = HaikuoStore(rootOverride: tempDir);
    mockClipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.getData':
              final text = mockClipboardText;
              if (text == null) return null;
              return <String, dynamic>{'text': text};
            case 'Clipboard.setData':
              final args = call.arguments;
              if (args is Map) {
                mockClipboardText = args['text'] as String?;
              }
              return null;
            case 'Clipboard.hasStrings':
              return <String, dynamic>{
                'value':
                    mockClipboardText != null && mockClipboardText!.isNotEmpty,
              };
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> seed(WidgetTester tester, {String host = '', String url = ''}) async {
    final rule = <String, Object?>{
      'title': '测试站',
      'url': url.isNotEmpty ? url : 'hiker://empty##https://example.com',
      'find_rule': 'js:\nsetResult([]);',
      if (host.isNotEmpty) 'host': host,
    };
    await tester.runAsync(
      () => store.importText(jsonEncode([rule]), origin: '测试'),
    );
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: HaikuoHomePage(store: store)));
    // 首帧加载圈是无限动画，pumpAndSettle 永远等不到静止；手动逐帧推，
    // 与 haikuo_home_page_test.dart 同一口径。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.longPress(find.text('测试站'));
    await tester.pumpAndSettle();
  }

  Future<void> openMoreSheet(WidgetTester tester) async {
    await openSheet(tester);
    await tester.tap(find.text('更多分享'));
    await tester.pumpAndSettle();
  }

  Future<void> popTop(WidgetTester tester) async {
    final context = tester.element(find.byType(HaikuoRunnerPage));
    Navigator.of(context).maybePop();
    await tester.pump();
  }

  // 假异步与真 I/O 交替推（跑页建本地服务器、删库写盘是真 I/O）：
  // runAsync 让真 I/O 完成，带时长的 pump 推进假时钟与动画。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // 排干直到条件成立或 40 轮耗尽：写盘链是多跳真 I/O，固定轮数
  // 不可靠（删库一链约 9 跳，机器忙时一跳要多轮才落定）。
  Future<void> drainUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  test('主表常量：9 项顺序照官方截图', () {
    expect(haikuoActionSheetItems.map((item) => item.label).toList(), [
      '编辑规则',
      '搜索内容',
      '分享规则',
      '更多分享',
      '网站首页',
      '删除规则',
      '清除缓存',
      'Web编辑',
      '重生恢复',
    ]);
  });

  test('子表常量：13 项顺序照官方截图', () {
    expect(haikuoMoreShareSheetItems.map((item) => item.label).toList(), [
      '明文口令',
      '提交云仓库',
      '文件形式1',
      '文件形式2',
      '云剪贴板1',
      '云剪贴板2',
      '云剪贴板5',
      '云剪贴板6',
      '云剪贴板7',
      '云剪贴板9',
      '云剪贴板10',
      '小程序包',
      '小程序包2',
    ]);
  });

  testWidgets('长按弹出主表，9 项齐全、无旧表残留', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openSheet(tester);
    expect(find.text('请选择操作'), findsOneWidget);
    for (final item in haikuoActionSheetItems) {
      expect(find.text(item.label), findsOneWidget);
    }
    expect(find.text('打开'), findsNothing);
    expect(find.text('详情'), findsNothing);
    expect(find.text('复制 JSON'), findsNothing);
    expect(find.text('生成口令分享'), findsNothing);
  });

  testWidgets('更多分享弹出子表，13 项齐全', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openMoreSheet(tester);
    expect(find.text('更多分享'), findsOneWidget);
    for (final item in haikuoMoreShareSheetItems) {
      expect(find.text(item.label), findsOneWidget);
    }
  });

  testWidgets('分享规则：弹窗展示官方口令，可复制', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openSheet(tester);
    await tester.tap(find.text('分享规则'));
    await tester.pumpAndSettle();
    expect(find.text('分享「测试站」'), findsOneWidget);
    expect(find.text('复制口令'), findsOneWidget);
    await tester.tap(find.text('复制口令'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('口令已复制到剪贴板'), findsOneWidget);
    expect(mockClipboardText, startsWith('海阔视界规则分享'));
    expect(mockClipboardText, contains('￥'));
  });

  testWidgets('明文口令：直接复制到剪贴板', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openMoreSheet(tester);
    await tester.tap(find.text('明文口令'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('明文口令已复制到剪贴板'), findsOneWidget);
    expect(mockClipboardText, contains('￥home_rule￥'));
  });

  testWidgets('删除规则：确认后落库删除', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openSheet(tester);
    await tester.tap(find.text('删除规则'));
    await tester.pumpAndSettle();
    expect(find.text('删除小程序'), findsOneWidget);
    expect(find.text('确定删除「测试站」吗？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await drainUntil(tester, find.text('还没有导入海阔小程序'));
    expect(find.text('测试站'), findsNothing);
    expect(await tester.runAsync(() => store.list()), isEmpty);
  });

  testWidgets('搜索内容：打开跑页并展开搜索栏，跑页无壳子顶栏', (tester) async {
    await seed(tester);
    await pumpPage(tester);
    await openSheet(tester);
    await tester.tap(find.text('搜索内容'));
    await drain(tester);
    final runner = tester.widget<HaikuoRunnerPage>(
      find.byType(HaikuoRunnerPage),
    );
    expect(runner.initialShowSearch, isTrue);
    expect(
      find.descendant(
        of: find.byType(HaikuoRunnerPage),
        matching: find.byType(AppBar),
      ),
      findsNothing,
    );
    await popTop(tester);
    await drain(tester);
  });

  testWidgets('网站首页：有地址时打开应用内网页', (tester) async {
    await seed(tester, host: 'mysite.example');
    await pumpPage(tester);
    await openSheet(tester);
    await tester.tap(find.text('网站首页'));
    await drain(tester);
    final page = tester.widget<HaikuoWebPage>(find.byType(HaikuoWebPage));
    expect(page.url, 'https://mysite.example');
    expect(page.title, '测试站');
    await tester.pageBack();
    await drain(tester);
  });

  testWidgets('网站首页：无地址时明说打不开', (tester) async {
    await seed(tester, url: 'hiker://empty');
    await pumpPage(tester);
    await openSheet(tester);
    await tester.tap(find.text('网站首页'));
    await tester.pumpAndSettle();
    expect(find.text('这条规则没有网站地址，打不开首页'), findsOneWidget);
    expect(find.byType(HaikuoWebPage), findsNothing);
  });

  const unavailableMain = {
    '编辑规则': '编辑器',
    '清除缓存': 'WebView',
    'Web编辑': '局域网',
    '重生恢复': '手册',
  };
  for (final entry in unavailableMain.entries) {
    testWidgets('诚实不可用：${entry.key}点后明说原因', (tester) async {
      await seed(tester);
      await pumpPage(tester);
      await openSheet(tester);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(find.text(entry.key), findsOneWidget);
      expect(find.textContaining(entry.value), findsWidgets);
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
    });
  }

  const unavailableMore = {
    '提交云仓库': '云仓库账号',
    '文件形式1': '文件形式1/2',
    '文件形式2': '文件形式1/2',
    '云剪贴板1': '未公开',
    '云剪贴板2': '未公开',
    '云剪贴板5': '未公开',
    '云剪贴板7': '未公开',
    '云剪贴板9': '未公开',
    '云剪贴板10': '未公开',
    '小程序包': '打包格式',
    '小程序包2': '打包格式',
  };
  for (final entry in unavailableMore.entries) {
    testWidgets('诚实不可用：${entry.key}点后明说原因', (tester) async {
      await seed(tester);
      await pumpPage(tester);
      await openMoreSheet(tester);
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(find.text(entry.key), findsOneWidget);
      expect(find.textContaining(entry.value), findsWidgets);
      expect(find.text('知道了'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
    });
  }
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
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}

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
    return const ColoredBox(color: Color(0xFF1A1030));
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
