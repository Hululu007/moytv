// 预览图（2026-11-27 手机实测四问题修复批）：
// 1) 小程序区四页签行（问题 4a：已安装/海阔/插件/市场、无齿轮）；
// 2) 演员库详情页 AvPlay 版式上半（问题 3 扩围：大标题+翻译
//    切换、信息卡+评分缎带、相关分类胶囊）；
// 3) 详情页下半（她们还演出过/你可能也喜欢/磁力区）。
// 渲染预览 · 假数据；图片走本机测试环境解不出的远程地址时
// 显示占位框，真机出真图；图标字体在预览里可能成方框。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/javdb_api.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/miniapp/mini_app_home_page.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_settings.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _previewDir = '/home/hatch/workspace/moyi_phonefix_20261127/preview';

ThemeData _previewTheme() {
  final base = ThemeData.dark();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
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

Future<void> _shoot(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 600)),
  );
  await _settle(tester);
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name.png').writeAsBytesSync(bytes);
}

Widget _framed(GlobalKey key, String label, Widget child) {
  return RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _previewTheme(),
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'PreviewCJK'),
        child: Scaffold(
          body: Column(
            children: [
              Container(
                width: double.infinity,
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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
          ),
        ),
      ),
    ),
  );
}

String _envelope(Object? data) => jsonEncode({'success': true, 'data': data});

Map<String, Object?> _movieJson(String id, String number) => {
  'id': id,
  'number': number,
  'title': '标题 $number',
  'thumb_url': 'https://c0.jdbstatic.com/thumbs/$id.jpg',
  'cover_url': 'https://c0.jdbstatic.com/covers/$id.jpg',
};

class _FakeJavdb {
  Future<String> fetch(String url) async {
    if (url.contains('api/v2/search')) {
      return _envelope({
        'movies': [_movieJson('m1', 'SSIS-001')],
      });
    }
    if (url.contains('/magnets')) {
      return _envelope({
        'magnets': [
          {
            'hash': 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
            'name': 'SSIS-001 HD',
            'size': 2048,
            'created_at': '2024-06-15',
            'hd': true,
            'cnsub': true,
          },
        ],
      });
    }
    if (url.contains('/reviews')) return _envelope({'reviews': const []});
    if (url.contains('api/v4/movies/')) {
      return _envelope({
        'movie': {
          'score': 4.5,
          'reviews_count': 123,
          'series_name': 'S1 NO.1 STYLE',
          'maker_name': 'S1 NO.1 STYLE',
          'origin_title': '原題のタイトル',
          'tags': [
            {'id': 't1', 'name': '秘书'},
            {'id': 't2', 'name': '已婚妇女'},
            {'id': 't3', 'name': '巨乳'},
            {'id': 't4', 'name': '单体作品'},
          ],
          'relative_movies': [_movieJson('m9', 'SSIS-999')],
          'actor_movies': [
            _movieJson('m1', 'SSIS-001'),
            _movieJson('m8', 'SSIS-888'),
            _movieJson('m7', 'SSIS-777'),
          ],
          'preview_images': const [],
        },
      });
    }
    throw StateError('未预期的网址：$url');
  }

  JavdbApiClient get client => JavdbApiClient(fetch: fetch);
}

class _Repo extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, const []);
}

Future<bool> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return true;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 详情页门禁认登记过的源：照补充链组件测试的登记法把
    // chaoliu 登记为导入站，否则页面落无权访问面板、补充链
    // 不跑（预览就拍不到版式）。
    SourceSite.importedSites['chaoliu'] = const SourceSite(
      'chaoliu',
      '潮流',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originImport,
      importType: 'py',
    );
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader('PreviewCJK')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => Directory.systemTemp.path,
        );
  });

  testWidgets('preview miniapp tabs', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    MiniAppHomeCache.warmForTest(
      settings: const MiniAppSettings(),
      installed: const [MiniAppManifest(appId: 'com.ant.emby', name: '影视库')],
    );
    addTearDown(MiniAppHomeCache.resetForTest);
    final key = GlobalKey();
    await tester.pumpWidget(
      _framed(
        key,
        '渲染预览 · 假数据 · 问题4a：小程序区页签只剩 已安装/海阔/插件/市场，右上角齿轮已删',
        const MiniAppHomePage(),
      ),
    );
    await _settle(tester);
    await _shoot(tester, key, 'miniapp_tabs');
  });

  testWidgets('preview detail avplay top', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
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
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text(
                      '渲染预览 · 假数据 · 问题3扩围：大标题+翻译切换、信息卡+评分缎带、相关分类胶囊（封面图本机解不出显示占位，真机出真图）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(child: _DetailPage(fake: _FakeJavdb())),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      await _waitFor(tester, find.byKey(const ValueKey('detail-score-ribbon'))),
      isTrue,
    );
    // 回到顶部再拍（waitFor 一路下拖过）。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 4000));
    await _settle(tester);
    await _shoot(tester, key, 'detail_avplay_top');
  });

  testWidgets('preview detail avplay sections', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
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
              body: Column(
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: const Text(
                      '渲染预览 · 假数据 · 问题3扩围下半：她们还演出过/你可能也喜欢（有真数据才出）',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'PreviewCJK',
                      ),
                    ),
                  ),
                  Expanded(child: _DetailPage(fake: _FakeJavdb())),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      await _waitFor(
        tester,
        find.byKey(const ValueKey('detail-javdb-actor-movies')),
      ),
      isTrue,
    );
    await _shoot(tester, key, 'detail_avplay_sections');
  });
}

class _DetailPage extends StatefulWidget {
  const _DetailPage({required this.fake});
  final _FakeJavdb fake;
  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  LocalStore? _store;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _store = LocalStore(prefs));
    });
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) return const SizedBox.shrink();
    return DetailScreen(
      drama: const Drama(
        id: 'chaoliu:SSIS-001',
        source: 'chaoliu',
        title: 'SSIS-001 样本影片',
        category: '成人影片',
        onlineDate: '2024-06-15',
        tags: ['SSIS-001'],
        episodes: 1,
      ),
      repository: _Repo(),
      store: store,
      javdbStillsClient: widget.fake.client,
    );
  }
}
