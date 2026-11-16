import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_helpers.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('标题归一与跨规则匹配', () {
    test('花体数字折叠为 ASCII', () {
      expect(normalizeRuleTitle('𝟕𝐌𝐌𝐓𝐕'), '7mmtv');
    });

    test('去 🔞、全角、大小写折叠', () {
      expect(normalizeRuleTitle('🔞ＡＢＣ'), 'abc');
      expect(normalizeRuleTitle('  JavMenu '), 'javmenu');
    });

    test('matchRuleTitle 三级：精确优先', () {
      const titles = ['JavMenu', '🔞JavMenu', 'javmenu'];
      expect(matchRuleTitle('JavMenu', titles), 'JavMenu');
      expect(matchRuleTitle('🔞JavMenu', titles), '🔞JavMenu');
    });

    test('matchRuleTitle：去 🔞 与归一化兜底', () {
      const titles = ['🔞JavMenu'];
      expect(matchRuleTitle('JavMenu', titles), '🔞JavMenu');
      expect(matchRuleTitle('𝟕𝐌𝐌𝐓𝐕', ['7MMTV']), '7MMTV');
      expect(matchRuleTitle('不存在的规则', titles), isNull);
      expect(matchRuleTitle('', titles), isNull);
    });
  });

  group('预置模块解析', () {
    const manifest = <String, List<String>>{
      'Tnaflix': ['Tnaflix__Apollo.js'],
      'Jav精品': ['Jav精品__𝟕𝐌𝐌𝐓𝐕.js'],
      'Xvideos': ['Xvideos__Apollo.js', 'shared_util.js'],
    };

    test('当前规则映射：标题 + .js 取 Apollo 引擎', () {
      expect(
        resolvePresetModule(
          requestBasename: 'Tnaflix.js',
          ruleTitle: 'Tnaflix',
          manifest: manifest,
        ),
        'Tnaflix__Apollo.js',
      );
    });

    test('花体标题动态取模块', () {
      expect(
        resolvePresetModule(
          requestBasename: '𝟕𝐌𝐌𝐓𝐕.js',
          ruleTitle: 'Jav精品',
          manifest: manifest,
        ),
        'Jav精品__𝟕𝐌𝐌𝐓𝐕.js',
      );
    });

    test('__ 后缀与精确文件名', () {
      expect(
        resolvePresetModule(
          requestBasename: 'Apollo.js',
          ruleTitle: '别的规则',
          manifest: manifest,
        ),
        'Tnaflix__Apollo.js',
      );
      expect(
        resolvePresetModule(
          requestBasename: 'shared_util.js',
          ruleTitle: '别的规则',
          manifest: manifest,
        ),
        'shared_util.js',
      );
    });

    test('找不到回 null，不伪造', () {
      expect(
        resolvePresetModule(
          requestBasename: 'Cookie/abc.txt',
          ruleTitle: 'Tnaflix',
          manifest: manifest,
        ),
        isNull,
      );
    });
  });

  group('代理改写行', () {
    test('含 => 的 proxy 不再误读成代理主机', () {
      expect(parseHaikuoProxy('a.com=>b.com'), isNull);
      expect(parseHaikuoProxy('127.0.0.1:8080'), 'http://127.0.0.1:8080');
    });

    test('改写行按行解析，首个 => 拆分', () {
      final rewrites = parseHaikuoProxyRewrites(
        'old.example.com=>new.example.com\nplain line\nx=>y=>z',
      );
      expect(rewrites, [
        ('old.example.com', 'new.example.com'),
        ('x', 'y=>z'),
      ]);
    });

    test('包含匹配、首条命中替换', () {
      const rewrites = [('old.com', 'new.com'), ('/v1/', '/v2/')];
      expect(
        applyHaikuoProxyRewrites('https://cdn.old.com/v1/a.m3u8', rewrites),
        'https://cdn.new.com/v1/a.m3u8',
      );
      expect(
        applyHaikuoProxyRewrites('https://x.com/v1/a.m3u8', rewrites),
        'https://x.com/v2/a.m3u8',
      );
      expect(
        applyHaikuoProxyRewrites('https://x.com/a.m3u8', rewrites),
        'https://x.com/a.m3u8',
      );
    });
  });

  group('嗅探与通配', () {
    test('指南例：video*m3u*.ts 包含匹配命中中间段', () {
      expect(
        pickSniffedVideoUrl(
          ['https://cdn.example.com/xx/video123m3u8ab.ts?x=1'],
          includeRules: ['video*m3u*.ts'],
        ),
        'https://cdn.example.com/xx/video123m3u8ab.ts?x=1',
      );
    });

    test('排除规则包含匹配', () {
      expect(
        pickSniffedVideoUrl(
          [
            'https://ad.example.com/a.mp4',
            'https://cdn.example.com/b.mp4',
          ],
          excludeRules: ['*ad*'],
        ),
        'https://cdn.example.com/b.mp4',
      );
    });

    test('wildcardContains：* 通配 + 包含', () {
      expect(wildcardContains('https://a.com/x/ad.js', '*ad*'), isTrue);
      expect(wildcardContains('https://a.com/x/b.js', '*ad*'), isFalse);
      expect(wildcardContains('https://a.com/video.m3u8', '*.m3u8'), isTrue);
      expect(wildcardContains('https://a.com/', ''), isFalse);
    });

    test('代理服务路径解析', () {
      expect(
        parseProxyServerId('/__proxyserver/ps1_abc/proxy.m3u8'),
        'ps1_abc',
      );
      expect(parseProxyServerId('/__proxyserver/'), isNull);
      expect(parseProxyServerId('/__fetch'), isNull);
    });
  });

  group('PBKDF2', () {
    String hex(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('RFC 6070 SHA1 向量', () {
      List<int> derive(int iterations, int keyBytes) => haikuoPbkdf2(
        password: utf8.encode('password'),
        salt: utf8.encode('salt'),
        iterations: iterations,
        keyBytes: keyBytes,
      );
      expect(
        hex(derive(1, 20)),
        '0c60c80f961f0e71f3a9b524af6012062fe037a6',
      );
      expect(
        hex(derive(2, 20)),
        'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957',
      );
      expect(
        hex(derive(4096, 20)),
        '4b007901b765489abead49d926f721d065a429c1',
      );
    });

    test('SHA256 向量', () {
      expect(
        hex(
          haikuoPbkdf2(
            password: utf8.encode('password'),
            salt: utf8.encode('salt'),
            iterations: 1,
            keyBytes: 32,
            hash: 'sha256',
          ),
        ),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
    });

    test('空口令/空盐不抛错', () {
      expect(
        haikuoPbkdf2(
          password: const [],
          salt: const [],
          iterations: 1,
          keyBytes: 16,
        ).length,
        16,
      );
    });
  });

  group('收藏 / 历史 / 书签存储', () {
    late Directory tempDir;
    late HaikuoStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('haikuo_collections_');
      store = HaikuoStore(rootOverride: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('历史去重置顶 + 规则过滤按归一化标题', () async {
      await store.recordHistory(rule: '🔞A站', url: 'u1', title: '一');
      await store.recordHistory(rule: 'A站', url: 'u2', title: '二');
      await store.recordHistory(rule: '🔞A站', url: 'u1', title: '一新');
      final all = await store.listHistory();
      expect(all.map((e) => e['url']), ['u1', 'u2']);
      expect(all.first['title'], '一新');
      expect((await store.listHistory(rule: 'a站')).length, 2);
      expect((await store.listHistory(rule: 'B站')).length, 0);
    });

    test('历史上限 200 条', () async {
      for (var i = 0; i < 205; i++) {
        await store.recordHistory(rule: 'A', url: 'u$i');
      }
      expect((await store.listHistory()).length, 200);
    });

    test('收藏开关往返 + 分组过滤', () async {
      const entry = {'rule': 'A', 'url': 'u1', 'title': 't', 'group': 'g1'};
      expect(await store.toggleFavorite(entry), isTrue);
      expect(await store.isFavorite(rule: 'A', url: 'u1'), isTrue);
      expect(await store.toggleFavorite(entry), isFalse);
      expect(await store.isFavorite(rule: 'A', url: 'u1'), isFalse);
      await store.toggleFavorite(entry);
      await store.toggleFavorite({
        'rule': 'A',
        'url': 'u2',
        'title': 't2',
        'group': 'g2',
      });
      expect((await store.listFavorites(group: 'g1')).length, 1);
      expect(await store.listFavoriteGroups(), ['g1', 'g2']);
    });

    test('书签增删', () async {
      await store.addBookmark({'rule': 'A', 'url': 'u1', 'title': 't'});
      await store.addBookmark({'rule': 'A', 'url': 'u1', 'title': 't新'});
      expect((await store.listBookmarks()).length, 1);
      expect((await store.listBookmarks()).first['title'], 't新');
      await store.removeBookmark(rule: 'A', url: 'u1');
      expect(await store.listBookmarks(), isEmpty);
    });

    test('收藏文件与规则库文件分离', () async {
      await store.recordHistory(rule: 'A', url: 'u1');
      expect(File('${tempDir.path}/collections.json').existsSync(), isTrue);
      expect(File('${tempDir.path}/programs.json').existsSync(), isFalse);
    });
  });

  group('运行时落点：新增接口与端点', () {
    test('新全局函数与钩子都在', () {
      for (final name in [
        'function getIP',
        'function registerTask',
        'function clearM3u8Ad',
        'function fetchCodeByWebView',
        'function startProxyServer',
        'function getAppVersion',
        'function getRuleCount',
        'function getLastRules',
        'function refreshX5WebView',
        'function setPagePicUrl',
        'function requireDownload',
        'function decodeStr',
        'function aesEncode',
        'function batchExecute',
        'function syncExecute',
        'function writeHexFile',
        'function stripM3u8Ads',
        'function imageSrc',
        'function parseX5Desc',
        'function runAggregatedSearch',
        'function bindLongClick',
        'function parsePlayJson',
        'function isMediaLink',
        'function clearPageTasks',
        'function dollarToString',
        'function makeCryptoJavaModule',
        'function proxyServe',
        'storage0',
        'MY_NAME',
        '__haikuoCryptoJava',
        '__haikuoProxyServe',
        '__haikuoPbkdf2',
        '__haikuoCurrentPage',
        '__haikuoToggleFavorite',
        '__haikuoSearch',
        '__haikuoOpenDetail',
      ]) {
        expect(haikuoRuntimeHtml, contains(name), reason: name);
      }
    });

    test('新端点名都在', () {
      for (final path in [
        '/__img',
        '/__savefile',
        '/__rulepage/',
        '/__findrule',
        '/__ip',
        '/__appinfo',
        '/__lastrules',
        '/__clipboard',
        '/__webview',
        '/__proxyserver/',
        '/__history',
        '/__collection',
        '/__bookmark',
        '/__favorite',
      ]) {
        expect(haikuoRuntimeHtml, contains(path), reason: path);
      }
    });

    test('模板与后缀新形态都在', () {
      expect(haikuoRuntimeHtml, contains('firstPage'));
      expect(haikuoRuntimeHtml, contains('JsonBody'));
      expect(haikuoRuntimeHtml, contains('fyAll'));
      expect(haikuoRuntimeHtml, contains('x5_webview_single'));
      expect(haikuoRuntimeHtml, contains('crypto-java.js'));
    });

    test('规则文件 md5 未变', () {
      final bytes = File(
        'assets/haikuo_builtin_rules.json',
      ).readAsBytesSync();
      expect(
        md5.convert(bytes).toString(),
        'a7dbf907b02142d261a930d2e51bb204',
      );
    });
  });
}
