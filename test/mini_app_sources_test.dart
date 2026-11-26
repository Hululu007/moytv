import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moyi/jar_bridge.dart';
import 'package:moyi/miniapp/mini_app_bridge.dart';
import 'package:moyi/miniapp/mini_app_manifest.dart';
import 'package:moyi/miniapp/mini_app_sources.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';

class _FakeSourceProvider implements MiniAppSourceProvider {
  final List<String> calls = [];
  Object? nextError;

  @override
  Future<List<Map<String, dynamic>>> listSites() async {
    calls.add('list');
    if (nextError != null) throw nextError!;
    return [
      <String, dynamic>{
        'key': 'k1',
        'name': '站一',
        'type': 'jar',
        'searchable': true,
        'available': true,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> home(String siteKey) async {
    calls.add('home:$siteKey');
    if (nextError != null) throw nextError!;
    return {'list': []};
  }

  @override
  Future<Map<String, dynamic>> category({
    required String siteKey,
    required String tid,
    required int page,
    Map<String, dynamic> ext = const {},
  }) async {
    calls.add('category:$siteKey:$tid:$page:$ext');
    if (nextError != null) throw nextError!;
    return {'list': []};
  }

  @override
  Future<Map<String, dynamic>> detail({
    required String siteKey,
    required String id,
  }) async {
    calls.add('detail:$siteKey:$id');
    if (nextError != null) throw nextError!;
    return {'list': []};
  }

  @override
  Future<Map<String, dynamic>> play({
    required String siteKey,
    required String flag,
    required String id,
  }) async {
    calls.add('play:$siteKey:$flag:$id');
    if (nextError != null) throw nextError!;
    return {'url': 'https://example.com/v.m3u8', 'header': {}};
  }

  @override
  Future<Map<String, dynamic>> search({
    required String siteKey,
    required String wd,
    required int page,
  }) async {
    calls.add('search:$siteKey:$wd:$page');
    if (nextError != null) throw nextError!;
    return {'list': []};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MiniAppBridge makeBridge(
    MiniAppManifest manifest,
    SharedPreferences prefs, {
    MiniAppSourceProvider? sourceProvider,
  }) {
    return MiniAppBridge(
      manifest: manifest,
      appDir: Directory.systemTemp,
      prefs: prefs,
      sourceProvider: sourceProvider,
      callbacks: MiniAppBridgeCallbacks(
        evaluateJavascript: (_) async {},
        showToast: (_) {},
        showLoading: (_) {},
        hideLoading: () {},
        confirm: ({required title, required content}) async => true,
        actionSheet: (_) async => 0,
        navigateTo: (_) async {},
        navigateBack: () async {},
        exit: () {},
        openMiniApp: (_) async {},
        resolveMiniAppUrl: (_) async => null,
        log: (_) {},
      ),
    );
  }

  group('MiniAppBridge source.* dispatch', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    const manifest = MiniAppManifest(
      appId: 'com.example.sources',
      name: 'Sources',
      permissions: ['source'],
    );

    test('routes all six source.* calls with contract params', () async {
      final fake = _FakeSourceProvider();
      final bridge = makeBridge(manifest, prefs, sourceProvider: fake);
      await bridge.invoke('source.list', {});
      await bridge.invoke('source.home', {'siteKey': 'jar:zakatv:abc'});
      await bridge.invoke('source.category', {
        'siteKey': 'jar:zakatv:abc',
        'tid': '7',
        'page': '2',
        'ext': {'area': '1'},
      });
      await bridge.invoke('source.detail', {
        'siteKey': 'py1',
        'id': 'vod9',
      });
      await bridge.invoke('source.play', {
        'siteKey': 'py1',
        'flag': '线路1',
        'id': 'ep1',
      });
      await bridge.invoke('source.search', {
        'siteKey': 'py1',
        'wd': '关键词',
        'page': 3,
      });
      expect(fake.calls, [
        'list',
        'home:jar:zakatv:abc',
        'category:jar:zakatv:abc:7:2:{area: 1}',
        'detail:py1:vod9',
        'play:py1:线路1:ep1',
        'search:py1:关键词:3',
      ]);
    });

    test('accepts common param aliases', () async {
      final fake = _FakeSourceProvider();
      final bridge = makeBridge(manifest, prefs, sourceProvider: fake);
      await bridge.invoke('source.category', {
        'siteKey': 's',
        'typeId': '9',
      });
      await bridge.invoke('source.detail', {'siteKey': 's', 'vodId': 'v1'});
      await bridge.invoke('source.play', {
        'siteKey': 's',
        'flag': 'f',
        'playId': 'p1',
      });
      await bridge.invoke('source.search', {'siteKey': 's', 'query': 'q'});
      expect(fake.calls, [
        'category:s:9:1:{}',
        'detail:s:v1',
        'play:s:f:p1',
        'search:s:q:1',
      ]);
    });

    test('denies source.* without the source permission', () async {
      const denied = MiniAppManifest(
        appId: 'com.example.noperm',
        name: 'NoPerm',
        permissions: ['storage'],
      );
      final bridge = makeBridge(
        denied,
        prefs,
        sourceProvider: _FakeSourceProvider(),
      );
      await expectLater(
        bridge.invoke('source.list', {}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'PERMISSION_DENIED',
          ),
        ),
      );
    });

    test('propagates host failure codes unchanged', () async {
      final fake = _FakeSourceProvider()
        ..nextError = const MiniAppSourceFailure(
          'SITE_NOT_FOUND',
          '未找到内置站点：nope',
        );
      final bridge = makeBridge(manifest, prefs, sourceProvider: fake);
      await expectLater(
        bridge.invoke('source.home', {'siteKey': 'nope'}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'SITE_NOT_FOUND',
          ),
        ),
      );
    });

    test('unknown source.* sub-api is UNKNOWN_API', () async {
      final bridge = makeBridge(
        manifest,
        prefs,
        sourceProvider: _FakeSourceProvider(),
      );
      await expectLater(
        bridge.invoke('source.bogus', {}),
        throwsA(
          isA<MiniAppApiException>().having(
            (e) => e.code,
            'code',
            'UNKNOWN_API',
          ),
        ),
      );
    });
  });

  group('HostMiniAppSourceProvider', () {
    late ZakatvBuiltinSite jarBuiltin;
    late ZakatvBuiltinSite jarUnregistered;
    late String jarSiteId;
    const standaloneJarSiteId = 'jar:standalone_test:demo';

    setUp(() {
      final video = zakatvBuiltinSites
          .where((site) => !site.audioOnly)
          .toList();
      jarBuiltin = video.first;
      jarUnregistered = video[1];
      jarSiteId = JarSiteSpec.siteIdFor(zakatvJarId, jarBuiltin.key);
      JarBridge.register(
        JarSiteSpec(
          siteId: jarSiteId,
          configId: zakatvJarId,
          name: jarBuiltin.name,
          className: jarBuiltin.className,
          jarUrl: '',
          jarMd5: zakatvJarMd5,
          ext: jarBuiltin.ext,
        ),
      );
      SourceSite.importedSites['test_py_builtin'] = const SourceSite(
        'test_py_builtin',
        '测试 py 站',
        '内置 py · test',
        origin: SourceSite.originBuiltin,
        importType: 'py',
      );
      SourceSite.importedPyFiles['test_py_builtin'] = 'test_py_builtin.py';
      SourceSite.importedSites['test_py_config'] = const SourceSite(
        'test_py_config',
        '配置 py 站',
        'Python 蜘蛛 · 来自配置',
        origin: SourceSite.originConfig,
        importType: 'py',
      );
      SourceSite.importedPyFiles['test_py_config'] = 'test_py_config.py';
      SourceSite.importedSites['test_py_import'] = const SourceSite(
        'test_py_import',
        '导入 py 站',
        'py 导入',
        origin: SourceSite.originImport,
        importType: 'py',
      );
      SourceSite.importedPyFiles['test_py_import'] = 'test_py_import.py';
      // ZakaTV jar 内置站经 JarImport 还会在注册表里留一条同 id 的
      // import/jar 登记（运行时真实形态），清单里必须去重。
      SourceSite.importedSites[jarSiteId] = SourceSite(
        jarSiteId,
        jarBuiltin.name,
        'ZakaTV jar 内置 · test',
        origin: SourceSite.originImport,
        importType: 'jar',
      );
      SourceSite.importedSites['test_jsonlist_import'] = const SourceSite(
        'test_jsonlist_import',
        '导入 jsonlist 站',
        'JSON 列表导入站',
        origin: SourceSite.originImport,
        importType: 'jsonlist',
      );
      SourceSite.importedPyFiles['test_jsonlist_import'] =
          'test_jsonlist_import.py';
      // 独立导入 jar 站：spec 进 jar 桥 + 注册表一条 import/jar。
      JarBridge.register(
        const JarSiteSpec(
          siteId: standaloneJarSiteId,
          configId: 'standalone_test',
          name: '独立导入 jar 站',
          className: 'csp_Demo',
          jarUrl: '',
          jarMd5: '',
          ext: '',
        ),
      );
      SourceSite.importedSites[standaloneJarSiteId] = const SourceSite(
        standaloneJarSiteId,
        '独立导入 jar 站',
        'jar 导入 · csp_Demo',
        origin: SourceSite.originImport,
        importType: 'jar',
      );
      // JS 蜘蛛与 idj 插件站：取数链不在本提供者，不进汇合集。
      SourceSite.importedSites['test_js_import'] = const SourceSite(
        'test_js_import',
        '导入 JS 站',
        'JS 蜘蛛导入站',
        origin: SourceSite.originImport,
        importType: 'js',
      );
      SourceSite.importedSites['idj_testplug'] = const SourceSite(
        'idj_testplug',
        '测试插件站',
        'idj 插件 · test',
        origin: SourceSite.originImport,
        importType: 'js',
        importExt: 'com.idj.ext.testplug',
      );
    });

    tearDown(() {
      JarBridge.unregister(jarSiteId);
      JarBridge.unregister(standaloneJarSiteId);
      SourceSite.importedSites.remove('test_py_builtin');
      SourceSite.importedSites.remove('test_py_config');
      SourceSite.importedSites.remove('test_py_import');
      SourceSite.importedSites.remove(jarSiteId);
      SourceSite.importedSites.remove('test_jsonlist_import');
      SourceSite.importedSites.remove(standaloneJarSiteId);
      SourceSite.importedSites.remove('test_js_import');
      SourceSite.importedSites.remove('idj_testplug');
      SourceSite.importedPyFiles.remove('test_py_builtin');
      SourceSite.importedPyFiles.remove('test_py_config');
      SourceSite.importedPyFiles.remove('test_py_import');
      SourceSite.importedPyFiles.remove('test_jsonlist_import');
    });

    test('list keeps the builtin segment intact and appends merged sites',
        () async {
      final provider = HostMiniAppSourceProvider();
      final sites = await provider.listSites();
      final jarCount =
          zakatvBuiltinSites.where((site) => !site.audioOnly).length +
          missav30BuiltinSites.where((site) => !site.audioOnly).length;
      bool isBuiltinJarKey(Object? key) =>
          (key as String).startsWith('jar:zakatv:') ||
          key.startsWith('jar:missav30:');
      final jarEntries = sites.where((e) => e['type'] == 'jar').toList();
      // 内置 jar 段条数不变，其后只多汇合进来的独立导入 jar 一条。
      expect(
        jarEntries.where((e) => isBuiltinJarKey(e['key'])).length,
        jarCount,
      );
      expect(jarEntries.length, jarCount + 1);
      for (final entry in jarEntries) {
        expect(entry['searchable'], isTrue);
        expect(entry['name'], isA<String>());
      }
      final registered = jarEntries.firstWhere(
        (e) => e['key'] == jarSiteId,
      );
      expect(registered['available'], isTrue);
      expect(
        jarEntries
            .where((e) => isBuiltinJarKey(e['key']) && e['key'] != jarSiteId)
            .every((e) => e['available'] == false),
        isTrue,
      );
      // JarImport 的同 id 重复登记被去重：全表 key 不重复，
      // jarSiteId 只出现一次且留在内置段位置（在汇合 jar 之前）。
      final keys = [for (final e in sites) e['key']];
      expect(keys.toSet().length, keys.length);
      expect(keys.where((k) => k == jarSiteId).length, 1);
      expect(
        keys.indexOf(jarSiteId) < keys.indexOf(standaloneJarSiteId),
        isTrue,
      );
      final mergedJar = jarEntries.firstWhere(
        (e) => e['key'] == standaloneJarSiteId,
      );
      expect(mergedJar['name'], '独立导入 jar 站');
      expect(mergedJar['available'], isTrue);

      // py 段：内置在前，汇合段按注册表顺序跟上（配置/导入/jsonlist）。
      final pyEntries = sites.where((e) => e['type'] == 'py').toList();
      expect(
        [for (final e in pyEntries) e['key']],
        [
          'test_py_builtin',
          'test_py_config',
          'test_py_import',
          'test_jsonlist_import',
        ],
      );
      expect(pyEntries.first['name'], '测试 py 站');
      expect(pyEntries.first['searchable'], isTrue);
      expect(pyEntries.first['available'], isTrue);
      expect(
        pyEntries.every((e) => e['available'] == true),
        isTrue,
      );
      // JS 蜘蛛与 idj 插件站不进清单。
      expect(keys.contains('test_js_import'), isFalse);
      expect(keys.contains('idj_testplug'), isFalse);
    });

    test('unknown keys and missing params fail with contract codes',
        () async {
      final provider = HostMiniAppSourceProvider();
      await expectLater(
        provider.home('no_such_site'),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SITE_NOT_FOUND',
          ),
        ),
      );
      await expectLater(
        provider.home(''),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'INVALID_PARAMS',
          ),
        ),
      );
      final unregisteredId = JarSiteSpec.siteIdFor(
        zakatvJarId,
        jarUnregistered.key,
      );
      await expectLater(
        provider.home(unregisteredId),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SITE_UNAVAILABLE',
          ),
        ),
      );
      await expectLater(
        provider.detail(siteKey: jarSiteId, id: ''),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'INVALID_PARAMS',
          ),
        ),
      );
      await expectLater(
        provider.search(siteKey: jarSiteId, wd: '', page: 1),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'INVALID_PARAMS',
          ),
        ),
      );
      // JS 蜘蛛与 idj 插件站不在本提供者的取数链上，仍报未找到。
      for (final key in ['test_js_import', 'idj_testplug']) {
        await expectLater(
          provider.home(key),
          throwsA(
            isA<MiniAppSourceFailure>().having(
              (e) => e.code,
              'code',
              'SITE_NOT_FOUND',
            ),
          ),
        );
      }
    });

    test('merged import and config sites resolve via the existing chains',
        () async {
      final pySeen = <String>[];
      final jarSeen = <String>[];
      final provider = HostMiniAppSourceProvider(
        pyCall: (source, request) async {
          pySeen.add('$source:${request['action']}');
          switch (request['action']) {
            case 'home':
              return {
                'list': [
                  {'vod_id': 'm1', 'vod_name': '汇合片'},
                ],
              };
            case 'resolve':
              return {'playUrl': 'https://cdn.example.com/m.m3u8'};
          }
          return {};
        },
        jarCall: (spec, method, args) async {
          jarSeen.add('${spec.siteId}:$method');
          return {
            'list': [
              {'vod_id': 'j1', 'vod_name': '导入 jar 片'},
            ],
          };
        },
      );

      // 导入 py、配置 py、jsonlist 导入站都走 py 桥现成动作。
      for (final key in [
        'test_py_import',
        'test_py_config',
        'test_jsonlist_import',
      ]) {
        final home = await provider.home(key);
        expect((home['list'] as List).length, 1, reason: key);
      }
      expect(pySeen, [
        'test_py_import:home',
        'test_py_config:home',
        'test_jsonlist_import:home',
      ]);
      final play = await provider.play(
        siteKey: 'test_py_import',
        flag: '默认',
        id: 'q1',
      );
      expect(play['url'], 'https://cdn.example.com/m.m3u8');

      // 独立导入 jar 站按完整 siteId 走 jar 桥，spec 就是注册那条。
      final jarHome = await provider.home(standaloneJarSiteId);
      expect((jarHome['list'] as List).length, 1);
      expect(jarSeen, ['$standaloneJarSiteId:homeContent']);
    });

    test('jar data calls use the host jar bridge methods', () async {
      final seen = <String>[];
      final provider = HostMiniAppSourceProvider(
        jarCall: (spec, method, args) async {
          seen.add('$method:${args['tid'] ?? args['key'] ?? ''}');
          switch (method) {
            case 'homeContent':
              return {
                'class': [
                  {'type_id': '1', 'type_name': '电影'},
                ],
                'list': [
                  {'vod_id': 'v1', 'vod_name': '片一'},
                ],
              };
            case 'homeVideoContent':
              return {'list': []};
            case 'categoryContent':
              return {
                'list': [
                  {'vod_id': 'v2', 'vod_name': '片二'},
                ],
                'page': 2,
                'pagecount': 5,
              };
            case 'detailContent':
              return {
                'list': [
                  {
                    'vod_id': 'v2',
                    'vod_play_from': '线路1',
                    'vod_play_url': '第1集\$p1',
                  },
                ],
              };
            case 'playerContent':
              return {
                'url': 'https://cdn.example.com/v.m3u8',
                'header': '{"Referer":"https://example.com/"}',
                'parse': 1,
              };
            case 'searchContent':
              return {
                'list': [
                  {'vod_id': 'v3', 'vod_name': '搜到的片'},
                ],
              };
          }
          return {};
        },
      );

      final home = await provider.home(jarSiteId);
      expect(home['classes'], home['class']);
      expect((home['list'] as List).length, 1);

      // 短 key 也认。
      final homeShort = await provider.home(jarBuiltin.key);
      expect((homeShort['list'] as List).length, 1);

      final category = await provider.category(
        siteKey: jarSiteId,
        tid: '1',
        page: 2,
        ext: {'area': '2'},
      );
      expect(category['page'], 2);
      expect(category['pagecount'], 5);

      // 空分类先走 homeVideoContent，空列表再回落到 homeContent。
      final emptyCategory = await provider.category(
        siteKey: jarSiteId,
        tid: '',
        page: 1,
      );
      expect((emptyCategory['list'] as List).length, 1);

      final detail = await provider.detail(siteKey: jarSiteId, id: 'v2');
      expect(detail['vod_id'], 'v2');
      expect(detail['vod_play_from'], ['线路1']);
      expect(detail['vod_play_url'], ['第1集\$p1']);

      final play = await provider.play(
        siteKey: jarSiteId,
        flag: '线路1',
        id: 'p1',
      );
      expect(play['url'], 'https://cdn.example.com/v.m3u8');
      expect(play['header'], {'Referer': 'https://example.com/'});
      expect(play['parse'], '1');
      expect(play.containsKey('jx'), isFalse);

      final search = await provider.search(
        siteKey: jarSiteId,
        wd: '关键词',
        page: 1,
      );
      expect((search['list'] as List).length, 1);
      expect(seen, contains('categoryContent:1'));
      expect(seen, contains('searchContent:关键词'));
    });

    test('py data calls use the host py actions', () async {
      final seen = <Map<String, dynamic>>[];
      final provider = HostMiniAppSourceProvider(
        pyCall: (source, request) async {
          seen.add({'source': source, ...request});
          switch (request['action']) {
            case 'home':
              return {
                'class': [
                  {'type_id': '2', 'type_name': '剧集'},
                ],
                'list': [
                  {'vod_id': 'a1', 'vod_name': '剧一'},
                ],
              };
            case 'catalog':
              return {
                'list': [
                  {'vod_id': 'a2', 'vod_name': '剧二'},
                ],
                'page': 1,
                'pagecount': 1,
              };
            case 'detail':
              return {
                'list': [
                  {
                    'vod_id': 'a2',
                    'vod_play_from': '默认',
                    'vod_play_url': '正片\$q1',
                  },
                ],
              };
            case 'resolve':
              return {
                'playUrl': 'https://cdn.example.com/a.m3u8',
                'header': {'User-Agent': 'ua'},
                'jx': '0',
              };
          }
          return {};
        },
      );

      final home = await provider.home('test_py_builtin');
      expect(home['classes'], home['class']);
      final category = await provider.category(
        siteKey: 'test_py_builtin',
        tid: '2',
        page: 1,
      );
      expect((category['list'] as List).length, 1);
      final detail = await provider.detail(
        siteKey: 'test_py_builtin',
        id: 'a2',
      );
      expect(detail['vod_id'], 'a2');
      expect(detail['vod_play_from'], ['默认']);
      expect(detail['vod_play_url'], ['正片\$q1']);
      final play = await provider.play(
        siteKey: 'test_py_builtin',
        flag: '默认',
        id: 'q1',
      );
      expect(play['url'], 'https://cdn.example.com/a.m3u8');
      expect(play['jx'], '0');
      final search = await provider.search(
        siteKey: 'test_py_builtin',
        wd: '剧',
        page: 1,
      );
      expect((search['list'] as List).length, 1);

      expect(seen.map((e) => e['action']).toList(), [
        'home',
        'catalog',
        'detail',
        'resolve',
        'catalog',
      ]);
      expect(seen[1]['category'], '2');
      expect(seen[3]['flag'], '默认');
      expect(seen[3]['playId'], 'q1');
      expect(seen[4]['query'], '剧');
    });

    test('detail unwraps the vod and splits multi-line play fields', () async {
      final provider = HostMiniAppSourceProvider(
        jarCall: (_, method, _) async {
          if (method == 'detailContent') {
            return {
              'list': [
                {
                  'vod_id': 'v9',
                  'vod_name': '片九',
                  'vod_pic': 'https://example.com/p.jpg',
                  'vod_play_from': '线路1\$\$\$线路2',
                  'vod_play_url': '第1集\$a1#第2集\$a2\$\$\$正片\$b1',
                },
              ],
            };
          }
          return {};
        },
      );
      final detail = await provider.detail(siteKey: jarSiteId, id: 'v9');
      expect(detail['vod_id'], 'v9');
      expect(detail['vod_name'], '片九');
      expect(detail['vod_pic'], 'https://example.com/p.jpg');
      expect(detail['vod_play_from'], ['线路1', '线路2']);
      expect(detail['vod_play_url'], ['第1集\$a1#第2集\$a2', '正片\$b1']);
      expect(detail.containsKey('list'), isFalse);
    });

    test('detail with an empty list returns an empty map', () async {
      final provider = HostMiniAppSourceProvider(
        jarCall: (_, _, _) async => {'list': []},
      );
      final detail = await provider.detail(siteKey: jarSiteId, id: 'v0');
      expect(detail, isEmpty);
    });

    test('detail keeps array play fields and tolerates missing ones', () async {
      final provider = HostMiniAppSourceProvider(
        pyCall: (_, _) async => {
          'list': [
            {
              'vod_id': 'a9',
              'vod_play_from': ['线路A', '线路B'],
              'vod_play_url': ['第1集\$x', ''],
            },
          ],
        },
      );
      final detail = await provider.detail(
        siteKey: 'test_py_builtin',
        id: 'a9',
      );
      expect(detail['vod_play_from'], ['线路A', '线路B']);
      expect(detail['vod_play_url'], ['第1集\$x', '']);

      final missing = HostMiniAppSourceProvider(
        pyCall: (_, _) async => {
          'list': [
            {'vod_id': 'a0', 'vod_name': '无线路片'},
          ],
        },
      );
      final noLines = await missing.detail(
        siteKey: 'test_py_builtin',
        id: 'a0',
      );
      expect(noLines['vod_id'], 'a0');
      expect(noLines['vod_play_from'], isEmpty);
      expect(noLines['vod_play_url'], isEmpty);
    });

    test('spider errors become SOURCE_FAILED', () async {
      final provider = HostMiniAppSourceProvider(
        jarCall: (_, _, _) async => throw StateError('boom'),
      );
      await expectLater(
        provider.home(jarSiteId),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SOURCE_FAILED',
          ),
        ),
      );
    });

    test('fourth concurrent call is rejected', () async {
      final gate = Completer<void>();
      var calls = 0;
      final provider = HostMiniAppSourceProvider(
        jarCall: (_, _, _) async {
          calls++;
          await gate.future;
          return {'list': []};
        },
      );
      final first = provider.home(jarSiteId);
      final second = provider.home(jarSiteId);
      final third = provider.home(jarSiteId);
      await expectLater(
        provider.home(jarSiteId),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'TOO_MANY_REQUESTS',
          ),
        ),
      );
      gate.complete();
      await Future.wait([first, second, third]);
      expect(calls, 3);
    });

    test('slow calls time out with TIMEOUT', () async {
      final provider = HostMiniAppSourceProvider(
        jarCall: (_, _, _) => Completer<Map<String, dynamic>>().future,
        callTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        provider.home(jarSiteId),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'TIMEOUT',
          ),
        ),
      );
    });

    test('proxyImageUrl builds a decodable pyproxy payload', () {
      const proxyPic =
          'proxy://do=py&siteKey=test_py_builtin&u=https%3A%2F%2Fcdn.example.com%2Fcover.jpg';
      final url = HostMiniAppSourceProvider.proxyImageUrl(
        'http://127.0.0.1:18080',
        'test_py_builtin',
        proxyPic,
      );
      expect(url, startsWith('http://127.0.0.1:18080/pyproxy?d='));
      final uri = Uri.parse(url);
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(uri.queryParameters['d']!)))
              as Map<String, dynamic>;
      expect(payload['source'], 'test_py_builtin');
      expect(payload['param'], {
        'do': 'py',
        'siteKey': 'test_py_builtin',
        'u': 'https://cdn.example.com/cover.jpg',
      });
    });

    test('proxyParam without key=value pairs falls back to url', () {
      expect(
        HostMiniAppSourceProvider.proxyParam('https://x.example.com/a.jpg'),
        {'url': 'https://x.example.com/a.jpg'},
      );
      expect(
        HostMiniAppSourceProvider.proxyParam('u=https%3A%2F%2Fx%2Fa.jpg'),
        {'u': 'https://x/a.jpg'},
      );
    });

    test('py home/category/detail/search rewrite proxy pics only', () async {
      const proxyPic =
          'proxy://do=py&siteKey=test_py_builtin&u=https%3A%2F%2Fcdn.example.com%2Fcover.jpg';
      const httpPic = 'https://cdn.example.com/plain.jpg';
      Map<String, dynamic> vod(String id, String pic) => {
        'vod_id': id,
        'vod_name': '片$id',
        'vod_pic': pic,
      };
      var capturedHome = <String, dynamic>{};
      final provider = HostMiniAppSourceProvider(
        imageBaseUrl: 'http://127.0.0.1:18080',
        pyCall: (source, request) async {
          switch (request['action']) {
            case 'home':
              capturedHome = {
                'class': [
                  {'type_id': '2', 'type_name': '剧集'},
                ],
                'list': [vod('a1', proxyPic), vod('a2', httpPic)],
              };
              return capturedHome;
            case 'catalog':
              if ((request['query'] as String? ?? '').isNotEmpty) {
                return {
                  'list': [vod('a3', proxyPic)],
                };
              }
              return {
                'list': [vod('a4', proxyPic), vod('a5', httpPic)],
              };
            case 'detail':
              return {
                'list': [
                  {
                    ...vod('a6', proxyPic),
                    'vod_play_from': '默认',
                    'vod_play_url': '正片\$q1',
                  },
                ],
              };
          }
          return {};
        },
      );

      final home = await provider.home('test_py_builtin');
      final homeList = home['list'] as List;
      expect(
        (homeList[0] as Map)['vod_pic'],
        HostMiniAppSourceProvider.proxyImageUrl(
          'http://127.0.0.1:18080',
          'test_py_builtin',
          proxyPic,
        ),
      );
      expect((homeList[1] as Map)['vod_pic'], httpPic);
      // 改写不污染蜘蛛原始返回。
      expect(
        ((capturedHome['list'] as List)[0] as Map)['vod_pic'],
        proxyPic,
      );

      final category = await provider.category(
        siteKey: 'test_py_builtin',
        tid: '2',
        page: 1,
      );
      final categoryList = category['list'] as List;
      expect(
        ((categoryList[0] as Map)['vod_pic'] as String),
        startsWith('http://127.0.0.1:18080/pyproxy?d='),
      );
      expect((categoryList[1] as Map)['vod_pic'], httpPic);

      final detail = await provider.detail(
        siteKey: 'test_py_builtin',
        id: 'a6',
      );
      expect(
        (detail['vod_pic'] as String),
        startsWith('http://127.0.0.1:18080/pyproxy?d='),
      );
      expect(detail['vod_play_from'], ['默认']);
      expect(detail['vod_play_url'], ['正片\$q1']);

      final search = await provider.search(
        siteKey: 'test_py_builtin',
        wd: '剧',
        page: 1,
      );
      expect(
        (((search['list'] as List)[0] as Map)['vod_pic'] as String),
        startsWith('http://127.0.0.1:18080/pyproxy?d='),
      );
    });

    test('no rewrite without imageBaseUrl, jar pics untouched', () async {
      const proxyPic = 'proxy://do=py&siteKey=x&u=https%3A%2F%2Fx%2Fa.jpg';
      final noBase = HostMiniAppSourceProvider(
        pyCall: (_, _) async => {
          'list': [
            {'vod_id': 'a1', 'vod_pic': proxyPic},
          ],
        },
      );
      final home = await noBase.home('test_py_builtin');
      expect(((home['list'] as List)[0] as Map)['vod_pic'], proxyPic);

      final jarProvider = HostMiniAppSourceProvider(
        imageBaseUrl: 'http://127.0.0.1:18080',
        jarCall: (_, _, _) async => {
          'list': [
            {'vod_id': 'v1', 'vod_pic': proxyPic},
          ],
        },
      );
      final jarHome = await jarProvider.home(jarSiteId);
      expect(((jarHome['list'] as List)[0] as Map)['vod_pic'], proxyPic);
    });

    test('rewrite tolerates missing, empty and non-map pics', () {
      final rewritten = HostMiniAppSourceProvider.rewriteProxyImages(
        {
          'list': [
            {'vod_id': 'a1'},
            {'vod_id': 'a2', 'vod_pic': ''},
            {'vod_id': 'a3', 'vod_pic': 42},
            'not-a-map',
            {'vod_id': 'a4', 'vod_pic': 'proxy://u=https%3A%2F%2Fx%2Fa.jpg'},
          ],
        },
        baseUrl: 'http://127.0.0.1:18080',
        source: 'test_py_builtin',
      );
      final list = rewritten['list'] as List;
      expect((list[0] as Map).containsKey('vod_pic'), isFalse);
      expect((list[1] as Map)['vod_pic'], '');
      expect((list[2] as Map)['vod_pic'], 42);
      expect(list[3], 'not-a-map');
      expect(
        ((list[4] as Map)['vod_pic'] as String),
        startsWith('http://127.0.0.1:18080/pyproxy?d='),
      );
    });

    test('proxyFetch calls the proxy action for py sites of any origin',
        () async {
      final seen = <Map<String, dynamic>>[];
      final provider = HostMiniAppSourceProvider(
        pyCall: (source, request) async {
          seen.add({'source': source, ...request});
          return {
            'status': 200,
            'mime': 'image/jpeg',
            'bodyBase64': 'aGVsbG8=',
            'headers': {},
          };
        },
      );
      final result = await provider.proxyFetch('test_py_builtin', {
        'u': 'https://cdn.example.com/cover.jpg',
      });
      expect(result['status'], 200);
      expect(result['mime'], 'image/jpeg');
      expect(seen.length, 1);
      expect(seen[0]['action'], 'proxy');
      expect(seen[0]['param'], {'u': 'https://cdn.example.com/cover.jpg'});

      // 汇合口径：导入/配置/jsonlist 的 py 站同样放行。
      for (final key in [
        'test_py_import',
        'test_py_config',
        'test_jsonlist_import',
      ]) {
        final merged = await provider.proxyFetch(key, {
          'u': 'https://x/a.jpg',
        });
        expect(merged['status'], 200, reason: key);
      }
      expect(seen.length, 4);
      expect(seen[3]['source'], 'test_jsonlist_import');

      // 非 py 站与未知站仍报未找到，且不触发蜘蛛调用。
      for (final key in ['test_js_import', 'no_such_site']) {
        await expectLater(
          provider.proxyFetch(key, {'u': 'https://x/a.jpg'}),
          throwsA(
            isA<MiniAppSourceFailure>().having(
              (e) => e.code,
              'code',
              'SITE_NOT_FOUND',
            ),
          ),
        );
      }
      expect(seen.length, 4);
    });

    test('native segment lists js and idj sites when the chain is injected',
        () async {
      SourceSite.importedJsFiles['test_js_import'] = 'test_js_import.js';
      addTearDown(() => SourceSite.importedJsFiles.remove('test_js_import'));
      final provider = HostMiniAppSourceProvider(
        nativeCall: (source, operation,
            {category = '', page = 1, query = '', vodId = '', flag = '',
            playId = ''}) async =>
            {},
      );
      final sites = await provider.listSites();
      final keys = [for (final e in sites) e['key']];
      expect(keys.toSet().length, keys.length);
      final js = sites.firstWhere((e) => e['key'] == 'test_js_import');
      expect(js['type'], 'js');
      expect(js['name'], '导入 JS 站');
      expect(js['searchable'], isTrue);
      expect(js['available'], isTrue);
      final idj = sites.firstWhere((e) => e['key'] == 'idj_testplug');
      expect(idj['type'], 'idj');
      expect(idj['name'], '测试插件站');
      expect(idj['searchable'], isTrue);
      expect(idj['available'], isTrue);
      // 原生段在汇合段之后：排在最后一个 py 条目之后。
      expect(
        keys.indexOf('test_js_import') > keys.indexOf('test_jsonlist_import'),
        isTrue,
      );
      expect(
        keys.indexOf('idj_testplug') > keys.indexOf('test_jsonlist_import'),
        isTrue,
      );
    });

    test('js sites route through the native call with spider operations',
        () async {
      final seen = <String>[];
      final provider = HostMiniAppSourceProvider(
        nativeCall: (source, operation,
            {category = '', page = 1, query = '', vodId = '', flag = '',
            playId = ''}) async {
          seen.add(
            '$operation|cat=$category|pg=$page|q=$query|id=$vodId'
            '|flag=$flag|play=$playId',
          );
          switch (operation) {
            case 'home':
              return {
                'class': [
                  {'type_id': '1', 'type_name': '电影'},
                ],
                'list': [
                  {'vod_id': 'j1', 'vod_name': 'JS 片'},
                ],
              };
            case 'category':
              return {
                'list': [
                  {'vod_id': 'j2', 'vod_name': 'JS 分类片'},
                ],
              };
            case 'search':
              return {
                'list': [
                  {'vod_id': 'j3', 'vod_name': 'JS 搜片'},
                ],
              };
            case 'detail':
              return {
                'list': [
                  {
                    'vod_id': 'j1',
                    'vod_play_from': '线路A',
                    'vod_play_url': '第1集\$e1',
                  },
                ],
              };
            case 'player':
              return {
                'url': 'https://cdn.example.com/js.m3u8',
                'header': {'Referer': 'https://example.com/'},
                'parse': 0,
              };
          }
          return {};
        },
      );

      final home = await provider.home('test_js_import');
      expect((home['list'] as List).length, 1);
      expect((home['classes'] as List).length, 1);
      final category = await provider.category(
        siteKey: 'test_js_import',
        tid: '1',
        page: 2,
      );
      expect((category['list'] as List).length, 1);
      final search = await provider.search(
        siteKey: 'test_js_import',
        wd: '词',
        page: 1,
      );
      expect((search['list'] as List).length, 1);
      final detail = await provider.detail(
        siteKey: 'test_js_import',
        id: 'j1',
      );
      expect(detail['vod_id'], 'j1');
      expect(detail['vod_play_from'], ['线路A']);
      expect(detail['vod_play_url'], ['第1集\$e1']);
      final play = await provider.play(
        siteKey: 'test_js_import',
        flag: '线路A',
        id: 'e1',
      );
      expect(play['url'], 'https://cdn.example.com/js.m3u8');
      expect(play['header'], {'Referer': 'https://example.com/'});
      expect(play['parse'], '0');
      expect(seen, [
        'home|cat=|pg=1|q=|id=|flag=|play=',
        'category|cat=1|pg=2|q=|id=|flag=|play=',
        'search|cat=|pg=1|q=词|id=|flag=|play=',
        'detail|cat=|pg=1|q=|id=j1|flag=|play=',
        'player|cat=|pg=1|q=|id=|flag=线路A|play=e1',
      ]);
    });

    test('idj sites translate the idj1 shapes', () async {
      final seen = <String>[];
      final provider = HostMiniAppSourceProvider(
        nativeCall: (source, operation,
            {category = '', page = 1, query = '', vodId = '', flag = '',
            playId = ''}) async {
          seen.add('$operation|cat=$category|pg=$page|q=$query|id=$vodId');
          switch (operation) {
            case 'home':
              return {
                'categories': [
                  {'id': 'movie', 'name': '电影'},
                  {'id': '', 'name': '坏行'},
                  {'id': 'tv'},
                ],
                'items': [
                  {
                    'id': 'a1',
                    'title': '插件片',
                    'cover': 'https://img.example.com/a1.jpg',
                    'remarks': '12集',
                    'duration': '45分钟',
                  },
                  {
                    'id': 'a2',
                    'title': '插件片二',
                    'cover': '',
                    'duration': '30分钟',
                  },
                ],
                'hasMore': true,
              };
            case 'category':
              return {
                'items': [
                  {'id': 'a3', 'title': '分类片', 'cover': ''},
                ],
                'hasMore': false,
              };
            case 'search':
              return {
                'items': [
                  {'id': 'a4', 'title': '搜到的插件片', 'cover': ''},
                ],
                'hasMore': false,
              };
            case 'detail':
              return {
                'id': 'a1',
                'title': '插件片',
                'cover': 'https://img.example.com/a1.jpg',
                'desc': '简介',
                'tags': ['动作', ''],
                'lines': [
                  {
                    'name': '线路一',
                    'episodes': [
                      {'id': 'e1', 'name': '第1集'},
                      {'id': 'e2'},
                    ],
                  },
                  {'name': '空线路', 'episodes': []},
                ],
              };
          }
          return {};
        },
      );

      final home = await provider.home('idj_testplug');
      expect(home['class'], [
        {'type_id': '', 'type_name': '全部'},
        {'type_id': 'movie', 'type_name': '电影'},
        {'type_id': 'tv', 'type_name': 'tv'},
      ]);
      expect(home['classes'], home['class']);
      final homeList = home['list'] as List;
      expect(homeList.length, 2);
      expect((homeList[0] as Map)['vod_remarks'], '12集');
      expect((homeList[1] as Map)['vod_remarks'], '30分钟');
      expect(home['hasMore'], isTrue);

      // 空分类不调 category：改走 home 取首页内容，只取第一页。
      final homeCategory = await provider.category(
        siteKey: 'idj_testplug',
        tid: '',
        page: 1,
      );
      expect((homeCategory['list'] as List).length, 2);
      final beyond = await provider.category(
        siteKey: 'idj_testplug',
        tid: '',
        page: 2,
      );
      expect(beyond['list'], isEmpty);
      final category = await provider.category(
        siteKey: 'idj_testplug',
        tid: 'movie',
        page: 1,
      );
      expect((category['list'] as List).length, 1);
      expect(category['hasMore'], isFalse);
      final search = await provider.search(
        siteKey: 'idj_testplug',
        wd: '插件',
        page: 1,
      );
      expect((search['list'] as List).length, 1);

      final detail = await provider.detail(siteKey: 'idj_testplug', id: 'a1');
      expect(detail['vod_id'], 'a1');
      expect(detail['vod_name'], '插件片');
      expect(detail['vod_content'], '简介');
      expect(detail['vod_class'], '动作');
      expect(detail['vod_play_from'], ['线路一']);
      expect(detail['vod_play_url'], ['第1集\$e1#e2\$e2']);

      // category 只被以非空 tid 调过一次；空 tid 两页都没触发新调用。
      expect(seen, [
        'home|cat=|pg=1|q=|id=',
        'home|cat=|pg=1|q=|id=',
        'category|cat=movie|pg=1|q=|id=',
        'search|cat=|pg=1|q=插件|id=',
        'detail|cat=|pg=1|q=|id=a1',
      ]);
    });

    test('idj play goes through the plan call and maps the plan', () async {
      final seen = <String>[];
      var drm = false;
      final provider = HostMiniAppSourceProvider(
        nativeCall: (source, operation,
            {category = '', page = 1, query = '', vodId = '', flag = '',
            playId = ''}) async =>
            {},
        idjPlanCall: (source, {required flag, required playId}) async {
          seen.add('$source:$flag:$playId');
          return PlaybackPlan(
            url: 'https://cdn.example.com/p.m3u8',
            headers: const {'User-Agent': 'UA'},
            drm: drm ? const PlaybackDrm(type: 'widevine', key: 'k') : null,
          );
        },
      );
      final play = await provider.play(
        siteKey: 'idj_testplug',
        flag: '线路一',
        id: 'e1',
      );
      expect(play['url'], 'https://cdn.example.com/p.m3u8');
      expect(play['header'], {'User-Agent': 'UA'});
      expect(play['parse'], '0');
      expect(seen, ['idj_testplug:线路一:e1']);

      // DRM 计划不回裸地址冒充可播，如实报失败。
      drm = true;
      await expectLater(
        provider.play(siteKey: 'idj_testplug', flag: '线路一', id: 'e1'),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SOURCE_FAILED',
          ),
        ),
      );
    });

    test('native chain errors become SOURCE_FAILED and proxy stays closed',
        () async {
      final provider = HostMiniAppSourceProvider(
        nativeCall: (source, operation,
            {category = '', page = 1, query = '', vodId = '', flag = '',
            playId = ''}) async =>
            throw StateError('核调用炸了'),
      );
      await expectLater(
        provider.home('test_js_import'),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SOURCE_FAILED',
          ),
        ),
      );
      // proxyFetch 不接 JS/idj：主链没有这两类的取图代理路径。
      for (final key in ['test_js_import', 'idj_testplug']) {
        await expectLater(
          provider.proxyFetch(key, {'u': 'https://x/a.jpg'}),
          throwsA(
            isA<MiniAppSourceFailure>().having(
              (e) => e.code,
              'code',
              'SITE_NOT_FOUND',
            ),
          ),
        );
      }
    });
  });

  group('play result normalization', () {
    test('url wins, playUrl is the fallback', () {
      final direct = HostMiniAppSourceProvider.normalizePlayResult({
        'url': 'https://a.example.com/v.mp4',
        'playUrl': 'https://b.example.com/v.mp4',
      });
      expect(direct['url'], 'https://a.example.com/v.mp4');
      final fallback = HostMiniAppSourceProvider.normalizePlayResult({
        'playUrl': 'https://b.example.com/v.mp4',
      });
      expect(fallback['url'], 'https://b.example.com/v.mp4');
    });

    test('empty url fails with SOURCE_FAILED', () {
      expect(
        () => HostMiniAppSourceProvider.normalizePlayResult({'url': ''}),
        throwsA(
          isA<MiniAppSourceFailure>().having(
            (e) => e.code,
            'code',
            'SOURCE_FAILED',
          ),
        ),
      );
    });

    test('headers accept map, json string and pair list', () {
      expect(
        HostMiniAppSourceProvider.normalizeHeaders({'A': '1', 'B': 2}),
        {'A': '1', 'B': '2'},
      );
      expect(
        HostMiniAppSourceProvider.normalizeHeaders('{"A":"1"}'),
        {'A': '1'},
      );
      expect(
        HostMiniAppSourceProvider.normalizeHeaders([
          ['A', '1'],
          {'key': 'B', 'value': '2'},
        ]),
        {'A': '1', 'B': '2'},
      );
      expect(HostMiniAppSourceProvider.normalizeHeaders(null), {});
      expect(HostMiniAppSourceProvider.normalizeHeaders('not json'), {});
    });

    test('parse and jx normalize to 1/0 strings, absent stays absent', () {
      final withFlags = HostMiniAppSourceProvider.normalizePlayResult({
        'url': 'https://a.example.com/v.mp4',
        'parse': 1,
        'jx': false,
      });
      expect(withFlags['parse'], '1');
      expect(withFlags['jx'], '0');
      final truthy = HostMiniAppSourceProvider.normalizePlayResult({
        'url': 'https://a.example.com/v.mp4',
        'parse': 'true',
      });
      expect(truthy['parse'], '1');
      expect(truthy.containsKey('jx'), isFalse);
    });

    test('解析线路字段 playUrl/jxFrom/key/flag 有则原样带上，无则不编', () {
      final parsed = HostMiniAppSourceProvider.normalizePlayResult({
        'url': 'https://site.example.com/play/123',
        'parse': 1,
        'playUrl': 'https://jx.example.com/?url=x',
        'jxFrom': '解析源A',
        'key': 'k1',
        'flag': '线路1',
      });
      expect(parsed['playUrl'], 'https://jx.example.com/?url=x');
      expect(parsed['jxFrom'], '解析源A');
      expect(parsed['key'], 'k1');
      expect(parsed['flag'], '线路1');
      final direct = HostMiniAppSourceProvider.normalizePlayResult({
        'url': 'https://a.example.com/v.mp4',
      });
      expect(direct.containsKey('playUrl'), isFalse);
      expect(direct.containsKey('jxFrom'), isFalse);
      expect(direct.containsKey('key'), isFalse);
      expect(direct.containsKey('flag'), isFalse);
    });

    test('classes alias mirrors class without overwriting', () {
      final aliased = HostMiniAppSourceProvider.withClassesAlias({
        'class': [
          {'type_id': '1'},
        ],
        'list': [],
      });
      expect(aliased['classes'], aliased['class']);
      final kept = HostMiniAppSourceProvider.withClassesAlias({
        'class': [
          {'type_id': '1'},
        ],
        'classes': [
          {'type_id': '9'},
        ],
      });
      expect((kept['classes'] as List).first['type_id'], '9');
      final none = HostMiniAppSourceProvider.withClassesAlias({'list': []});
      expect(none.containsKey('classes'), isFalse);
    });
  });
}
