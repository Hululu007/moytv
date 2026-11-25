// 导出格式生成器（往返验证的一半）：用真实 ActressDbExporter 把
// 一批刁钻值（引号/换行/-- 与 /* 在字符串里/空值/数字）导成 .sql
// 落到 harness/export_sample.sql；另一半在 harness_pkg/bin/
// export_import_check.dart：用真实导入器把它导回并逐字断言。
// 本文件身兼断言：导出成功、文件结构完整。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_db_export.dart';
import 'package:moyi/actress/actress_spreadsheet.dart';

class _TrickyStore implements ActressExportStore {
  final tables = <String, List<Map<String, Object?>>>{
    'videos': [
      {
        'vod_id': 'k1037',
        'title': "K1037 餌食牝 -- 北上尚子 '引号' \"双引\"",
        'pic_url': 'https://img.test/k.jpg',
        'm3u8_url': 'https://v.test/k.m3u8',
        'vod_play_url': 'https://v.test/k.m3u8',
        'type_name': '成人影片',
      },
      {
        'vod_id': 'pfes-065',
        'title': '带 /* 块注释 */ 样的标题\n第二行',
        'pic_url': null,
        'm3u8_url': 'https://v.test/p.m3u8',
        'vod_play_url': 'https://v.test/p.m3u8',
        'type_name': '成人影片',
      },
    ],
    'actresses': [
      {'cate_id': '北上尚子', 'name': '北上尚子', 'avatar': ''},
    ],
    'video_actress': [
      {'vod_id': 'k1037', 'cate_id': '北上尚子'},
      {'vod_id': 'pfes-065', 'cate_id': '北上尚子'},
    ],
    'video_play_urls': [
      {
        'vod_id': 'k1037',
        'play_url': 'https://v.test/k.m3u8',
        'play_from': 'whos.tv',
      },
      {
        'vod_id': 'pfes-065',
        'play_url': 'https://v.test/p.m3u8',
        'play_from': 'whos.tv',
      },
    ],
    'video_category': [
      {'vod_id': 'k1037', 'main_category': '有码'},
      {'vod_id': 'pfes-065', 'main_category': '有码'},
    ],
    'video_tag': [
      {'vod_id': 'k1037', 'tag_name': '标签一'},
    ],
  };

  @override
  Future<List<String>> tableNames() async => tables.keys.toList();

  @override
  Future<String?> tableSql(String table) async => switch (table) {
    'videos' =>
      'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, '
          'pic_url TEXT, m3u8_url TEXT, vod_play_url TEXT, '
          'type_name TEXT)',
    'actresses' =>
      'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, '
          'avatar TEXT)',
    'video_actress' => 'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT)',
    'video_play_urls' =>
      'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, '
          'play_from TEXT)',
    'video_category' =>
      'CREATE TABLE video_category (vod_id TEXT, main_category TEXT)',
    'video_tag' => 'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT)',
    _ => null,
  };

  @override
  Future<List<String>> indexSqls() async => const [];

  @override
  Future<int> countRows(String table) async => tables[table]?.length ?? 0;

  @override
  Future<List<Map<String, Object?>>> rowsPage(
    String table,
    int offset,
    int limit,
  ) async {
    final rows = tables[table] ?? const [];
    if (offset >= rows.length) return const [];
    return rows.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countWorks() async => 2;

  @override
  Future<List<SpreadsheetWorkRow>> worksPage(int offset, int limit) async =>
      const [];

  @override
  Future<void> close() async {}
}

void main() {
  test('导出刁钻值 .sql 供往返验证', () async {
    final out =
        '/home/hatch/workspace/moyi_import_fix_20261125/harness/'
        'export_sample.sql';
    final result = await const ActressDbExporter().exportSql(
      store: _TrickyStore(),
      outPath: out,
      compressed: false,
    );
    expect(result.ok, isTrue);
    final text = File(out).readAsStringSync();
    expect(text, contains('CREATE TABLE videos'));
    expect(text.trimRight().endsWith('COMMIT;'), isTrue);
    // 标题里的 -- 必须原样留在字符串里（切分器根因回归点）。
    expect(text, contains('餌食牝 -- 北上尚子'));
  });
}
