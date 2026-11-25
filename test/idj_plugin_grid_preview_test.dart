// 插件列表三列网格预览图（2026-11-25 plugin-list-ui 批）：
//   1. installed_grid.png —— 已安装三列网格：真实 IdjPluginTab，
//      种子 5 个（启用 3 + 已停用 1 置灰 + 已损坏 1），卡片右上角
//      小菜单收管理动作，状态以小标签显示。
//   2. market_grid.png —— 插件市场三列网格：同一 tab 下滑到订阅区，
//      订阅展开 6 个插件卡：已装同版显示「已安装」、有新版显示
//      「更新」、未装显示「安装」；点安装免确认直接装（本图只展示）。
// 演示数据：站名/版本为合成假数据；脚本是迷你合成脚本。
// 截图写到本工作区 preview/ 目录。注意：调过 toImage 的测试在收尾
// 时会挂起——单跑本文件、PNG 落地后超时杀掉即可，绝不与普通测试
// 批量跑在一次调用里。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/idj_plugin_store.dart';
import 'package:moyi/miniapp/idj_plugin_tab.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir = '/home/hatch/workspace/moyi_plugin_ui_20261125/preview';
const _cjkFont = 'PreviewCJK';

const _miniScript =
    'export default { home: async () => ({}), play: async () => ({}) };';

String _hash(String script) =>
    base64Encode(sha256.convert(utf8.encode(script)).bytes);

String _bundleText({
  required String id,
  required String name,
  required String version,
  bool adult = false,
}) {
  final manifest = <String, dynamic>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'entry': 'main.js',
    'type': 'video',
    'adult': adult,
    'author': 'test',
    'description': '预览用迷你插件',
    'capabilities': ['home', 'category', 'search', 'detail', 'play'],
    'minAppVersion': '1.5',
    'permissions': {
      'http': const ['example.com'],
      'media': const ['example.com'],
      'cloudflare': false,
      'login': false,
      'storage': true,
    },
    'settings': [],
    'integrity': 'sha256-${_hash(_miniScript)}',
  };
  return jsonEncode({
    'manifest': manifest,
    'files': {'main.js': _miniScript},
  });
}

Future<Map<String, dynamic>> _probeStub({
  required String pluginId,
  required String script,
  required Map<String, dynamic> manifest,
}) async => {};

Future<void> _drainUntil(WidgetTester tester, bool Function() until) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    if (until()) break;
  }
  await tester.pump();
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String file) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$file').writeAsBytesSync(bytes);
}

ThemeData _lightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _cjkFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _cjkFont),
  );
}

Widget _wrap(GlobalKey key, Widget child, String banner) {
  return RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _lightTheme(),
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: _cjkFont, color: Colors.black87),
        child: Scaffold(
          body: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 40, 16, 10),
                color: const Color(0xFFFFF4E0),
                child: Text(
                  banner,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF7A5A12),
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

IdjSubscription _marketSubscription() {
  IdjSubscriptionPlugin plugin(
    String id,
    String name,
    String version, {
    bool adult = false,
  }) => IdjSubscriptionPlugin(
    id: id,
    name: name,
    version: version,
    type: 'video',
    adult: adult,
    description: '',
    manifestUrl: 'https://example.com/$id.json',
  );
  return IdjSubscription(
    url: 'https://example.com/sub.json',
    name: '演示插件订阅',
    plugins: [
      // 橙果已装同版 → 「已安装」；爱果有新版 → 「更新」；其余未装 → 「安装」。
      plugin('com.idj.ext.chengguo', '橙果短剧', '1.0.1', adult: true),
      plugin('com.idj.ext.aiguo', '爱果短剧', '1.2.0', adult: true),
      plugin('com.idj.ext.xingkong', '星空影视', '2.0.3'),
      plugin('com.idj.ext.chaoliu', '🔞潮流AV', '1.4.0', adult: true),
      plugin('com.idj.ext.duanjuwo', '短剧窝', '0.9.8', adult: true),
      plugin('com.idj.ext.qianqian', '千千音乐', '3.1.0'),
    ],
    cms: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    try {
      final bytes = File(
        '/home/hatch/workspace/huoyi_new/cjk_subset.ttf',
      ).readAsBytesSync();
      final loader = FontLoader(_cjkFont)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {}
  });

  late Directory tempDir;
  late IdjPluginStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tempDir = await Directory.systemTemp.createTemp('idj_grid_preview');
    store = IdjPluginStore(
      preferences: prefs,
      rootOverride: tempDir,
      probe: _probeStub,
    );
    await store.installBundleText(
      _bundleText(id: 'com.idj.ext.chengguo', name: '橙果短剧', version: '1.0.1', adult: true),
    );
    await store.installBundleText(
      _bundleText(id: 'com.idj.ext.aiguo', name: '爱果短剧', version: '1.1.0', adult: true),
    );
    await store.installBundleText(
      _bundleText(id: 'com.idj.ext.chaoliu', name: '🔞潮流AV', version: '1.3.5', adult: true),
    );
    await store.installBundleText(
      _bundleText(id: 'com.idj.ext.ai2048', name: '🔞2048AI', version: '1.0.1', adult: true),
    );
    await store.setEnabled('com.idj.ext.ai2048', false);
    await store.installBundleText(
      _bundleText(id: 'com.idj.ext.broken', name: '坏掉的插件', version: '0.1.0'),
    );
    final brokenFile = File(
      '${tempDir.path}/com.idj.ext.broken/bundle.idjplugin',
    );
    if (await brokenFile.exists()) await brokenFile.delete();
  });

  tearDown(() async {
    for (final key in SourceSite.importedSites.keys.toList()) {
      if (key.startsWith('idj_')) SourceSite.importedSites.remove(key);
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('preview installed grid', (tester) async {
    tester.view.physicalSize = const Size(390, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      _wrap(
        key,
        IdjPluginTab(store: store),
        '预览图（演示数据）：已安装插件改三列网格\n'
        '卡片 = 首字图标 + 名称 + 版本 + 状态标签；右上角「⋯」菜单收着\n'
        '详情 / 启用停用 / 检查更新 / 重新安装 / 卸载；已停用置灰、已损坏标红。',
      ),
    );
    await _drainUntil(
      tester,
      () => find.text('已安装（5）').evaluate().isNotEmpty,
    );
    await _shot(tester, key, 'installed_grid.png');
  });

  testWidgets('preview market grid', (tester) async {
    tester.view.physicalSize = const Size(390, 1560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      _wrap(
        key,
        IdjPluginTab(
          store: store,
          initialSubscriptions: [_marketSubscription()],
        ),
        '预览图（演示数据）：插件市场改三列网格，上下滑动\n'
        '卡片按钮三态：安装 / 更新 / 已安装；点「安装」「更新」免确认\n'
        '直接装完，只在装完后给一条结果提示。',
      ),
    );
    await _drainUntil(
      tester,
      () => find.text('已安装（5）').evaluate().isNotEmpty,
    );
    final subscriptionFinder = find.byKey(
      const ValueKey('idj-subscription-https://example.com/sub.json'),
    );
    await tester.ensureVisible(subscriptionFinder);
    await tester.tap(subscriptionFinder);
    await tester.pumpAndSettle();
    // 把订阅网格滚到画面中部再截。
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    await _shot(tester, key, 'market_grid.png');
  });
}
