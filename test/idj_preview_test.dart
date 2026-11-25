// iDuanJu 插件移植预览图：只做测试内截图，不改业务代码。
// 5 张图（设计 docs/idjplugin-system-design.md §8.3 + 任务要求）：
//   1. site_picker_dialog.png —— 真实 SitePickerDialog（居中 Dialog，
//      保持原来形态，不走底部弹窗；图标宫格 + 选中态保留；组标题新格式
//      「短剧类 5」纯文本名 + 空格 + 数；分组走真实
//      SourceGroup.pickerCategoryGroups；片库调用已取消 enableZoneFlip）。
//   2. miniapp_plugin_tab.png —— 真实 IdjPluginTab（小程序内第 4 个
//      tab「插件」；已安装 2 个 + 已停用 1 个置灰 + 已损坏 1 个、安装入口
//      三按钮、订阅区 1 条订阅展开 2 个插件 + 1 个 cms 行、「检查更新」按钮）。
//   3./4. 原 install_confirm_sheet.png 与 local_import_flow.png 两图
//      已随 2026-11-25「安装免确认」口径取消：安装确认 sheet 组件已删，
//      点安装直接装完只给结果提示；三列网格新图见
//      test/idj_plugin_grid_preview_test.dart。
//   5. library_with_idj.png —— 装好 4 个插件后片库里的站：真实
//      SitePickerDialog，短剧类含橙果/爱果、午夜类含 🔞潮流AV/🔞2048AI，
//      用假的已安装登记渲染，宿主顶栏注明是假登记示意。
//   6. idj_builtin_repo.png —— 内置远程仓库：真实 IdjPluginTab，订阅区
//      只有内置仓库一条（7 个插件：4 个原插件 + 3 个新插件），默认展开、
//      带「内置」徽标、无删除按钮；图写到本工作树 preview/ 目录。
// 假数据：站名取自树内真实站名；4 个插件的版本/id/域名取自设计文档 §2.6
//（实施时以包文件为准）；插件脚本是新写的迷你合成脚本，绝不粘贴真实
// main.js 片段。站 id 统一加 idj_/fake_ 前缀：SiteIcon 会按 id 查
// jar/py 桥接表派生站标候选，用假 id 撞上真表会触发联网取图；前缀 id
// 查不到表，只显示图案标，不联网。
// 注意：调过 toImage 的测试在收尾时会挂起——跑单测、超时杀掉只取 PNG；
// 绝不把本文件与普通测试批量跑在一次调用里。
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
import 'package:moyi/source_picker_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previewDir = '/home/hatch/workspace/moyi_idjplugin_20261124/previews';
const _cjkFont = 'PreviewCJK';

// ---------- 迷你合成插件（新写，只够覆盖安装链路） ----------

const _miniScript =
    'export default { home: async () => ({}), play: async () => ({}) };';

String _hash(String script) =>
    base64Encode(sha256.convert(utf8.encode(script)).bytes);

String _bundleText({
  required String id,
  required String name,
  required String version,
  bool adult = false,
  List<String> http = const ['example.com'],
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
    'description': '测试用迷你插件',
    'capabilities': ['home', 'category', 'search', 'detail', 'play'],
    'minAppVersion': '1.5',
    'permissions': {
      'http': http,
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

// 橙果形态的 manifest（设计 §2.6 的 7 个 http 域名）。
const _chengguoDomains = <String>[
  'api2.chengguodj.com',
  'chengguodj.com',
  'www.chengguodj.com',
  'hls.ohjzmm.cn',
  '*.ohjzmm.cn',
  'mts.hhjd.mobi',
  '*.hhjd.mobi',
];

String _chengguoBundle({String version = '1.0.1'}) => _bundleText(
  id: 'com.idj.ext.chengguo',
  name: '橙果短剧',
  version: version,
  adult: true,
  http: _chengguoDomains,
);

// ---------- 截图工具 ----------

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    try {
      await tester.pump(const Duration(milliseconds: 100));
    } catch (_) {}
  }
}

// 真 I/O 加载链的排干：单次 runAsync + pump 只够推进一步，
// 轮询到目标出现为止（见 test/idj_plugin_tab_test.dart 的 drain）。
Future<void> _drainUntil(
  WidgetTester tester,
  bool Function() until,
) async {
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

/// 图 6 专用：写到本工作树 preview/ 目录（旧 5 张图的目录是上一棵树）。
Future<void> _shotHere(
  WidgetTester tester,
  GlobalKey key,
  String file,
) async {
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  const dir = '/home/hatch/workspace/moyi_idjplugin_fix_20261124/preview';
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  Directory(dir).createSync(recursive: true);
  File('$dir/$file').writeAsBytesSync(bytes);
}

/// 图 6 的订阅：内置远程仓库测试索引（7 条，格式与转换工人产物一致）。
IdjSubscription _builtinSubscription() {
  final fixture = File(
    '/home/hatch/workspace/moyi_idjplugin_fix_20261124/test/fixtures/idj_builtin_subscription.json',
  ).readAsStringSync();
  return IdjPluginStore.parseSubscriptionJson(
    jsonDecode(fixture) as Map<String, dynamic>,
    Uri.parse(idjBuiltInSubscriptionUrl),
  );
}

ThemeData _lightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _cjkFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _cjkFont),
  );
}

Widget _wrap(GlobalKey key, Widget child) {
  return RepaintBoundary(
    key: key,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _lightTheme(),
      home: DefaultTextStyle(
        style: const TextStyle(fontFamily: _cjkFont, color: Colors.black87),
        child: child,
      ),
    ),
  );
}

// ---------- 图 1/图 5 共用：假站 + 真实分组 ----------

SourceSite _site(
  String id,
  String name, {
  String section = SourceSite.sectionDrama,
  String origin = SourceSite.originBuiltin,
  String importType = '',
}) => SourceSite(
  id,
  name,
  '',
  section: section,
  origin: origin,
  importType: importType,
);

/// 图 1 的 13 个假站：短剧 5（含 1 个 idj 假站橙果，其中 1 个短剧站
/// 带 🔞 前缀，验收它仍在短剧类、不进午夜类）、视频 4、午夜 3
///（含 🔞潮流AV、🔞2048AI 假站）；另含 1 个 py 导入站（麒麟影视，
/// 证明导入站没丢，进视频类）。
List<SourceSite> _dialogSites() => [
  _site('idj_chengguo', '橙果短剧'),
  _site('fake_dj69', '🔞69短剧'),
  _site('fake_dj91', '91短剧'),
  _site('fake_duanjuwo', '短剧窝'),
  _site('fake_duanjuone', '短剧one'),
  _site('fake_duoduo', '多多', section: SourceSite.sectionVideo),
  _site('fake_6789', '6789', section: SourceSite.sectionVideo),
  _site('fake_xingkong', '星空', section: SourceSite.sectionVideo),
  _site('fake_qianqian', '千千', section: SourceSite.sectionVideo),
  _site(
    'fake_qilin_py',
    '麒麟影视',
    section: SourceSite.sectionVideo,
    origin: SourceSite.originImport,
    importType: 'py',
  ),
  _site('idj_chaoliu', '🔞潮流AV', section: SourceSite.sectionVideo),
  _site('idj_ai2048', '🔞2048AI', section: SourceSite.sectionVideo),
  _site('fake_missav', '🔞MissAV', section: SourceSite.sectionVideo),
];

/// 图 5 的假登记：4 个已安装插件 + 2 个普通站。
List<SourceSite> _librarySites() => [
  _site('idj_chengguo', '橙果短剧'),
  _site('idj_aiguo', '爱果短剧'),
  _site('fake_dj69', '69短剧'),
  _site('fake_dj91', '91短剧'),
  _site('fake_duoduo', '多多', section: SourceSite.sectionVideo),
  _site('fake_6789', '6789', section: SourceSite.sectionVideo),
  _site('idj_chaoliu', '🔞潮流AV', section: SourceSite.sectionVideo),
  _site('idj_ai2048', '🔞2048AI', section: SourceSite.sectionVideo),
];

List<SourcePickerGroup> _pickerGroups(List<SourceSite> sites) => [
  const SourcePickerGroup(
    title: '',
    entries: [SourcePickerEntry(id: '__all__', name: '全部站源')],
  ),
  for (final group in SourceGroup.pickerCategoryGroups(sites))
    SourcePickerGroup(
      title: group.name,
      entries: [
        for (final site in group.sources)
          SourcePickerEntry(id: site.id, name: site.name),
      ],
    ),
];

Widget _dialogHost({
  required List<SourceSite> sites,
  required String currentId,
  String? banner,
}) {
  return Scaffold(
    backgroundColor: const Color(0xFF8A8F96),
    body: Column(
      children: [
        if (banner != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 12),
            color: const Color(0xFFFFF4E0),
            child: Text(
              banner,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF7A5A12)),
            ),
          ),
        Expanded(
          child: Center(
            child: Builder(
              builder: (context) => FilledButton(
                // 按片库区真实调用：不传 enableZoneFlip（已取消翻页），
                // 传 onDeleteSite + onImport（+ 号与长按删除提示都在）。
                onPressed: () => showSitePickerDialog(
                  context,
                  sectionName: '片库',
                  currentId: currentId,
                  groups: _pickerGroups(sites),
                  onDeleteSite: (_) async => false,
                  onImport: () async {},
                ),
                child: const Text('切换片库源'),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

// ---------- 图 2：真实插件 tab ----------

IdjSubscription _previewSubscription() => IdjSubscription(
  url: 'https://example.com/sub.json',
  name: 'yydsys 插件订阅',
  plugins: [
    IdjSubscriptionPlugin(
      id: 'com.idj.ext.chengguo',
      name: '橙果短剧',
      version: '1.0.1',
      type: 'video',
      adult: true,
      description: '短剧插件',
      manifestUrl: 'https://example.com/chengguo.json',
    ),
    IdjSubscriptionPlugin(
      id: 'com.idj.ext.chaoliu',
      name: '🔞潮流AV',
      version: '1.4.0',
      type: 'video',
      adult: true,
      description: '',
      manifestUrl: 'https://example.com/chaoliu.json',
    ),
  ],
  cms: [
    IdjSubscriptionCms(
      name: 'CMS 采集站示例',
      api: 'https://cms.example.com/api.php',
      adult: false,
    ),
  ],
);

Widget _pluginTabHost(
  IdjPluginStore store, {
  List<IdjSubscription>? subscriptions,
}) {
  return DefaultTabController(
    length: 4,
    initialIndex: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('小程序', style: TextStyle(fontSize: 18)),
        centerTitle: false,
        actions: const [
          Icon(Icons.add),
          SizedBox(width: 16),
          Icon(Icons.grid_view_rounded),
          SizedBox(width: 16),
          Icon(Icons.settings_outlined),
          SizedBox(width: 12),
        ],
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          unselectedLabelStyle: TextStyle(fontSize: 14),
          tabs: [
            Tab(text: '已安装'),
            Tab(text: '市场'),
            Tab(text: '海阔'),
            Tab(text: '插件'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          const Center(child: Text('已安装 tab（示意）')),
          const Center(child: Text('市场 tab（示意）')),
          const Center(child: Text('海阔 tab（示意）')),
          IdjPluginTab(
            store: store,
            initialSubscriptions: subscriptions ?? [_previewSubscription()],
          ),
        ],
      ),
    ),
  );
}

// ---------- 测试 ----------

void main() {
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

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('idj_preview');
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = IdjPluginStore(
      preferences: prefs,
      rootOverride: tempDir,
      probe: _probeStub,
    );
    // 图 2 的种子：已安装 2 个（橙果、潮流）+ 已停用 1 个（2048）
    // + 已损坏 1 个（删包文件）。
    await store.installBundleText(_chengguoBundle());
    await store.installBundleText(
      _bundleText(
        id: 'com.idj.ext.chaoliu',
        name: '潮流AV',
        version: '1.3.5',
        adult: true,
      ),
    );
    await store.installBundleText(
      _bundleText(
        id: 'com.idj.ext.ai2048',
        name: '2048AI',
        version: '1.0.1',
        adult: true,
      ),
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

  tearDown(() {
    for (final key in SourceSite.importedSites.keys.toList()) {
      if (key.startsWith('idj_')) SourceSite.importedSites.remove(key);
    }
  });

  testWidgets('preview idj site picker dialog', (tester) async {
    // 视口加高到 1300：对话框高上限是视口的 0.7，13 个站三组全显
    // 约需 850 以上；1000 高时午夜组会被截断。
    tester.view.physicalSize = const Size(390, 1300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      _wrap(key, _dialogHost(sites: _dialogSites(), currentId: 'idj_chengguo')),
    );
    await _settle(tester);
    await tester.tap(find.text('切换片库源'));
    await _settle(tester);
    await _shot(tester, key, 'site_picker_dialog.png');
  });

  testWidgets('preview idj plugin tab', (tester) async {
    // 插件 tab 是可滚动的整页：用加高视口一次截全页（手机上是上下滑动看完）。
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(_wrap(key, _pluginTabHost(store)));
    await _drainUntil(
      tester,
      () => find.text('已安装（4）').evaluate().isNotEmpty,
    );
    // 展开订阅，截到 2 个插件行 + 1 个 cms 行。
    final subscriptionFinder = find.byKey(
      const ValueKey('idj-subscription-https://example.com/sub.json'),
    );
    await tester.ensureVisible(subscriptionFinder);
    await tester.tap(subscriptionFinder);
    await tester.pumpAndSettle();
    await _shot(tester, key, 'miniapp_plugin_tab.png');
  });

  testWidgets('preview idj builtin repo', (tester) async {
    // 内置仓库 7 个插件行比图 2 高：视口加高一次截全页。
    tester.view.physicalSize = const Size(390, 2300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      _wrap(key, _pluginTabHost(store, subscriptions: [_builtinSubscription()])),
    );
    await _drainUntil(
      tester,
      () => find.text('已安装（4）').evaluate().isNotEmpty,
    );
    // 内置仓库默认展开：不用点就看到 7 个插件行。
    expect(find.text('魔蚁插件订阅'), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-builtin-badge')), findsOneWidget);
    expect(find.text('PornTube'), findsOneWidget);
    expect(find.text('HQPorner'), findsOneWidget);
    await _shotHere(tester, key, 'idj_builtin_repo.png');
  });

  testWidgets('preview idj library with plugins', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      _wrap(
        key,
        _dialogHost(
          sites: _librarySites(),
          currentId: 'idj_aiguo',
          banner: '假登记示意：4 个插件已安装进片库（未真装），短剧类含橙果/爱果，午夜类含 🔞潮流AV/🔞2048AI',
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('切换片库源'));
    await _settle(tester);
    await _shot(tester, key, 'library_with_idj.png');
  });
}
