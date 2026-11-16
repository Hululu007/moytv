// 14 版手机反馈修复预览图：只做测试内截图，不改业务代码。
// 全部假数据；调过 toImage 的测试在收尾时可能挂起（旧现象，PNG 已落地），
// 跑单测、超时杀掉只取 PNG。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/hongguo_drama_home.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/ui_style.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEUlEQVR4nGNgeFb2Hy8eGQoAbuuWwWeGLLsAAAAASUVORK5CYII=';

/// 测试内网络图片 mock：一切 HTTP 请求都回一张 1x1 PNG，让
/// Image.network 走完“加载成功”分支（否则测试环境无网络，图标
/// 全回落字形，预览图看不出图标链是否生效）。
class _ImageHttpOverrides extends HttpOverrides {
  _ImageHttpOverrides(this.bytes);
  final Uint8List bytes;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeImageHttpClient(bytes);
}

class _FakeImageHttpClient implements HttpClient {
  _FakeImageHttpClient(this.bytes);
  final Uint8List bytes;

  @override
  bool autoUncompress = false;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  @override
  int? maxConnectionsPerHost;

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeImageHttpRequest(bytes);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeImageHttpRequest(bytes);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageHttpRequest implements HttpClientRequest {
  _FakeImageHttpRequest(this.bytes);
  final Uint8List bytes;
  final _FakeHttpHeaders _headers = _FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => _FakeImageHttpResponse(bytes);

  @override
  String get method => 'GET';

  @override
  Uri get uri => Uri.parse('https://preview.invalid/');

  @override
  int get contentLength => 0;

  @override
  set contentLength(int value) {}

  @override
  bool get followRedirects => true;

  @override
  set followRedirects(bool value) {}

  @override
  bool get persistentConnection => false;

  @override
  set persistentConnection(bool value) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _map = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _map.putIfAbsent(name.toLowerCase(), () => []).add(value.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _map[name.toLowerCase()] = [value.toString()];
  }

  @override
  void remove(String name, Object value) {
    _map[name.toLowerCase()]?.remove(value.toString());
  }

  @override
  void removeAll(String name) {
    _map.remove(name.toLowerCase());
  }

  @override
  List<String>? operator [](String name) => _map[name.toLowerCase()];

  @override
  String? value(String name) => _map[name.toLowerCase()]?.join(', ');

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _map.forEach(action);
  }

  @override
  void clear() => _map.clear();

  @override
  void noFolding(String name) {}

  @override
  int contentLength = 0;

  @override
  ContentType? contentType;

  @override
  bool chunkedTransferEncoding = false;

  @override
  String? host;

  @override
  int? port;

  @override
  DateTime? date;

  @override
  DateTime? expires;

  @override
  DateTime? ifModifiedSince;

  @override
  bool persistentConnection = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeImageHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeImageHttpResponse(this.bytes);
  final Uint8List bytes;

  @override
  int get statusCode => 200;

  @override
  String get reasonPhrase => 'OK';

  @override
  int get contentLength => bytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  HttpHeaders get headers => _FakeHttpHeaders();

  @override
  bool get persistentConnection => false;

  @override
  List<Cookie> get cookies => const [];

  @override
  X509Certificate? get certificate => null;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadFont() async {
  try {
    final bytes = File(
      '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
    ).readAsBytesSync();
    final loader = FontLoader('PreviewCJK')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  } catch (_) {}
}

ThemeData _previewTheme() {
  appThemeNotifier.value = AppThemeMode.purpleNeon;
  final base = AppThemeConfig.forTheme(AppThemeMode.purpleNeon).toThemeData();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  const dir = '/home/hatch/workspace/moyi_previews';
  Directory(dir).createSync(recursive: true);
  File('$dir/$name').writeAsBytesSync(bytes);
  print('preview landed: $name');
}

void _setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _banner(String label, Widget child) => Column(
  children: [
    Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontFamily: 'PreviewCJK',
        ),
      ),
    ),
    Expanded(child: child),
  ],
);

void main() {
  setUpAll(_loadFont);

  testWidgets('预览 我的页无主题行', (tester) async {
    _setViewport(tester);
    SharedPreferences.setMockInitialValues({'appThemeMode': 'purpleNeon'});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: _banner(
                '预览 · 假数据 · 我的页：主题切换行已删，设置是唯一入口',
                HongguoDramaHome(
                  dramas: const [
                    Drama(
                      id: 'hongguo:1',
                      source: 'hongguo',
                      title: '普通短剧一',
                      cover: 'https://x.test/base.jpg',
                      episodes: 3,
                    ),
                  ],
                  repository: FixtureRepository(),
                  store: store,
                  onOpenDrama: (_) {},
                  onOpenFeed: () {},
                  onPickSource: () {},
                  sourceLabel: '红果 (1)',
                  feedEnabled: true,
                  categories: const [
                    CatalogCategory('', '全部'),
                    CatalogCategory('rec', '推荐'),
                  ],
                  selectedCategory: 'rec',
                  onCategorySelected: (_) {},
                  searchController: TextEditingController(),
                  searchHint: '搜索',
                  onSearchChanged: (_) {},
                  onSearchSubmitted: (_) {},
                  onOpenGlobalSearch: () {},
                  onAvatarPressed: () {},
                  onFilterPressed: () {},
                  onRankingsPressed: () {},
                  onNewPressed: () {},
                  filtersActive: false,
                  newActive: false,
                  onOpenSaved: ({required bool history}) {},
                  onSettingsPressed: () {},
                  requestedTab: HongguoDramaHome.mineTabIndex,
                  hideCapsuleBar: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('主题切换'), findsNothing);
    await _capture(key, 'mine_no_theme_dup.png');
  });

  testWidgets('预览 海阔网格图标', (tester) async {
    _setViewport(tester);
    final png = base64Decode(_tinyPngBase64);
    HttpOverrides.global = _ImageHttpOverrides(png);
    addTearDown(() => HttpOverrides.global = null);
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('haikuo-preview-'),
    ))!;
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final store = HaikuoStore(rootOverride: temp);
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '🔞MissAV',
            'type': 'video',
            'url': 'hiker://empty##https://missav.live/dm16/cn',
            'icon': 'https://static.missav888.com/img/favicon.png',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '有站无图标',
            'type': 'video',
            'host': 'https://example.com',
            'url': 'hiker://empty##fypage',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '内嵌图标',
            'type': 'video',
            'url': 'hiker://empty##fypage',
            'icon': 'data:image/png;base64,$_tinyPngBase64',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '无图标',
            'type': 'video',
            'url': 'hiker://empty##fypage',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '🔞Jable',
            'type': 'video',
            'url': 'hiker://empty##https://jable.tv',
            'icon': 'https://jable.tv/favicon.ico',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
          {
            'title': '带host字段',
            'type': 'video',
            'host': 'example.org',
            'url': 'hiker://empty##fypage',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '预览',
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: Scaffold(
              body: _banner(
                '预览 · 假数据 · 海阔网格：真图标优先，favicon 次之，无图标回落字形',
                HaikuoHomePage(store: store),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump();
    }
    await _settle(tester);
    expect(find.text('🔞MissAV'), findsOneWidget);
    await _capture(key, 'haikuo_grid_icons.png');
  });

  testWidgets('预览 听读合并导航', (tester) async {
    _setViewport(tester);
    SharedPreferences.setMockInitialValues({
      'hiddenSites': '[]',
      'appThemeMode': 'purpleNeon',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _previewTheme(),
          navigatorObservers: [homeRouteObserver],
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'PreviewCJK'),
            child: HomeScreen(repository: FixtureRepository(), store: store),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('shell-tab-2')));
    await _settle(tester);
    expect(find.text('听读'), findsWidgets);
    expect(find.text('听书'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    await _capture(key, 'nav_merged_listenread.png');
  });
}
