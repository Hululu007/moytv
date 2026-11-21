// 导入 JSON 列表站名修复（2026-11-21 用户报“导入的 json 还是老
// 问题没有站点名称”）：以前 ping 不带 ext，蜘蛛名回落成通用名
// “JSON List”又把登记名覆盖掉；修后 ping 带 ext、通用名不再
// 覆盖登记名；老导入启动时读盘重算一次站名写回。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/json_list_import.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<LocalStore> _makeStore(List<ImportedSiteRecord> records) async {
  SharedPreferences.setMockInitialValues({
    'importedSites': jsonEncode(
      records.map((r) => r.toJson()).toList(),
    ),
  });
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<String> _writeJsonList(Directory dir) async {
  final file = File('${dir.path}/list.json');
  // 导入时规范化后的存盘形态：顶层对象 + list 键（裸数组不算
  // 视频列表，解析会返回 0 条）。
  await file.writeAsString(jsonEncode({
    'list': [
      {
        'vod_id': '1',
        'vod_name': '测试一',
        'vod_play_from': '测试站',
        'vod_play_url': 'http://x/1.m3u8',
      },
      {
        'vod_id': '2',
        'vod_name': '测试二',
        'vod_play_from': '测试站',
        'vod_play_url': 'http://x/2.m3u8',
      },
    ],
  }));
  return file.path;
}

void main() {
  group('repairImportedJsonListNames', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jsonlist_name_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('通用名“JSON List”的老导入读盘重算出站名并写回', () async {
      final path = await _writeJsonList(tmp);
      final store = await _makeStore([
        ImportedSiteRecord(
          id: 'jsonlist_test',
          name: 'JSON List',
          type: ImportedSiteRecord.typeJsonList,
          fileName: 'jsonlist_test.py',
          contentHash: 'x',
          ext: jsonListExtFor(path: path, name: 'JSON List'),
        ),
      ]);
      await store.repairImportedJsonListNames();
      final record = store.importedSiteRecords.single;
      expect(record.name, '测试站');
      expect(jsonListPathFromExt(record.ext), path);
      expect(record.ext.contains('测试站'), isTrue);
    });

    test('名字已经正常的站不动，文件没了的站不动', () async {
      final path = await _writeJsonList(tmp);
      final store = await _makeStore([
        ImportedSiteRecord(
          id: 'jsonlist_good',
          name: '测试站',
          type: ImportedSiteRecord.typeJsonList,
          fileName: 'jsonlist_good.py',
          contentHash: 'y',
          ext: jsonListExtFor(path: path, name: '测试站'),
        ),
        ImportedSiteRecord(
          id: 'jsonlist_gone',
          name: 'JSON List',
          type: ImportedSiteRecord.typeJsonList,
          fileName: 'jsonlist_gone.py',
          contentHash: 'z',
          ext: jsonListExtFor(
            path: '${tmp.path}/no_such_file.json',
            name: 'JSON List',
          ),
        ),
      ]);
      await store.repairImportedJsonListNames();
      final records = store.importedSiteRecords;
      expect(records[0].name, '测试站');
      expect(records[1].name, 'JSON List');
    });
  });
}
