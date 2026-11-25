// 本地 JSON 兜底链回归（2026-11-25 核查）：MYTV 里放 mjv011.json 时
// bindLocalDirs -> load -> 详情合并这条链必须通。.sql-only 批删的是
// .db 老路、没误伤这条链，本文件钉住结论。注意口径：JSON 条目只经
// 详情合并与站点筛选进显示，从不直接进人物列表（人物列表只读
// 工作库，新旧一致）——第三段断言钉的是这个边界，不是缺陷。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Map<String, dynamic> _row({
  required String vodId,
  required String code,
  required String actor,
}) => {
  'vod_id': vodId,
  'vod_name': code,
  'vod_pic': 'https://example.test/cover.jpg',
  'vod_actor': actor,
  'vod_director': '',
  'vod_remarks': '高清',
  'vod_pubdate': '2026-01-01',
  'vod_area': '日本',
  'vod_year': '2026',
  'vod_content': '',
  'vod_play_from': 'mjv011',
  'vod_play_url': '正片\$https://example.test/$code.m3u8',
  'type_name': '有码',
  'vod_code': code,
  'vod_actress_pic': '',
};

Directory _writeJson(Directory temp) {
  final dir = Directory('${temp.path}/actress_json')
    ..createSync(recursive: true);
  File('${dir.path}/mjv011.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'list': [
        _row(vodId: 'mjv-1', code: 'SSIS-001', actor: '测试女优甲'),
        _row(vodId: 'mjv-2', code: 'SSIS-002', actor: '测试女优甲'),
        _row(vodId: 'mjv-3', code: 'SSIS-003', actor: '仅JSON女优'),
      ],
      'parse': 0,
      'jx': 0,
      'last_update': '2026-11-20T00:00:00',
    }),
  );
  return dir;
}

void main() {
  test('bindLocalDirs + load: local mjv011.json entries are queryable',
      () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final dir = _writeJson(temp);
    // Production wiring: page creates the fallback bare, then binds
    // the MYTV json dir once the bind resolves.
    final fallback = ActressJsonFallback();
    fallback.bindLocalDirs(jsonDir: dir);
    await fallback.load();
    expect(fallback.loaded, isTrue);
    expect(fallback.entriesForActress('测试女优甲'), hasLength(2));
    expect(fallback.entriesForCode('SSIS-001'), hasLength(1));
    expect(fallback.entriesForActress('仅JSON女优'), hasLength(1));
    expect(fallback.counts['mjv'], 3);
  });

  test('async merge (detail path): JSON entries surface over an empty db',
      () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final dir = _writeJson(temp);
    final db = MemoryActressDatabase();
    final fallback = ActressJsonFallback(localJsonDir: dir)
      ..filmDb = FilmLibraryService(database: db);
    await fallback.load();
    final rows = await fallback.entriesForActressAsync('测试女优甲');
    expect(rows.map((e) => e.vodCode), containsAll(['SSIS-001', 'SSIS-002']));
    final byCode = await fallback.entriesForCodeAsync('SSIS-003');
    expect(byCode, hasLength(1));
    expect(byCode.single.vodActor, '仅JSON女优');
  });

  testWidgets('page: db person renders; json-only person does not enter list',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final dir = _writeJson(temp);
    final db = MemoryActressDatabase();
    await db.upsertRosterPerson(
      const RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: 'a1',
        name: '测试女优甲',
        sex: 'female',
      ),
    );
    final fallback = ActressJsonFallback(localJsonDir: dir);
    await fallback.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActressListPage(
            repository: FixtureRepository(),
            store: store,
            database: db,
            fallback: fallback,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 50));
      }
    });
    expect(tester.takeException(), isNull);
    expect(find.textContaining('测试女优甲'), findsWidgets);
    // 边界断言：只在本地 JSON 里的人不直接进人物列表（人物列表
    // 只读工作库，JSON 经详情合并/站点筛选进显示——既定口径）。
    final jsonOnlyFound = find.textContaining('仅JSON女优').evaluate().isNotEmpty;
    expect(jsonOnlyFound, isFalse);
  });
}
