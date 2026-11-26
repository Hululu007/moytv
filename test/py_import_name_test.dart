import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 全协议蜘蛛，自报名字与文件名故意不同：旧行为 ping 成功后登记名
/// 会被改成自报的「样例站」，新口径必须始终显示文件名。
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

ImportedSiteRecord _record(String id, String name, {String baseName = ''}) =>
    ImportedSiteRecord(
      id: id,
      name: name,
      type: ImportedSiteRecord.typePy,
      fileName: '$id.py',
      contentHash: 'hash-$id',
      baseName: baseName,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  const pyChannel = MethodChannel('moyi/pybridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('moyi_py_name_test');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(pyChannel, null);
    PyBridge.setTestProbe(null);
    PyBridge.clearTestStatus();
  });

  /// 让 py 桥「可用」：validate 回 ok，ping（call）回蜘蛛自报名。
  /// 旧代码在这种情况下会把登记名改成自报名，新代码不许改。
  void mockBridgeAlive() {
    PyBridge.setTestProbe(
      () async => const PyRuntimeStatus(available: true, python: '3.13'),
    );
    messenger.setMockMethodCallHandler(pyChannel, (call) async {
      if (call.method == 'validate') {
        return jsonEncode({
          'ok': true,
          'hasSpider': true,
          'missing': <String>[],
          'error': '',
        });
      }
      if (call.method == 'call') {
        return jsonEncode({
          'ok': true,
          'data': {'name': '样例站', 'filled': <String>[]},
        });
      }
      return null;
    });
  }

  Future<LocalStore> newStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(() async {
      await store.syncImportedSites(const []);
      store.dispose();
    });
    return store;
  }

  group('ImportCandidate.baseName 文件名口径', () {
    test('去后缀', () {
      expect(ImportCandidate(name: 'abc.py', bytes: const []).baseName, 'abc');
    });

    test('去路径（正斜杠与反斜杠）', () {
      expect(
        ImportCandidate(name: 'sub/dir/abc.py', bytes: const []).baseName,
        'abc',
      );
      expect(
        ImportCandidate(name: 'sub\\dir\\abc.py', bytes: const []).baseName,
        'abc',
      );
    });

    test('无后缀原样', () {
      expect(ImportCandidate(name: 'abc', bytes: const []).baseName, 'abc');
    });
  });

  group('renumberImportedSiteRecords 同名序号', () {
    test('单条不带号且原样返回', () {
      final records = [_record('py:a', 'abc', baseName: 'abc')];
      final out = renumberImportedSiteRecords(records);
      expect(identical(out, records), isTrue);
      expect(out.single.name, 'abc');
    });

    test('同名两条按顺序编号 1/2，基准名保留', () {
      final out = renumberImportedSiteRecords([
        _record('py:a', 'abc', baseName: 'abc'),
        _record('py:b', 'abc', baseName: 'abc'),
      ]);
      expect(out.map((r) => r.name).toList(), ['abc1', 'abc2']);
      expect(out.map((r) => r.baseName).toList(), ['abc', 'abc']);
    });

    test('同名三条编号 1/2/3，不同名不受影响', () {
      final out = renumberImportedSiteRecords([
        _record('py:a', 'abc', baseName: 'abc'),
        _record('py:b', 'xyz', baseName: 'xyz'),
        _record('py:c', 'abc', baseName: 'abc'),
        _record('py:d', 'abc', baseName: 'abc'),
      ]);
      expect(out.map((r) => r.name).toList(), ['abc1', 'xyz', 'abc2', 'abc3']);
    });

    test('删一条后重排：剩一条回原名', () {
      final numbered = renumberImportedSiteRecords([
        _record('py:a', 'abc', baseName: 'abc'),
        _record('py:b', 'abc', baseName: 'abc'),
      ]);
      final afterDelete = renumberImportedSiteRecords([numbered.first]);
      expect(afterDelete.single.name, 'abc');
    });

    test('删中间一条后其余重排成 1/2', () {
      final numbered = renumberImportedSiteRecords([
        _record('py:a', 'abc', baseName: 'abc'),
        _record('py:b', 'abc', baseName: 'abc'),
        _record('py:c', 'abc', baseName: 'abc'),
      ]);
      final afterDelete = renumberImportedSiteRecords([
        numbered[0],
        numbered[2],
      ]);
      expect(afterDelete.map((r) => r.name).toList(), ['abc1', 'abc2']);
    });

    test('旧记录无 baseName 时以 name 为基准、单条零扰动', () {
      final records = [_record('py:old', '蜘蛛自报名')];
      final out = renumberImportedSiteRecords(records);
      expect(identical(out, records), isTrue);
      expect(out.single.name, '蜘蛛自报名');
      expect(out.single.effectiveBaseName, '蜘蛛自报名');
    });

    test('baseName 经 toJson/fromJson 往返不丢', () {
      final record = _record('py:a', 'abc1', baseName: 'abc');
      final restored = ImportedSiteRecord.fromJson(record.toJson());
      expect(restored.baseName, 'abc');
      expect(restored.name, 'abc1');
    });
  });

  group('导入引擎：py 站名以文件名为准', () {
    test('ping 回蜘蛛自报名也不改登记名', () async {
      mockBridgeAlive();
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FixtureRepository(),
      );
      final report = await engine.importAll([
        ImportCandidate(name: 'mysite.py', bytes: utf8.encode(_fullSpider)),
      ]);
      expect(report.successCount, 1);
      expect(report.outcomes.single.siteName, 'mysite');
      expect(report.outcomes.single.reason, isNot(contains('蜘蛛名为')));
      final record = store.importedSiteRecords.single;
      expect(record.name, 'mysite');
      expect(record.baseName, 'mysite');
      final site = SourceSite.importedSites[record.id];
      expect(site, isNotNull);
      expect(site!.name, 'mysite');
    });

    test('带路径的候选名只登记文件名部分', () async {
      mockBridgeAlive();
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FixtureRepository(),
      );
      final report = await engine.importAll([
        ImportCandidate(
          name: 'pkg/inner/pathname.py',
          bytes: utf8.encode(_fullSpider),
        ),
      ]);
      expect(report.successCount, 1);
      expect(store.importedSiteRecords.single.name, 'pathname');
    });

    test('同名不同内容重复导入编号 1/2，删一个后重排回原名', () async {
      mockBridgeAlive();
      final store = await newStore();
      final engine = ImportEngine(
        store: store,
        repository: FixtureRepository(),
      );
      final variant = '# variant\n$_fullSpider';
      final first = await engine.importAll([
        ImportCandidate(name: 'dup.py', bytes: utf8.encode(_fullSpider)),
      ]);
      expect(first.successCount, 1);
      final second = await engine.importAll([
        ImportCandidate(name: 'dup.py', bytes: utf8.encode(variant)),
      ]);
      expect(second.successCount, 1);
      final records = store.importedSiteRecords;
      expect(records.length, 2);
      expect(records.map((r) => r.id).toSet().length, 2);
      expect(records.map((r) => r.name).toList(), ['dup1', 'dup2']);
      expect(
        SourceSite.importedSites[records[0].id]!.name,
        'dup1',
      );
      expect(
        SourceSite.importedSites[records[1].id]!.name,
        'dup2',
      );
      await store.syncImportedSites([records.first]);
      expect(store.importedSiteRecords.single.name, 'dup');
      expect(
        SourceSite.importedSites[store.importedSiteRecords.single.id]!.name,
        'dup',
      );
    });
  });
}
