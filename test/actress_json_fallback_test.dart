// 女优库 JSON 兜底（2026-11-19）：本地 json 文件原样对接。
// 2026-11-22 用户令最终口径：随包 json 已不再打包、不再读，
// 这里的文档全是内联合成的小样例，写进临时本地目录再读。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

Map<String, dynamic> _row({
  required String vodId,
  required String code,
  required String actor,
  String playFrom = 'mjv011',
  String playUrl = '正片\$https://example.test/1.m3u8',
  String typeName = '有码',
  String name = '',
}) => {
  'vod_id': vodId,
  'vod_name': name.isNotEmpty ? name : code,
  'vod_pic': 'https://example.test/cover.jpg',
  'vod_actor': actor,
  'vod_director': '',
  'vod_remarks': '高清',
  'vod_pubdate': '2026-01-01',
  'vod_area': '日本',
  'vod_year': '2026',
  'vod_content': '',
  'vod_play_from': playFrom,
  'vod_play_url': playUrl,
  'type_name': typeName,
  'vod_code': code,
  'vod_actress_pic': '',
};

Map<String, dynamic> _doc(
  List<Map<String, dynamic>> rows, {
  String lastUpdate = '2026-11-20T00:00:00',
}) => {
  'list': rows,
  'parse': 0,
  'jx': 0,
  'last_update': lastUpdate,
};

/// mjv 侧样例：两条同女优、不同番号。
final _mjvDoc = _doc([
  _row(vodId: 'mjv-1', code: 'SSIS-001', actor: '测试女优'),
  _row(
    vodId: 'mjv-2',
    code: 'SSIS-002',
    actor: '测试女优',
    playUrl: '正片\$https://example.test/2.m3u8',
  ),
]);

/// whos 侧样例：一条。
final _whosDoc = _doc([
  _row(
    vodId: 'whos-1',
    code: 'ABC-123',
    actor: '另一位演员',
    playFrom: 'whos',
    playUrl: '正片\$https://example.test/3.m3u8',
  ),
]);

/// 把两份样例写进临时本地目录（mjv011.json 是单文件权威，
/// whos.json 是旧版分站文件），返回配好 localJsonDir 的加载器。
Future<ActressJsonFallback> _loadLocal(Directory temp) async {
  final dir = Directory('${temp.path}/actress_json')
    ..createSync(recursive: true);
  File('${dir.path}/mjv011.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(_mjvDoc),
  );
  File('${dir.path}/whos.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(_whosDoc),
  );
  final fallback = ActressJsonFallback(localJsonDir: dir);
  await fallback.load();
  return fallback;
}

void main() {
  test('本地两份 JSON 合 hsck 格式：顶层四键、每行 15 字段同顺序', () {
    for (final entry in {'mjv011': _mjvDoc, 'whos': _whosDoc}.entries) {
      expect(
        () => validateActressJsonDocument(entry.value, entry.key),
        returnsNormally,
      );
      expect(entry.value.keys.toSet(), actressJsonTopKeys);
      expect(entry.value['parse'], 0);
      expect(entry.value['jx'], 0);
      final rows = entry.value['list'] as List;
      expect(rows.isNotEmpty, isTrue);
      for (final row in rows) {
        expect(
          (row as Map).keys.toList(),
          actressJsonFieldOrder,
          reason: '${entry.key} 行字段顺序必须与 hsck 一致',
        );
        expect(row['vod_remarks'], '高清');
      }
    }
    expect((_mjvDoc['list'] as List).length, 2);
    expect((_whosDoc['list'] as List).length, 1);
  });

  test('格式不对就报错：缺顶层键、字段顺序错、播放地址不是正片\$地址', () {
    final missingKey = Map<String, dynamic>.from(_mjvDoc)..remove('jx');
    expect(
      () => validateActressJsonDocument(missingKey, '缺键'),
      throwsFormatException,
    );
    final badOrder = jsonDecode(jsonEncode(_mjvDoc)) as Map<String, dynamic>;
    final rows = badOrder['list'] as List;
    final first = Map<String, dynamic>.from(rows.first as Map);
    final reordered = <String, dynamic>{
      'vod_code': first['vod_code'],
      for (final e in first.entries)
        if (e.key != 'vod_code') e.key: e.value,
    };
    rows[0] = reordered;
    expect(
      () => validateActressJsonDocument(badOrder, '顺序错'),
      throwsFormatException,
    );
    final badUrl = jsonDecode(jsonEncode(_mjvDoc)) as Map<String, dynamic>;
    (badUrl['list'] as List).first['vod_play_url'] =
        'https://example.test/x.m3u8';
    expect(
      () => validateActressJsonDocument(badUrl, '地址错'),
      throwsFormatException,
    );
  });

  test('加载器：按番号与女优名匹配，两站各留各的', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final fallback = await _loadLocal(temp);
    expect(fallback.loaded, isTrue);
    expect(fallback.counts['mjv'], 2);
    expect(fallback.counts['whos'], 1);

    const sampleCode = 'SSIS1';
    const sampleActor = '测试女优';
    final byCode = fallback.entriesForCode(sampleCode);
    expect(byCode.isNotEmpty, isTrue);
    expect(byCode.every((e) => e.codeKey == sampleCode), isTrue);
    final byName = fallback.entriesForActress(sampleActor);
    expect(byName.isNotEmpty, isTrue);
    expect(byName.every((e) => e.vodActor == sampleActor), isTrue);
    // 站点限定：只取 mjv 的。
    expect(
      fallback.entriesForCode(sampleCode, site: 'mjv').isNotEmpty,
      isTrue,
    );
    expect(fallback.entriesForCode(sampleCode, site: 'whos'), isEmpty);
    // 没番号没名字查不到。
    expect(fallback.entriesForCode(''), isEmpty);
    expect(fallback.entriesForActress('不存在的名字'), isEmpty);
  });

  test('本地文件叠加：同番号同链接跳过，任一字段不同就替换', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final dir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    // 旧版分站文件先读：原始行；单文件 mjv011.json 后读（权威）：
    // 同番号不同链接，应替换为新链接；同键只剩一条。
    final original = _row(vodId: 'mjv-1', code: 'SSIS-001', actor: '测试女优');
    final replaced = _row(
      vodId: 'mjv-1',
      code: 'SSIS-001',
      actor: '测试女优',
      playUrl: '正片\$https://example.test/new.m3u8',
    );
    File('${dir.path}/mjv.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_doc([original])),
    );
    File('${dir.path}/mjv011.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(_doc([replaced])),
    );
    final fallback = ActressJsonFallback(localJsonDir: dir);
    await fallback.load();
    final rows = fallback.entriesForCode('SSIS1', site: 'mjv');
    expect(rows.length, 1);
    expect(rows.single.playUrl, 'https://example.test/new.m3u8');
  });

  test('兜底卡点播用的合成详情：单集正片、集 id 就是直链、走潮流蜘蛛', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final fallback = await _loadLocal(temp);
    final entry = fallback.entries
        .firstWhere((e) => e.playable && e.codeKey.isNotEmpty);
    expect(entry.playUrl, startsWith('https://'));
    final detail = entry.toDramaDetail();
    expect(detail.drama.source, ActressJsonFallback.playSource);
    expect(detail.episodes.length, 1);
    expect(detail.episodes.single.title, '正片');
    expect(detail.episodes.single.id, entry.playUrl);
  });
}
