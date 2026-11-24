import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/core_bridge.dart';
import 'package:moyi/idj_plugin_store.dart';
import 'package:moyi/models.dart';

/// 迷你合成插件（新写，只够覆盖安装链路，绝不粘贴真实 main.js 片段）。
const _miniScript =
    'export default { home: async () => ({}), play: async () => ({}) };';

String _hash(String script) =>
    base64Encode(sha256.convert(utf8.encode(script)).bytes);

Map<String, dynamic> _miniManifestJson({
  String id = 'com.idj.ext.mini',
  String name = '迷你插件',
  String version = '1.0.0',
  String entry = 'main.js',
  String type = 'video',
  bool adult = false,
  List<String> capabilities = const [
    'home',
    'category',
    'search',
    'detail',
    'play',
  ],
  List<String> http = const ['example.com'],
  List<String> media = const ['example.com'],
  String integrity = 'flat',
  String minAppVersion = '1.5',
  String? updateUrl,
  bool cloudflare = false,
  bool login = false,
  bool storage = true,
}) {
  final manifest = <String, dynamic>{
    'schema': 1,
    'id': id,
    'name': name,
    'version': version,
    'entry': entry,
    'type': type,
    'adult': adult,
    'author': 'test',
    'description': '测试用迷你插件',
    'capabilities': capabilities,
    'minAppVersion': minAppVersion,
    'permissions': {
      'http': http,
      'media': media,
      'cloudflare': cloudflare,
      'login': login,
      'storage': storage,
    },
    'settings': [],
  };
  final hash = _hash(_miniScript);
  switch (integrity) {
    case 'flat':
      manifest['integrity'] = 'sha256-$hash';
    case 'object':
      manifest['integrity'] = {
        'files': {entry: 'sha256-$hash'},
      };
    case 'wrong':
      manifest['integrity'] =
          'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    case 'none':
      break;
  }
  if (updateUrl != null) {
    manifest['update'] = {'url': updateUrl};
  }
  return manifest;
}

String _miniBundleText({Map<String, dynamic>? manifestOverride}) {
  final manifest = _miniManifestJson();
  if (manifestOverride != null) manifest.addAll(manifestOverride);
  return jsonEncode({
    'manifest': manifest,
    'files': {'main.js': _miniScript},
  });
}

Future<Map<String, dynamic>> _fakeProbe({
  required String pluginId,
  required String script,
  required Map<String, dynamic> manifest,
}) async => {
  'ok': true,
  'capabilities': ['home', 'play'],
};

void main() {
  late Directory tempDir;
  late IdjPluginStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    IdjPluginStore.probeHandler = null;
    IdjPluginRegistry.onRegistryChanged = null;
    tempDir = Directory.systemTemp.createTempSync('idj_test_');
    store = IdjPluginStore(
      rootOverride: tempDir,
      supportOverride: Directory('${tempDir.path}/support'),
      probe: _fakeProbe,
    );
  });

  tearDown(() async {
    for (final key in SourceSite.importedSites.keys.toList()) {
      if (key.startsWith('idj_')) SourceSite.importedSites.remove(key);
    }
    IdjPluginRegistry.onRegistryChanged = null;
    IdjPluginStore.probeHandler = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('manifest 校验 problems()', () {
    test('合法通过', () {
      final manifest = IdjPluginManifest.fromJson(_miniManifestJson());
      expect(manifest.problems(), isEmpty);
    });

    test('id 不是合法反向域名拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(id: 'not-a-domain'),
      );
      expect(manifest.problems(), ['插件 id 不是合法的反向域名']);
    });

    test('版本不是三段 semver 拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(version: '1.0'),
      );
      expect(manifest.problems(), contains('插件版本不是合法的三段版本号'));
    });

    test('entry 不是 .js 文件名拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(entry: 'main.txt'),
      );
      expect(manifest.problems(), contains('插件入口不是合法的 .js 文件名'));
    });

    test('video 缺 play 能力拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(capabilities: ['home', 'detail']),
      );
      expect(manifest.problems(), contains('缺少 play 能力'));
    });

    test('域名形态不合法拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(http: ['http://example.com']),
      );
      expect(manifest.problems().join(), contains('域名不合法'));
    });

    test('minAppVersion 高于 1.5.2 拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(minAppVersion: '1.6'),
      );
      expect(manifest.problems(), contains('minAppVersion 1.6 高于本机支持的 1.5.2'));
    });

    test('update.url 不是 https 拒一个', () {
      final manifest = IdjPluginManifest.fromJson(
        _miniManifestJson(updateUrl: 'http://example.com/update.json'),
      );
      expect(manifest.problems(), contains('update.url 必须是 https 地址'));
    });
  });

  group('integrity 核对', () {
    test('扁平串形态接受', () {
      final bundle = IdjPluginStore.parseBundleText(_miniBundleText());
      expect(bundle.fileHash, _hash(_miniScript));
    });

    test('对象形态接受', () {
      final manifest = _miniManifestJson(integrity: 'object');
      final bundle = IdjPluginStore.parseBundleText(
        jsonEncode({
          'manifest': manifest,
          'files': {'main.js': _miniScript},
        }),
      );
      expect(bundle.fileHash, _hash(_miniScript));
    });

    test('值不对拒装', () {
      expect(
        () => IdjPluginStore.parseBundleText(
          jsonEncode({
            'manifest': _miniManifestJson(integrity: 'wrong'),
            'files': {'main.js': _miniScript},
          }),
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('完整性校验失败'),
          ),
        ),
      );
    });

    test('多文件不拒绝，只取 files[entry] 当源码', () {
      final bundle = IdjPluginStore.parseBundleText(
        jsonEncode({
          'manifest': _miniManifestJson(),
          'files': {'main.js': _miniScript, 'other.js': 'xxx'},
        }),
      );
      expect(bundle.script, _miniScript);
    });
  });

  group('安装 / 索引 / 注册', () {
    test('安装成功：写盘 + 索引 + 注册，站 key 带 idj_ 前缀', () async {
      var refreshed = 0;
      IdjPluginRegistry.onRegistryChanged = () => refreshed++;
      final installed = await store.installBundleText(_miniBundleText());
      expect(installed.entry.pluginId, 'com.idj.ext.mini');
      expect(installed.entry.siteKey, 'idj_mini');
      expect(installed.entry.enabled, isTrue);
      expect(installed.damaged, isFalse);
      expect(
        await File(
          '${tempDir.path}/com.idj.ext.mini/bundle.idjplugin',
        ).exists(),
        isTrue,
      );
      final site = SourceSite.importedSites['idj_mini'];
      expect(site, isNotNull);
      expect(site!.importType, 'js');
      expect(site.importExt, 'com.idj.ext.mini');
      expect(site.origin, SourceSite.originImport);
      expect(SourceSite.importedJsFiles.containsKey('idj_mini'), isFalse);
      expect(refreshed, greaterThan(0));
      final listed = await store.listInstalled();
      expect(listed.length, 1);
      expect(listed.first.damaged, isFalse);
    });

    test('probe 失败不装、不留半成品', () async {
      Future<Map<String, dynamic>> failingProbe({
        required String pluginId,
        required String script,
        required Map<String, dynamic> manifest,
      }) async => throw AppFailure('试加载失败：插件报错 缺少 play 能力 (E_ARGS)');
      expect(
        () => store.installBundleText(_miniBundleText(), probe: failingProbe),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('缺少 play 能力'),
          ),
        ),
      );
      expect(await store.readIndex(), isEmpty);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
      expect(await tempDir.list().toList(), isEmpty);
    });

    test('没有 probe 接线时明确报错，不静默跳过', () async {
      final noProbeStore = IdjPluginStore(rootOverride: tempDir);
      expect(
        () => noProbeStore.installBundleText(_miniBundleText()),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('插件宿主未就绪'),
          ),
        ),
      );
    });

    test('启用 / 停用只改索引 + 登记，不动包文件', () async {
      await store.installBundleText(_miniBundleText());
      final disabled = await store.setEnabled('com.idj.ext.mini', false);
      expect(disabled.enabled, isFalse);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
      expect(
        await File(
          '${tempDir.path}/com.idj.ext.mini/bundle.idjplugin',
        ).exists(),
        isTrue,
      );
      final enabled = await store.setEnabled('com.idj.ext.mini', true);
      expect(enabled.enabled, isTrue);
      expect(enabled.failures, 0);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isTrue);
    });

    test('卸载删包目录、清索引、注销登记', () async {
      await store.installBundleText(_miniBundleText());
      await store.uninstall('com.idj.ext.mini');
      expect(await store.readIndex(), isEmpty);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
      expect(
        await Directory('${tempDir.path}/com.idj.ext.mini').exists(),
        isFalse,
      );
    });

    test('重装保留原启用态（停用后重装仍停用）', () async {
      await store.installBundleText(_miniBundleText());
      await store.setEnabled('com.idj.ext.mini', false);
      final reinstalled = await store.installBundleText(
        _miniBundleText(manifestOverride: _miniManifestJson(version: '1.0.1')),
      );
      expect(reinstalled.entry.enabled, isFalse);
      expect(reinstalled.entry.version, '1.0.1');
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
    });

    test('启动恢复：已启用重登记，损坏的跳过不拦启动', () async {
      await store.installBundleText(_miniBundleText());
      SourceSite.importedSites.remove('idj_mini');
      final restored = await IdjPluginRegistry.restoreAll(store: store);
      expect(restored.length, 1);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isTrue);
      // 入口脚本改掉一个字符 → 哈希对不上，恢复时跳过。
      final bundleFile = File(
        '${tempDir.path}/com.idj.ext.mini/bundle.idjplugin',
      );
      final bundleText = await bundleFile.readAsString();
      await bundleFile.writeAsString(
        bundleText.replaceFirst('home:', 'home :'),
      );
      SourceSite.importedSites.remove('idj_mini');
      final restoredAgain = await IdjPluginRegistry.restoreAll(store: store);
      expect(restoredAgain.first.damaged, isTrue);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
    });

    test('看门狗：连续 3 次失败自动停用并注销，成功清零', () async {
      await store.installBundleText(_miniBundleText());
      await store.recordFailure('com.idj.ext.mini');
      await store.recordFailure('com.idj.ext.mini');
      var index = await store.readIndex();
      expect(index['com.idj.ext.mini']!.enabled, isTrue);
      await store.recordSuccess('com.idj.ext.mini');
      index = await store.readIndex();
      expect(index['com.idj.ext.mini']!.failures, 0);
      await store.recordFailure('com.idj.ext.mini');
      await store.recordFailure('com.idj.ext.mini');
      await store.recordFailure('com.idj.ext.mini');
      index = await store.readIndex();
      expect(index['com.idj.ext.mini']!.enabled, isFalse);
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
    });
  });

  group('站 key 生成与分区', () {
    test('chaoliu 不被抢：站 key 是 idj_chaoliu，不是裸名', () {
      expect(
        IdjPluginRegistry.siteKeyForPluginId('com.idj.ext.chaoliu'),
        'idj_chaoliu',
      );
    });

    test('末段冲突加 _2', () {
      SourceSite.importedSites['idj_mini'] = const SourceSite(
        'idj_mini',
        '占位',
        '',
        origin: SourceSite.originImport,
        importType: 'js',
      );
      expect(
        IdjPluginRegistry.siteKeyForPluginId('com.idj.ext.mini'),
        'idj_mini_2',
      );
    });

    test('潮流 / 2048 加 🔞 前缀进视频区，橙果 / 爱果不加前缀进短剧区', () {
      final chaoliu = IdjPluginRegistry.siteForPlugin(
        manifest: IdjPluginManifest.fromJson(
          _miniManifestJson(id: 'com.idj.ext.chaoliu', name: '潮流AV'),
        ),
        siteKey: 'idj_chaoliu',
      );
      expect(chaoliu.name, '🔞潮流AV');
      expect(chaoliu.section, SourceSite.sectionVideo);
      final ai2048 = IdjPluginRegistry.siteForPlugin(
        manifest: IdjPluginManifest.fromJson(
          _miniManifestJson(id: 'com.idj.ext.ai2048', name: '2048AI'),
        ),
        siteKey: 'idj_ai2048',
      );
      expect(ai2048.name, '🔞2048AI');
      final chengguo = IdjPluginRegistry.siteForPlugin(
        manifest: IdjPluginManifest.fromJson(
          _miniManifestJson(id: 'com.idj.ext.chengguo', name: '橙果短剧'),
        ),
        siteKey: 'idj_chengguo',
      );
      expect(chengguo.name, '橙果短剧');
      expect(chengguo.section, SourceSite.sectionDrama);
      final aiguo = IdjPluginRegistry.siteForPlugin(
        manifest: IdjPluginManifest.fromJson(
          _miniManifestJson(id: 'com.idj.ext.aiguo', name: '爱果短剧'),
        ),
        siteKey: 'idj_aiguo',
      );
      expect(aiguo.section, SourceSite.sectionDrama);
    });
  });

  group('PermissionDiff', () {
    test('多了域名、开了 CF、adult 由否变是都要再确认', () {
      final oldManifest = IdjPluginManifest.fromJson(_miniManifestJson());
      final newManifest = IdjPluginManifest.fromJson(
        _miniManifestJson(
          version: '1.0.1',
          adult: true,
          http: ['example.com', 'new.test'],
          cloudflare: true,
        ),
      );
      final diff = IdjPluginStore.permissionDiff(oldManifest, newManifest);
      expect(diff.needsConfirmation, isTrue);
      expect(diff.addedDomains, ['new.test']);
      expect(diff.cloudflareEnabled, isTrue);
      expect(diff.adultBecameTrue, isTrue);
      expect(diff.describe().join(), contains('新版本多申请了 1 个域名'));
    });

    test('无差异的更新直接装，不用再确认', () {
      final oldManifest = IdjPluginManifest.fromJson(_miniManifestJson());
      final newManifest = IdjPluginManifest.fromJson(
        _miniManifestJson(version: '1.0.1'),
      );
      final diff = IdjPluginStore.permissionDiff(oldManifest, newManifest);
      expect(diff.needsConfirmation, isFalse);
    });

    test('权限扩大未确认时安装被拒，确认后装上', () async {
      await store.installBundleText(_miniBundleText());
      final widened = jsonEncode({
        'manifest': _miniManifestJson(
          version: '1.0.1',
          http: ['example.com', 'new.test'],
        ),
        'files': {'main.js': _miniScript},
      });
      expect(
        () => store.installBundleText(widened),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('新版本申请了更多权限'),
          ),
        ),
      );
      final installed = await store.installBundleText(
        widened,
        permissionConfirmed: true,
      );
      expect(installed.entry.version, '1.0.1');
    });
  });

  group('订阅解析', () {
    test('manifest 相对地址按订阅地址解析；订阅只展示、不自动装', () {
      final subscription = IdjPluginStore.parseSubscriptionJson({
        'name': '测试订阅',
        'plugins': [
          {
            'id': 'com.idj.ext.mini',
            'name': '迷你插件',
            'manifest': 'pkg/manifest.json',
            'type': 'video',
            'adult': false,
            'version': '1.0.0',
            'description': '简介',
          },
        ],
        'cms': [
          {'name': '采集站A', 'api': 'https://cms.test/api.php', 'adult': true},
        ],
      }, Uri.parse('https://sub.test/dir/list.json'));
      expect(subscription.name, '测试订阅');
      expect(subscription.plugins.length, 1);
      expect(
        subscription.plugins.first.manifestUrl,
        'https://sub.test/dir/pkg/manifest.json',
      );
      expect(subscription.cms.length, 1);
      expect(subscription.cms.first.name, '采集站A');
      expect(subscription.cms.first.api, 'https://cms.test/api.php');
      // 解析只是数据，不装插件、不注册站点。
      expect(SourceSite.importedSites.containsKey('idj_mini'), isFalse);
    });

    test('相对地址解析失败的条目跳过记日志', () {
      final subscription = IdjPluginStore.parseSubscriptionJson({
        'name': '坏订阅',
        'plugins': [
          {
            'id': 'com.idj.ext.bad',
            'name': '坏插件',
            'manifest': '://bad url',
            'version': '1.0.0',
          },
          {
            'id': 'com.idj.ext.mini',
            'name': '迷你插件',
            'manifest': 'pkg/manifest.json',
            'version': '1.0.0',
          },
        ],
      }, Uri.parse('https://sub.test/list.json'));
      expect(subscription.plugins.length, 1);
      expect(subscription.plugins.first.id, 'com.idj.ext.mini');
    });
  });

  group('interpret 分流', () {
    test('M3U 报请走直播导入，不走安装器', () async {
      final result = await store.interpretText(
        '#EXTM3U\n#EXTINF:-1,频道\nhttps://live.test/1.m3u8',
      );
      expect(result.kind, IdjInterpretKind.m3u);
      expect(result.message, contains('请走直播导入'));
    });

    test('TVBox JSON 拒绝', () async {
      final result = await store.interpretText(
        jsonEncode({
          'sites': [
            {'key': 'x', 'name': 'x'},
          ],
        }),
      );
      expect(result.kind, IdjInterpretKind.tvbox);
      expect(result.message, contains('TVBox 配置'));
    });

    test('含 manifest + files 的 JSON 走安装链', () async {
      final result = await store.interpretText(_miniBundleText());
      expect(result.kind, IdjInterpretKind.bundle);
      expect(result.bundleText, isNotNull);
    });

    test('含 plugins 的 JSON 走订阅流程', () async {
      final result = await store.interpretText(
        jsonEncode({'name': '订阅', 'plugins': []}),
      );
      expect(result.kind, IdjInterpretKind.subscription);
    });

    test('都不是时报错', () async {
      final result = await store.interpretText('hello world');
      expect(result.kind, IdjInterpretKind.unsupported);
      expect(result.message, '这个链接不是插件 manifest / .idjplugin / 订阅列表 / M3U');
    });

    test('单个 manifest 无脚本地址时明确报错', () async {
      final result = await store.interpretText(jsonEncode(_miniManifestJson()));
      expect(result.kind, IdjInterpretKind.unsupported);
      expect(result.message, contains('缺少入口脚本地址'));
    });
  });

  group('下载器规则（不联网，只验拒绝分支）', () {
    test('http 地址拒绝', () async {
      expect(
        () => store.downloadText(
          Uri.parse('http://example.com/x.idjplugin'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('只支持 HTTPS 公网地址'),
          ),
        ),
      );
    });

    test('IP 字面量拒绝', () async {
      expect(
        () => store.downloadText(
          Uri.parse('https://127.0.0.1/x.idjplugin'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('只支持 HTTPS 公网地址'),
          ),
        ),
      );
    });
  });

  group('models 接线', () {
    test('pickerCategoryGroups：短剧类 / 视频类 / 午夜类，短剧 🔞 站留短剧类', () {
      final groups = SourceGroup.pickerCategoryGroups([
        const SourceSite('a', '短剧站', '', section: SourceSite.sectionDrama),
        const SourceSite('b', '🔞短剧站', '', section: SourceSite.sectionDrama),
        const SourceSite('c', '视频站', '', section: SourceSite.sectionVideo),
        const SourceSite('d', '🔞潮流AV', '', section: SourceSite.sectionVideo),
      ]);
      expect(groups.map((group) => group.name), ['短剧类', '视频类', '午夜类']);
      expect(groups[0].sources.map((site) => site.id), ['a', 'b']);
      expect(groups[1].sources.map((site) => site.id), ['c']);
      expect(groups[2].sources.map((site) => site.id), ['d']);
    });

    test('空组不出现', () {
      final groups = SourceGroup.pickerCategoryGroups([
        const SourceSite('c', '视频站', '', section: SourceSite.sectionVideo),
      ]);
      expect(groups.length, 1);
      expect(groups.first.name, '视频类');
    });

    test('duanjuOnlineSearch / duanjuPaged 规则式：短剧 js 站自动获得', () {
      const dramaJs = SourceSite(
        'idj_chengguo',
        '橙果短剧',
        '',
        section: SourceSite.sectionDrama,
        origin: SourceSite.originImport,
        importType: 'js',
      );
      expect(dramaJs.duanjuOnlineSearch, isTrue);
      expect(dramaJs.duanjuPaged, isTrue);
      const videoJs = SourceSite(
        'idj_chaoliu',
        '🔞潮流AV',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'js',
      );
      expect(videoJs.duanjuOnlineSearch, isFalse);
      expect(videoJs.duanjuPaged, isFalse);
    });

    test('defaultHiddenSiteIds 含两个 idj 成人站', () {
      expect(SourceSite.defaultHiddenSiteIds.contains('idj_chaoliu'), isTrue);
      expect(SourceSite.defaultHiddenSiteIds.contains('idj_ai2048'), isTrue);
    });
  });

  group('更新检查', () {
    test('没有 update.url 的插件不查，直接回空', () async {
      await store.installBundleText(_miniBundleText());
      expect(await store.checkUpdates(), isEmpty);
    });
  });
}
