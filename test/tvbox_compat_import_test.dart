import 'dart:convert';

import 'package:moyi/import_center.dart';
import 'package:moyi/live_sources.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_parse.dart';
import 'package:moyi/tvbox_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class FakeCompatRepository extends FixtureRepository {
  final added = <CustomSourceSite>[];
  var _sequence = 0;

  @override
  Future<List<CustomSourceSite>> customSources() async => List.of(added);

  @override
  Future<CustomSourceSite> addCustomSource({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    final site = CustomSourceSite(
      id: 'custom:${_sequence++}',
      name: name,
      base: base,
      rule: rule,
      kind: kind,
    );
    added.add(site);
    return site;
  }

  @override
  Future<Map<String, dynamic>> importCustomSources(String content) async =>
      {'added': <dynamic>[], 'updated': <dynamic>[], 'failed': <dynamic>[]};
}

Future<LocalStore> newCompatStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(() async {
    await store.syncImportedSites(const []);
    store.dispose();
  });
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('dotted class-name api registers as jar with the verbatim class name',
      () async {
    const config = '''
{
  "spider": {"url": "https://x.test/spider.jar", "md5": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  "sites": [
    {"key": "yt", "name": "YouTube", "api": "com.github.catvod.spider.YouTube"}
  ]
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-classname-test');
    expect(report.jarSites, 1);
    final stored = TvBoxConfigStore.configFor(report.configId)!;
    final site = stored.sites.single;
    expect(site.kind, 'jar');
    expect(site.className, 'com.github.catvod.spider.YouTube');
    expect(site.jarUrl, 'https://x.test/spider.jar');
    expect(site.jarMd5, 'a' * 32);
  });

  test('spider as [url, md5] list works for csp_ sites', () async {
    const config = '''
{
  "spider": ["https://x.test/spider.jar", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
  "sites": [
    {"key": "demo", "name": "演示", "api": "csp_Demo"}
  ]
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-spider-list-test');
    expect(report.jarSites, 1);
    final stored = TvBoxConfigStore.configFor(report.configId)!;
    expect(stored.sites.single.className, 'com.github.catvod.spider.Demo');
    expect(stored.sites.single.jarMd5, 'b' * 32);
  });

  test('remote .js api registers a lazily-loaded js site', () async {
    const config = '''
{
  "sites": [
    {"key": "alist", "name": "Alist", "type": 3, "api": "https://cdn.example.test/alist.js"}
  ]
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-remote-js-test');
    expect(report.jsSites, 1);
    expect(report.summary, contains('JS 1'));
    final stored = TvBoxConfigStore.configFor(report.configId)!;
    final site = stored.sites.single;
    expect(site.kind, 'js');
    expect(site.remoteUrl, 'https://cdn.example.test/alist.js');
    final registered = SourceSite.importedSites[site.coreId];
    expect(registered, isNotNull);
    expect(registered!.importType, 'js');
    expect(
      SourceSite.importedJsRemoteUrls[site.coreId],
      'https://cdn.example.test/alist.js',
    );
  });

  test('string type "t4" imports as a t4 custom source', () async {
    const config = '''
{
  "sites": [
    {"key": "t4s", "name": "T4 字符串", "type": "t4", "api": "https://t4.example.test/vod"}
  ]
}
''';
    final repository = FakeCompatRepository();
    final report = await TvBoxImporter(
      repository,
    ).importFromText(config, sourceIdentity: 'compat-string-t4-test');
    expect(report.t4Sites, 1);
    expect(repository.added.single.kind, 't4');
  });

  test('type 1 parses are accepted with headers; type 2/3 are skipped',
      () async {
    const config = '''
{
  "sites": [
    {"key": "a", "name": "A 站", "type": 1, "api": "https://a.example.test/vod/"}
  ],
  "parses": [
    {"name": "普通解析", "type": 0, "url": "https://jx0.example.test/?url="},
    {"name": "JSON 解析", "type": 1, "url": "https://jx1.example.test/?url=", "header": {"User-Agent": "UA1"}},
    {"name": "并发解析", "type": 2, "url": "https://jx2.example.test/?url="},
    {"name": "聚合解析", "type": 3, "url": "https://jx3.example.test/?url="}
  ]
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-parses-test');
    expect(report.parses, 2);
    expect(report.notes.any((note) => note.contains('并发解析')), isTrue);
    expect(report.notes.any((note) => note.contains('聚合解析')), isTrue);
    final stored = await ParseInterfaceStore.load();
    final jsonApi = stored.firstWhere((item) => item.name == 'JSON 解析');
    expect(jsonApi.jsonApi, isTrue);
    expect(jsonApi.headers['User-Agent'], 'UA1');
    final webApi = stored.firstWhere((item) => item.name == '普通解析');
    expect(webApi.jsonApi, isFalse);
  });

  test('singular parse key is accepted', () async {
    const config = '''
{
  "sites": [
    {"key": "a", "name": "A 站", "type": 1, "api": "https://a.example.test/vod/"}
  ],
  "parse": {"name": "单条解析", "type": 0, "url": "https://jx.example.test/?url="}
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-singular-parse-test');
    expect(report.parses, 1);
  });

  test('lives carry epg/group and accept singular live + array url',
      () async {
    const config = '''
{
  "sites": [
    {"key": "a", "name": "A 站", "type": 1, "api": "https://a.example.test/vod/"}
  ],
  "lives": [
    {"name": "央视", "url": "https://live.example.test/tv.m3u", "epg": "https://epg.example.test/epg.xml", "group": "央视"}
  ],
  "live": {"name": "单条直播", "url": ["/local.m3u", "https://live.example.test/one.m3u"]}
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-lives-test');
    expect(report.lives, 1);
    final stored = TvBoxConfigStore.configFor(report.configId)!;
    expect(stored.lives.single.epg, 'https://epg.example.test/epg.xml');
    expect(stored.lives.single.group, '央视');
    final liveSource = LiveSource.importedValues.firstWhere(
      (source) => source.id == stored.lives.single.id,
    );
    expect(liveSource.epg, 'https://epg.example.test/epg.xml');
    expect(liveSource.group, '央视');
  });

  test('singular live object alone is imported, array url resolved',
      () async {
    const config = '''
{
  "live": {"name": "单条直播", "url": ["/local.m3u", "https://live.example.test/one.m3u"]}
}
''';
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(config, sourceIdentity: 'compat-singular-live-test');
    expect(report.lives, 1);
    final stored = TvBoxConfigStore.configFor(report.configId)!;
    expect(stored.lives.single.url, 'https://live.example.test/one.m3u');
  });

  test('base64-wrapped config imports', () async {
    const json = '''
{
  "name": "base64 配置",
  "sites": [
    {"key": "a", "name": "A 站", "type": 1, "api": "https://a.example.test/vod/"}
  ]
}
''';
    final encoded = base64Encode(utf8.encode(json));
    final parsed = TvBoxConfigParser.parse(encoded);
    expect(parsed['name'], 'base64 配置');
    final report = await TvBoxImporter(
      FakeCompatRepository(),
    ).importFromText(encoded, sourceIdentity: 'compat-base64-test');
    expect(report.apiSites, 1);
    expect(report.name, 'base64 配置');
  });

  test('import center rejects drpy declarative rules with guidance',
      () async {
    final store = await newCompatStore();
    final engine = ImportEngine(
      store: store,
      repository: FakeCompatRepository(),
    );
    const rule = '''
var rule = {
  title: "示例",
  host: "https://example.test",
  url: "/fyclass/fypage.html",
  一级: "body&&.item",
  二级: "*",
  搜索: "body&&.item",
};
''';
    final result = await engine.importAll([
      ImportCandidate(name: 'drpy_rule.js', bytes: utf8.encode(rule)),
    ]);
    expect(result.failedCount, 1);
    expect(result.outcomes.single.reason, contains('drpy'));
    expect(result.outcomes.single.reason, contains('drpy-node'));
  });

  test('import center accepts a lives-only json via the tvbox route',
      () async {
    final store = await newCompatStore();
    final engine = ImportEngine(
      store: store,
      repository: FakeCompatRepository(),
    );
    final result = await engine.importAll([
      ImportCandidate(
        name: 'lives.json',
        bytes: utf8.encode(
          jsonEncode({
            'lives': [
              {
                'name': '央视',
                'url': 'https://live.example.test/tv.m3u',
              },
            ],
          }),
        ),
      ),
    ]);
    expect(result.successCount, 1);
    expect(result.outcomes.single.reason, contains('直播 1 个'));
  });
}
