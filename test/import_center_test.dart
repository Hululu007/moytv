import 'dart:convert';
import 'dart:io';

import 'package:moyi/import_center.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_contract.dart';
import 'package:moyi/py_spider_validator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _fullSpider = '''
class Spider:
    def getName(self): return "样例站"
    def getDependence(self): return []
    def init(self, extend=""): return None
    def destroy(self): return None
    def homeContent(self, filter=None): return {}
    def homeVideoContent(self): return {}
    def categoryContent(self, tid=None, pg=1, filter=None, extend=None): return {}
    def detailContent(self, ids=None): return {}
    def searchContent(self, key=None, quick=False, pg="1"): return {}
    def playerContent(self, flag=None, id=None, vipFlags=None): return {}
    def localProxy(self, param=None): return []
    def isVideoFormat(self, url=None): return False
    def manualVideoCheck(self): return False
    def action(self, action=None): return {}
''';

class FakeImportRepository extends FixtureRepository {
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
  Future<Map<String, dynamic>> importCustomSources(String content) async => {
    'added': const [],
    'updated': const [],
    'skipped': const [],
    'failed': const ['未接受'],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('huoyi_import_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  Future<LocalStore> newStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(() async {
      await store.syncImportedSites(const []);
      store.dispose();
    });
    return store;
  }

  group('py 静态校验', () {
    test('全协议蜘蛛通过', () {
      final result = validatePySource(_fullSpider);
      expect(result.ok, isTrue);
      expect(result.missing, isEmpty);
    });

    test('缺方法逐个列出', () {
      final broken = _fullSpider.replaceAll(
        'def playerContent(self, flag=None, id=None, vipFlags=None): return {}',
        '',
      );
      final result = validatePySource(broken);
      expect(result.ok, isFalse);
      expect(result.missing, contains('playerContent'));
      expect(result.message, contains('playerContent'));
    });

    test('无 Spider 类失败', () {
      final result = validatePySource('x = 1\n');
      expect(result.ok, isFalse);
      expect(result.hasSpider, isFalse);
    });

    test('缺 destroy/action 等缺省方法放行并注明补齐', () {
      var relaxed = _fullSpider;
      for (final line in [
        '    def getDependence(self): return []\n',
        '    def destroy(self): return None\n',
        '    def localProxy(self, param=None): return []\n',
        '    def isVideoFormat(self, url=None): return False\n',
        '    def manualVideoCheck(self): return False\n',
        '    def action(self, action=None): return {}\n',
      ]) {
        relaxed = relaxed.replaceAll(line, '');
      }
      final result = validatePySource(relaxed);
      expect(result.ok, isTrue, reason: result.message);
      expect(result.missing, isEmpty);
      expect(result.filled, containsAll(['destroy', 'action']));
      expect(result.filled.length, 6);
      expect(result.filledNote, contains('已自动补齐缺省方法 6/6'));
    });

    test('仅留 playerContent 按仅播放放行', () {
      var loose = _fullSpider;
      for (final line in [
        '    def getName(self): return "样例站"\n',
        '    def getDependence(self): return []\n',
        '    def init(self, extend=""): return None\n',
        '    def destroy(self): return None\n',
        '    def homeContent(self, filter=None): return {}\n',
        '    def homeVideoContent(self): return {}\n',
        '    def categoryContent(self, tid=None, pg=1, filter=None, extend=None): return {}\n',
        '    def detailContent(self, ids=None): return {}\n',
        '    def searchContent(self, key=None, quick=False, pg="1"): return {}\n',
        '    def localProxy(self, param=None): return []\n',
        '    def isVideoFormat(self, url=None): return False\n',
        '    def manualVideoCheck(self): return False\n',
        '    def action(self, action=None): return {}\n',
      ]) {
        loose = loose.replaceAll(line, '');
      }
      final result = validatePySource(loose);
      expect(result.ok, isTrue, reason: result.message);
      expect(result.playOnly, isTrue);
      expect(result.missing, isEmpty);
      expect(result.filled, containsAll(['homeContent', 'detailContent']));
      expect(result.filled, isNot(contains('playerContent')));
    });

    test('缺核心方法 playerContent 仍拒绝', () {
      final broken = _fullSpider.replaceAll(
        'def playerContent(self, flag=None, id=None, vipFlags=None): return {}',
        '',
      );
      final result = validatePySource(broken);
      expect(result.ok, isFalse);
      expect(result.missing, contains('playerContent'));
      expect(result.message, contains('缺少核心方法'));
    });
  });

  group('py 契约映射', () {
    test('列表文件夹与视频卡', () {
      final folder = PyContract.itemToDrama('py:x', {
        'vod_id': 'actress:abc',
        'vod_name': '某女优',
        'vod_pic': 'https://img.test/a.jpg',
        'vod_remarks': '12 视频',
        'vod_tag': 'folder',
      });
      expect(folder.isFolder, isTrue);
      expect(folder.folderId, 'actress:abc');
      expect(folder.sourceId, 'actress:abc');
      final video = PyContract.itemToDrama('py:x', {
        'vod_id': '9',
        'vod_name': '片名',
        'vod_remarks': '1:02:03',
      });
      expect(video.isFolder, isFalse);
      expect(video.id, 'py:x:9');
    });

    test('分类与分页', () {
      final categories = PyContract.categoriesFromHome({
        'class': [
          {'type_id': 'movie', 'type_name': '电影'},
        ],
      });
      expect(categories.length, 2);
      expect(categories[1].id, 'movie');
      final page = PyContract.pageFromResult('py:x', {
        'list': [
          {'vod_id': '1', 'vod_name': '一'},
        ],
        'page': 1,
        'pagecount': 3,
      });
      expect(page.hasMore, isTrue);
      expect(page.items.single.title, '一');
    });

    test('详情多线路集数解析', () {
      const base = Drama(
        id: 'py:x:42',
        source: 'py:x',
        sourceId: '42',
        title: '旧',
      );
      final detail = PyContract.detailFromResult('py:x', base, {
        'list': [
          {
            'vod_id': '42',
            'vod_name': '详情片',
            'vod_pic': 'https://img.test/d.jpg',
            'vod_content': '简介',
            'vod_play_from': '线路A\$\$\$线路B',
            'vod_play_url':
                '第1集\$https://p.test/1.m3u8#第2集\$https://p.test/2.m3u8\$\$\$正片\$https://p.test/main.mp4',
          },
        ],
      });
      expect(detail.episodes.length, 3);
      expect(detail.episodes[0].raw['flag'], '线路A');
      expect(detail.episodes[0].raw['id'], 'https://p.test/1.m3u8');
      expect(detail.episodes[0].title, '第1集');
      expect(detail.episodes[2].raw['flag'], '线路B');
      expect(detail.drama.episodes, 3);
    });

    test('播放计划与解析标记', () {
      final plan = PyContract.planFromResult({
        'url': 'https://p.test/a.m3u8',
        'header': {'User-Agent': 'UA', 'Referer': 'https://s.test/'},
        'parse': 0,
      });
      expect(plan.url, 'https://p.test/a.m3u8');
      expect(plan.headers['Referer'], 'https://s.test/');
      expect(plan.needsParse, isFalse);
      final parsed = PyContract.planFromResult({'url': 'x', 'jx': 1});
      expect(parsed.needsParse, isTrue);
    });
  });

  group('导入引擎分流与去重', () {
    test('py 成站、重复跳过、缺方法失败', () async {
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FakeImportRepository(),
      );
      final bytes = utf8.encode(_fullSpider);
      final first = await engine.importAll([
        ImportCandidate(name: 'sample.py', bytes: bytes),
      ]);
      expect(first.successCount, 1);
      expect(store.importedSiteRecords.single.type, ImportedSiteRecord.typePy);
      final site =
          SourceSite.importedSites[store.importedSiteRecords.single.id];
      expect(site, isNotNull);
      expect(site!.origin, SourceSite.originImport);
      expect(site.importType, 'py');
      expect(SourceSite.importedPyFiles[site.id], isNotEmpty);

      final second = await engine.importAll([
        ImportCandidate(name: 'copy.py', bytes: bytes),
      ]);
      expect(second.duplicateCount, 1);
      expect(second.outcomes.single.reason, contains('完全相同'));

      final broken = await engine.importAll([
        ImportCandidate(
          name: 'bad.py',
          bytes: utf8.encode(
            'class Spider:\n    def getName(self): return 1\n',
          ),
        ),
      ]);
      expect(broken.failedCount, 1);
      expect(broken.outcomes.single.reason, contains('playerContent'));
    });

    test('js 注册与无法识别', () async {
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FakeImportRepository(),
      );
      final ok = await engine.importAll([
        ImportCandidate(
          name: 'drpy.js',
          bytes: utf8.encode('var rule = { homeContent: function(){} }'),
        ),
      ]);
      expect(ok.successCount, 1);
      expect(store.importedSiteRecords.single.type, ImportedSiteRecord.typeJs);
      final bad = await engine.importAll([
        ImportCandidate(name: 'plain.js', bytes: utf8.encode('1 + 1')),
      ]);
      expect(bad.failedCount, 1);
    });

    test('json 三路分流', () async {
      final store = await newStore();
      final repository = FakeImportRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final xbpq = await engine.importAll([
        ImportCandidate(
          name: 'rule.json',
          bytes: utf8.encode(
            jsonEncode({
              '站名': '规则站',
              '主页url': 'https://rule.test/',
              '分类url': 'https://rule.test/list/{cateId}-{catePg}.html',
              '数组': 'a&&a',
              '标题': 't',
            }),
          ),
        ),
      ]);
      expect(xbpq.successCount, 1);
      expect(repository.added.single.name, '规则站');
      expect(repository.added.single.hasRule, isTrue);

      final tvbox = await engine.importAll([
        ImportCandidate(
          name: 'config.json',
          bytes: utf8.encode(
            jsonEncode({'spider': 'https://x.test/a.jar', 'sites': []}),
          ),
        ),
      ]);
      expect(tvbox.failedCount, 1);
      expect(tvbox.outcomes.single.reason, contains('未注册任何站点'));

      final unknown = await engine.importAll([
        ImportCandidate(name: 'misc.json', bytes: utf8.encode('{"a":1}')),
      ]);
      expect(unknown.failedCount, 1);
      expect(unknown.outcomes.single.reason, contains('无法识别的 JSON'));
    });

    test('jar 识别与桥接失败口径', () async {
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FakeImportRepository(),
      );
      final badMagic = await engine.importAll([
        ImportCandidate(name: 'fake.jar', bytes: utf8.encode('not a jar')),
      ]);
      expect(badMagic.failedCount, 1);
      expect(badMagic.outcomes.single.reason, contains('zip'));
      final real = await engine.importAll([
        ImportCandidate(
          name: 'spider.jar',
          bytes: const [0x50, 0x4B, 0x03, 0x04],
        ),
      ]);
      expect(real.failedCount, 1);
      expect(real.outcomes.single.reason, contains('jar 桥仅支持 Android'));
    });

    test('停用与恢复注册表', () async {
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FakeImportRepository(),
      );
      await engine.importAll([
        ImportCandidate(name: 'sample.py', bytes: utf8.encode(_fullSpider)),
      ]);
      final record = store.importedSiteRecords.single;
      expect(SourceSite.isAvailable(record.id), isTrue);
      await store.syncImportedSites([record.copyWith(enabled: false)]);
      expect(SourceSite.importedSites.containsKey(record.id), isFalse);
      expect(store.importedSiteRecords.single.enabled, isFalse);
      await store.syncImportedSites([
        store.importedSiteRecords.single.copyWith(enabled: true),
      ]);
      expect(SourceSite.importedSites.containsKey(record.id), isTrue);
    });
  });
}
