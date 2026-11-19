// JSON 导入测试：TVBox 视频列表 JSON（list + vod_play_url 拼串）。
//
// 夹具在 test/fixtures/json_list/：av.json / live.json 是用户原文件
// 全文；big_trimmed.json 等取原文件前 6 条；damaged.json 是按 hsck
// 10 号文件损坏形态合成的（64 个 NUL + 原始 0x81 非法字节）。
// 真 10 文件全量断言只在 ~/workspace/user/files/ 存在时跑
// （本机有、CI 没有），不存在时跳过不报错。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/import_file_store.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/json_list_import.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_contract.dart';
import 'package:moyi/py_spider_validator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _fixtureDir = 'test/fixtures/json_list';
const _userFilesDir = '/home/hatch/workspace/user/files';

Future<List<int>> _readFixture(String name) async =>
    File('$_fixtureDir/$name').readAsBytes();

bool get _realFilesPresent =>
    Directory(_userFilesDir).existsSync() &&
    File('$_userFilesDir/_____2_sl9n.json').existsSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_json_list_test');
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

  group('容错解析', () {
    test('AV 单条 332 频道：条数 1、站名 AV、成人', () async {
      final bytes = await _readFixture('av.json');
      final result = parseJsonListBytes(bytes);
      expect(result.items.length, 1);
      expect(result.skipped, 0);
      expect(result.damaged, isFalse);
      expect(jsonListDisplayName(result.items, 'AV_4_ijwi.json'), '🔞AV');
    });

    test('直播单条 502 频道：站名 直播、非成人', () async {
      final bytes = await _readFixture('live.json');
      final result = parseJsonListBytes(bytes);
      expect(result.items.length, 1);
      expect(jsonListDisplayName(result.items, '___3_lr34.json'), '直播');
    });

    test('hsck 裁剪件：站名带分类后缀消歧义', () async {
      final cases = {
        'hsck5_trimmed.json': '🔞hsck·动漫剧情',
        'hsck6_trimmed.json': '🔞hsck·国产视频',
        'hsck9_trimmed.json': '🔞hsck·日本无码',
      };
      for (final entry in cases.entries) {
        final bytes = await _readFixture(entry.key);
        final result = parseJsonListBytes(bytes);
        expect(result.items.length, 6);
        expect(jsonListDisplayName(result.items, entry.key), entry.value);
      }
    });

    test('58MB 裁剪件（带 parse/jx 键）：仍认作视频列表', () async {
      final bytes = await _readFixture('big_trimmed.json');
      final result = parseJsonListBytes(bytes);
      expect(result.items.length, 6);
      // 裁剪件前 6 条全是国产新片，单分类加后缀消歧义；
      // 58MB 全文件有 8 个分类，站名是不带后缀的 🔞hsck（真文件用例断言）。
      expect(jsonListDisplayName(result.items, '_____2_sl9n.json'), '🔞hsck·国产新片');
      expect(looksLikeVideoListJson(jsonDecode(utf8.decode(bytes))), isTrue);
    });

    test('损坏文件：找回 5 条、跳过 1 条、标 damaged', () async {
      final bytes = await _readFixture('damaged.json');
      // 严格 UTF-8 本来就解不出（原始 0x81 非法字节）。
      expect(() => utf8.decode(bytes), throwsA(isA<FormatException>()));
      final result = parseJsonListBytes(bytes);
      expect(result.items.length, 5);
      expect(result.skipped, 1);
      expect(result.damaged, isTrue);
      expect(jsonListDisplayName(result.items, 'damaged.json'), '🔞hsck·动漫剧情');
    });

    test('空列表与非列表 JSON 不认作视频列表', () async {
      final empty = await _readFixture('empty_list.json');
      expect(parseJsonListBytes(empty).items, isEmpty);
      final unknown = await _readFixture('unknown.json');
      expect(looksLikeVideoListJson(jsonDecode(utf8.decode(unknown))), isFalse);
      final config = await _readFixture('tvbox_config.json');
      expect(looksLikeVideoListJson(jsonDecode(utf8.decode(config))), isFalse);
    });

    test('站名回落：无站名无线路时，乱码文件名不用，改叫 JSON列表', () {
      final items = [
        {
          'vod_id': 'x1',
          'vod_play_url': '正片\$http://example.com/a.m3u8',
        },
      ];
      expect(deriveStationName(items, '_____2_sl9n.json'), 'JSON列表');
    });
  });

  group('拼串拆集与播放', () {
    test('AV 详情拆出 332 集，首集名 1、线路 直播', () async {
      final bytes = await _readFixture('av.json');
      final result = parseJsonListBytes(bytes);
      final row = result.items.first;
      final drama = Drama(
        id: 'jsonlist:test:${row['vod_id']}',
        source: 'jsonlist:test',
        sourceId: '${row['vod_id']}',
        title: '${row['vod_name']}',
      );
      final detail = PyContract.detailFromResult('jsonlist:test', drama, {
        'list': [row],
      });
      expect(detail.episodes.length, 332);
      expect(detail.episodes.first.title, '1');
      expect(detail.episodes.first.raw['flag'], '直播');
      expect(detail.episodes.first.id, contains('askzycdn.com'));
    });

    test('直播详情拆出 502 集，首集名 CCTV-1综合', () async {
      final bytes = await _readFixture('live.json');
      final result = parseJsonListBytes(bytes);
      final row = result.items.first;
      final drama = Drama(
        id: 'jsonlist:test:${row['vod_id']}',
        source: 'jsonlist:test',
        sourceId: '${row['vod_id']}',
        title: '${row['vod_name']}',
      );
      final detail = PyContract.detailFromResult('jsonlist:test', drama, {
        'list': [row],
      });
      expect(detail.episodes.length, 502);
      expect(detail.episodes.first.title, 'CCTV-1综合');
    });

    test('单集 hsck 详情拆出 1 集正片', () async {
      final bytes = await _readFixture('hsck5_trimmed.json');
      final result = parseJsonListBytes(bytes);
      final row = result.items.first;
      final drama = Drama(
        id: 'jsonlist:test:${row['vod_id']}',
        source: 'jsonlist:test',
        sourceId: '${row['vod_id']}',
        title: '${row['vod_name']}',
      );
      final detail = PyContract.detailFromResult('jsonlist:test', drama, {
        'list': [row],
      });
      expect(detail.episodes.length, 1);
      expect(detail.episodes.first.title, '正片');
    });

    test('取流 parse=0 直链，不走壳解析', () {
      final plan = PyContract.planFromResult({
        'parse': 0,
        'jx': 0,
        'url': 'https://t0.97img.com/a1001966/a.m3u8',
        'header': {},
      });
      expect(plan.needsParse, isFalse);
      expect(plan.url, 'https://t0.97img.com/a1001966/a.m3u8');
    });
  });

  group('蜘蛛模板', () {
    test('14 方法全齐、过 validatePySource、零中文注释', () {
      const methods = [
        'getName',
        'init',
        'homeContent',
        'homeVideoContent',
        'categoryContent',
        'detailContent',
        'searchContent',
        'playerContent',
        'getDependence',
        'destroy',
        'localProxy',
        'isVideoFormat',
        'manualVideoCheck',
        'action',
      ];
      final source = buildJsonListSpiderSource();
      for (final method in methods) {
        expect(source, contains('def $method('), reason: '缺方法 $method');
      }
      expect(validatePySource(source).ok, isTrue);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(source), isFalse);
    });

    test('ext 编解码往返', () {
      const path = '/data/imported_spiders/jsonlist_hsck.json';
      final ext = jsonListExtFor(path: path, name: '🔞hsck');
      expect(jsonListPathFromExt(ext), path);
      expect(jsonListPathFromExt(''), isEmpty);
    });
  });

  group('导入引擎', () {
    test('导入 AV：注册 jsonlist 站、存盘两文件、进 py 登记', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('av.json');
      final report = await engine.importAll([
        ImportCandidate(name: 'AV_4_ijwi.json', bytes: bytes),
      ]);
      expect(report.successCount, 1);
      final outcome = report.outcomes.single;
      expect(outcome.siteName, '🔞AV');
      expect(outcome.siteId, startsWith('jsonlist:'));
      final records = store.importedSiteRecords;
      expect(records.length, 1);
      final record = records.single;
      expect(record.type, ImportedSiteRecord.typeJsonList);
      expect(record.ext, contains('jsonlist_'));
      final spiderPath = await ImportFileStore.pathOf(record.fileName);
      expect(File(spiderPath).existsSync(), isTrue);
      expect(
        File(spiderPath).readAsStringSync(),
        contains('class Spider(BaseSpider)'),
      );
      final jsonPath = jsonListPathFromExt(record.ext);
      expect(File(jsonPath).existsSync(), isTrue);
      expect(SourceSite.importedPyFiles[record.id], record.fileName);
      expect(SourceSite.importedSites[record.id]?.importType, 'jsonlist');
      expect(
        SourceSite.importedSites[record.id]?.name,
        '🔞AV',
      );
    });

    test('同一文件重复导入按内容哈希认出，不注册两份', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('av.json');
      final first = await engine.importAll([
        ImportCandidate(name: 'AV_4_ijwi.json', bytes: bytes),
      ]);
      expect(first.successCount, 1);
      final second = await engine.importAll([
        ImportCandidate(name: 'AV_4_ijwi.json', bytes: bytes),
      ]);
      expect(second.duplicateCount, 1);
      expect(store.importedSiteRecords.length, 1);
    });

    test('损坏文件导入成功：存盘的是干净 JSON，只含完好条目', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('damaged.json');
      final report = await engine.importAll([
        ImportCandidate(name: 'damaged.json', bytes: bytes),
      ]);
      expect(report.successCount, 1);
      expect(report.outcomes.single.reason, contains('跳过损坏条目 1 条'));
      final record = store.importedSiteRecords.single;
      final stored = jsonDecode(
        File(jsonListPathFromExt(record.ext)).readAsStringSync(),
      );
      expect((stored['list'] as List).length, 5);
    });

    test('带 parse/jx 键的视频列表不进 TVBox 配置分支', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('big_trimmed.json');
      final report = await engine.importAll([
        ImportCandidate(name: '_____2_sl9n.json', bytes: bytes),
      ]);
      expect(report.successCount, 1);
      // 裁剪件前 6 条全是国产新片，单分类加后缀消歧义（全文件则是不带后缀的 🔞hsck）。
      expect(report.outcomes.single.siteName, '🔞hsck·国产新片');
      expect(store.importedSiteRecords.single.type, 'jsonlist');
    });

    test('无法识别的 JSON 报清原因、不注册', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('unknown.json');
      final report = await engine.importAll([
        ImportCandidate(name: 'unknown.json', bytes: bytes),
      ]);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, contains('无法识别的 JSON'));
      expect(store.importedSiteRecords, isEmpty);
    });

    test('空列表报清 0 条、不注册', () async {
      final store = await newStore();
      final repository = FixtureRepository();
      final engine = ImportEngine(store: store, repository: repository);
      final bytes = await _readFixture('empty_list.json');
      final report = await engine.importAll([
        ImportCandidate(name: 'empty_list.json', bytes: bytes),
      ]);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, contains('没有可播的条目'));
      expect(store.importedSiteRecords, isEmpty);
    });
  });

  group('真 10 文件全量（仅本机）', () {
    test(
      '逐文件条数与站名',
      () async {
        const cases = {
          '_____2_sl9n.json': (76714, '🔞hsck'),
          '___3_lr34.json': (1, '直播'),
          'AV_4_ijwi.json': (1, '🔞AV'),
          'hsck______5_wi0f.json': (237, '🔞hsck·动漫剧情'),
          'hsck______6_3eqx.json': (32627, '🔞hsck·国产视频'),
          'hsck______7_kw61.json': (2177, '🔞hsck·国产新片'),
          'hsck______8_ebgd.json': (1397, '🔞hsck·欧美高清'),
          'hsck______9_fddr.json': (4332, '🔞hsck·日本无码'),
          'hsck______10_vuju.json': (4615, '🔞hsck·日本有码'),
          'hsck________11_kh4o.json': (3718, '🔞hsck·无码中文字幕'),
        };
        for (final entry in cases.entries) {
          final bytes = await File(
            '$_userFilesDir/${entry.key}',
          ).readAsBytes();
          final result = await parseJsonListBytesAsync(bytes);
          expect(
            result.items.length,
            entry.value.$1,
            reason: entry.key,
          );
          expect(
            jsonListDisplayName(result.items, entry.key),
            entry.value.$2,
            reason: entry.key,
          );
        }
        // 10 号损坏文件：找回 4615、跳过 1。
        final damaged = await File(
          '$_userFilesDir/hsck______10_vuju.json',
        ).readAsBytes();
        final parsed = await parseJsonListBytesAsync(damaged);
        expect(parsed.skipped, 1);
        expect(parsed.damaged, isTrue);
        // 0 号与 9 号同一文件：内容哈希一致。
        final nine = await File(
          '$_userFilesDir/hsck______9_fddr.json',
        ).readAsBytes();
        final zero = await File(
          '$_userFilesDir/hsck______0_6adq.json',
        ).readAsBytes();
        expect(contentHashOf(nine), contentHashOf(zero));
      },
      skip: !_realFilesPresent
          ? '真文件只在本机 ~/workspace/user/files/ 有'
          : false,
    );
  });
}
