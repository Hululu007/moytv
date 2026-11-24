// iDuanJu 插件 tab widget 测试：只测 UI 层（lib/miniapp/idj_plugin_tab.dart），
// 安装链本身由 test/idj_plugin_store_test.dart 覆盖。
// 用合成迷你插件做假数据（新写脚本，绝不粘贴真实 main.js 片段）。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/idj_plugin_store.dart';
import 'package:moyi/miniapp/idj_plugin_tab.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _miniScript =
    'export default { home: async () => ({}), play: async () => ({}) };';

String _hash(String script) =>
    base64Encode(sha256.convert(utf8.encode(script)).bytes);

String _bundleText({
  required String id,
  required String name,
  required String version,
  String type = 'video',
  bool adult = false,
  List<String> http = const ['example.com'],
  List<String> media = const ['example.com'],
}) {
  final manifest = <String, dynamic>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'entry': 'main.js',
    'type': type,
    'adult': adult,
    'author': 'test',
    'description': '测试用迷你插件',
    'capabilities': ['home', 'category', 'search', 'detail', 'play'],
    'minAppVersion': '1.5',
    'permissions': {
      'http': http,
      'media': media,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late IdjPluginStore store;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('idj_tab_test');
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
    // 4 个真插件的名字 + id（名是事实，不涉代码复制）：
    // 橙果/爱果短剧区、潮流/2048 成人区（按 store 的 id 表定分区）。
    await store.installBundleText(
      _bundleText(
        id: 'com.idj.ext.chengguo',
        name: '橙果短剧',
        version: '1.0.1',
        adult: true,
        http: const [
          'api2.chengguodj.com',
          'chengguodj.com',
          'www.chengguodj.com',
          'hls.ohjzmm.cn',
          '*.ohjzmm.cn',
          'mts.hhjd.mobi',
          '*.hhjd.mobi',
        ],
      ),
    );
    await store.installBundleText(
      _bundleText(
        id: 'com.idj.ext.aiguo',
        name: '爱果短剧',
        version: '1.0.1',
        adult: true,
      ),
    );
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
    // 2048 停用；再装一个随后删包文件的，验已损坏行。
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

  // 交替排干：tab 的 _refreshAll 与点按后的变更链都是真 I/O，
  // 单次 runAsync + pump 只够把等待链推进一步（见 mini_app 的同款注释）。
  // 传了 until 就按目标状态轮询（变更链没有转圈，不能按“无 spinner”停）；
  // 不传时按加载态过去就停。
  Future<void> drain(
    WidgetTester tester, {
    bool Function()? until,
  }) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      if (until != null) {
        if (until()) break;
      } else if (i >= 11 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    await tester.pump();
  }

  Future<void> pumpTab(
    WidgetTester tester, {
    List<IdjSubscription>? subscriptions,
    List<IdjUpdateCandidate>? updates,
  }) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IdjPluginTab(
            store: store,
            initialSubscriptions: subscriptions,
            initialUpdateCandidates: updates,
          ),
        ),
      ),
    );
    await drain(
      tester,
      until: () => find.text('已安装（5）').evaluate().isNotEmpty,
    );
  }

  test('seed check：不渲染 widget，只查 store 的已安装列表', () async {
    final listed = await store.listInstalled();
    expect(listed.length, 5);
    expect(listed.where((item) => item.damaged).length, 1);
  });

  testWidgets('已安装区：启用/停用/损坏三态与四区齐全', (tester) async {
    await pumpTab(tester);

    expect(find.text('已安装（5）'), findsOneWidget);
    expect(find.text('橙果短剧'), findsOneWidget);
    expect(find.text('🔞潮流AV'), findsOneWidget);
    expect(find.text('🔞2048AI'), findsOneWidget);
    // 已停用行置灰标“已停用”，只 2048 一行。
    expect(find.text('已停用'), findsOneWidget);
    // 已损坏行标“已损坏”，只给「卸载」「重新安装」。
    expect(find.text('已损坏'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('idj-reinstall-com.idj.ext.broken')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('idj-detail-com.idj.ext.broken')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('idj-check-one-com.idj.ext.broken')),
      findsNothing,
    );
    // 安装入口三按钮 + 订阅区 + 更新检查按钮都在。
    expect(find.byKey(const ValueKey('idj-install-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-install-file')), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-install-paste')), findsOneWidget);
    // 订阅区永远有内置远程仓库这一条（测试环境拉不到真索引，只留报错卡）。
    expect(find.text('订阅（1）'), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-builtin-badge')), findsOneWidget);
    expect(
      find.byKey(ValueKey('idj-sub-delete-$idjBuiltInSubscriptionUrl')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('idj-check-updates')), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-add-subscription')), findsOneWidget);
  });

  testWidgets('启用开关：关掉橙果后行变“已停用”', (tester) async {
    await pumpTab(tester);

    final switchFinder = find.byKey(
      const ValueKey('idj-switch-com.idj.ext.chengguo'),
    );
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    await drain(
      tester,
      until: () => find.text('已停用').evaluate().length == 2,
    );

    // 橙果 + 2048 两行已停用。
    expect(find.text('已停用'), findsNWidgets(2));
    expect(SourceSite.importedSites.containsKey('idj_chengguo'), isFalse);
  });

  testWidgets('卸载：确认后行消失、片库登记注销', (tester) async {
    await pumpTab(tester);
    expect(SourceSite.importedSites.containsKey('idj_aiguo'), isTrue);

    final uninstallFinder = find.byKey(
      const ValueKey('idj-uninstall-com.idj.ext.aiguo'),
    );
    await tester.ensureVisible(uninstallFinder);
    await tester.tap(uninstallFinder);
    await tester.pumpAndSettle();
    expect(find.text('卸载插件'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await drain(
      tester,
      until: () => find.text('爱果短剧').evaluate().isEmpty,
    );

    expect(find.text('爱果短剧'), findsNothing);
    expect(SourceSite.importedSites.containsKey('idj_aiguo'), isFalse);
  });

  testWidgets('订阅区：展开一条订阅见插件行与 cms 行（只展示）', (tester) async {
    final subscription = IdjSubscription(
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
        IdjSubscriptionCms(name: 'CMS 采集站示例', api: 'https://cms.example.com/api.php', adult: false),
      ],
    );
    await pumpTab(tester, subscriptions: [subscription]);

    expect(find.text('yydsys 插件订阅'), findsOneWidget);
    // 未展开时订阅里的插件行不出现（只有已安装区的橙果一行）。
    expect(find.text('橙果短剧'), findsOneWidget);
    expect(find.text('🔞潮流AV'), findsOneWidget);

    final subscriptionFinder = find.byKey(
      const ValueKey('idj-subscription-https://example.com/sub.json'),
    );
    await tester.ensureVisible(subscriptionFinder);
    await tester.tap(subscriptionFinder);
    await tester.pumpAndSettle();

    // 展开后订阅里的两行插件 + cms 行都出现。
    expect(find.text('橙果短剧'), findsNWidgets(2));
    expect(find.text('🔞潮流AV'), findsNWidgets(2));
    expect(find.text('CMS 采集站示例'), findsOneWidget);
    expect(find.text('只展示'), findsOneWidget);
    // 橙果已装同版：订阅行按钮是“已安装”且置灰。
    expect(find.text('已安装'), findsOneWidget);
  });

  testWidgets('内置远程仓库：打开即展开见 7 个插件，有“内置”徽标、无删除按钮', (tester) async {
    final fixture = File(
      '/home/hatch/workspace/moyi_idjplugin_fix_20261124/test/fixtures/idj_builtin_subscription.json',
    ).readAsStringSync();
    final subscription = IdjPluginStore.parseSubscriptionJson(
      jsonDecode(fixture) as Map<String, dynamic>,
      Uri.parse(idjBuiltInSubscriptionUrl),
    );
    await pumpTab(tester, subscriptions: [subscription]);

    expect(find.text('订阅（1）'), findsOneWidget);
    expect(find.text('魔蚁插件订阅'), findsOneWidget);
    expect(find.byKey(const ValueKey('idj-builtin-badge')), findsOneWidget);
    // 内置仓库不可删：没有删除按钮，刷新按钮还在。
    expect(
      find.byKey(ValueKey('idj-sub-delete-$idjBuiltInSubscriptionUrl')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('idj-sub-refresh-$idjBuiltInSubscriptionUrl')),
      findsOneWidget,
    );
    // 默认展开：不用点就看到 7 个插件行（4 个已装同版 + 3 个新插件）。
    expect(find.text('橙果短剧'), findsNWidgets(2));
    expect(find.text('爱果短剧'), findsNWidgets(2));
    expect(find.text('PornTube'), findsOneWidget);
    expect(find.text('妻友社'), findsOneWidget);
    expect(find.text('HQPorner'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('idj-sub-install-com.idj.ext.porntube')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('idj-sub-install-com.idj.ext.qiyoushe')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('idj-sub-install-com.idj.ext.hqporner')),
      findsOneWidget,
    );
    expect(find.text('安装'), findsNWidgets(3));
  });

  testWidgets('更新候选：注入的候选逐条列出带“更新”按钮', (tester) async {
    final manifest = IdjPluginManifest.fromJson(
      jsonDecode(
        _bundleText(
          id: 'com.idj.ext.chengguo',
          name: '橙果短剧',
          version: '1.0.2',
          adult: true,
        ),
      )['manifest'] as Map<String, dynamic>,
    );
    await pumpTab(
      tester,
      updates: [
        IdjUpdateCandidate(
          pluginId: 'com.idj.ext.chengguo',
          currentVersion: '1.0.1',
          latestVersion: '1.0.2',
          manifest: manifest,
        ),
      ],
    );

    expect(find.text('v1.0.1 → v1.0.2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('idj-update-com.idj.ext.chengguo')),
      findsOneWidget,
    );
  });

  group('安装确认 sheet 分区文案', () {
    Future<void> pumpSheet(
      WidgetTester tester, {
      required String text,
      IdjPluginManifest? oldManifest,
    }) async {
      final bundle = IdjPluginStore.parseBundleText(text);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IdjInstallConfirmSheet(
              bundle: bundle,
              bundleBytes: utf8.encode(text).length,
              oldManifest: oldManifest,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('橙果：短剧区文案，不写午夜组', (tester) async {
      final text = _bundleText(
        id: 'com.idj.ext.chengguo',
        name: '橙果短剧',
        version: '1.0.1',
        adult: true,
        http: const [
          'api2.chengguodj.com',
          'chengguodj.com',
          'www.chengguodj.com',
          'hls.ohjzmm.cn',
          '*.ohjzmm.cn',
          'mts.hhjd.mobi',
          '*.hhjd.mobi',
        ],
      );
      await pumpSheet(tester, text: text);

      expect(find.text('橙果短剧'), findsOneWidget);
      expect(find.text('v1.0.1'), findsOneWidget);
      expect(find.text('com.idj.ext.chengguo'), findsOneWidget);
      expect(find.text('申请域名（7 个）'), findsOneWidget);
      expect(
        find.text('短剧插件：装好后进短剧区，可在片库短剧区找到'),
        findsOneWidget,
      );
      expect(find.textContaining('午夜组'), findsNothing);
      expect(find.text('安装'), findsOneWidget);
    });

    testWidgets('潮流：午夜组文案', (tester) async {
      final text = _bundleText(
        id: 'com.idj.ext.chaoliu',
        name: '潮流AV',
        version: '1.3.5',
        adult: true,
      );
      await pumpSheet(tester, text: text);

      expect(
        find.text('成人插件：装好后进午夜组，默认不对新用户显示'),
        findsOneWidget,
      );
      expect(find.textContaining('短剧区'), findsNothing);
    });

    testWidgets('更新场景：PermissionDiff 差异列出，按钮变“确认更新”', (tester) async {
      final oldText = _bundleText(
        id: 'com.idj.ext.chengguo',
        name: '橙果短剧',
        version: '1.0.0',
        adult: true,
        http: const ['chengguodj.com'],
      );
      final newText = _bundleText(
        id: 'com.idj.ext.chengguo',
        name: '橙果短剧',
        version: '1.0.1',
        adult: true,
        http: const ['chengguodj.com', 'api2.chengguodj.com', 'hls.ohjzmm.cn'],
      );
      final oldManifest = IdjPluginStore.parseBundleText(oldText).manifest;
      await pumpSheet(tester, text: newText, oldManifest: oldManifest);

      expect(find.text('新版本权限变化'), findsOneWidget);
      expect(find.textContaining('新版本多申请了 2 个域名'), findsOneWidget);
      expect(find.text('确认更新'), findsOneWidget);
      expect(find.text('安装'), findsNothing);
    });
  });
}
