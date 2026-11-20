// 女优库 JSON 兜底（2026-11-21）：随包快照已删，只读本地现爬文件。
// 不读任何随包 asset；本地没有的条目走 m3u 行补。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

Map<String, dynamic> _row({
  required String id,
  required String name,
  required String actor,
  required String playFrom,
  required String playUrl,
  required String code,
  String typeName = '日本AV',
}) {
  return <String, dynamic>{
    'vod_id': id,
    'vod_name': name,
    'vod_pic': '',
    'vod_actor': actor,
    'vod_director': '',
    'vod_remarks': '高清',
    'vod_pubdate': '',
    'vod_area': '日本',
    'vod_year': '',
    'vod_content': '<p>test</p>',
    'vod_play_from': playFrom,
    'vod_play_url': playUrl,
    'type_name': typeName,
    'vod_code': code,
    'vod_actress_pic': '',
  };
}

String _doc(List<Map<String, dynamic>> rows) => jsonEncode(<String, dynamic>{
  'list': rows,
  'parse': 0,
  'jx': 0,
  'last_update': '2026-11-20T00:00:00',
});

Map<String, dynamic> _mjvDoc() => jsonDecode(_doc([
  _row(
    id: 'a1',
    name: '作品一',
    actor: '波多野結衣',
    playFrom: 'mjv011',
    playUrl: '正片\$https://a.example/1.m3u8',
    code: 'SSIS-001',
  ),
  _row(
    id: 'a2',
    name: '作品二',
    actor: '大槻ひびき',
    playFrom: 'mjv011',
    playUrl: '正片\$https://a.example/2.m3u8',
    code: 'SSIS-002',
  ),
  _row(
    id: 'a3',
    name: '作品三',
    actor: '波多野結衣',
    playFrom: 'mjv011',
    playUrl: '正片\$https://a.example/3.m3u8',
    code: 'SSIS-003',
  ),
])) as Map<String, dynamic>;

Map<String, dynamic> _whosDoc() => jsonDecode(_doc([
  _row(
    id: 'b1',
    name: '作品三合演',
    actor: '大槻響，波多野結衣',
    playFrom: 'whos',
    playUrl: '正片\$https://b.example/3.m3u8',
    code: 'SSIS-003',
  ),
])) as Map<String, dynamic>;

void main() {
  test('本地文件合 hsck 格式：顶层四键、每行 15 字段同顺序', () {
    for (final entry in {'mjv': _mjvDoc(), 'whos': _whosDoc()}.entries) {
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
  });

  test('格式不对就报错：缺顶层键、字段顺序错、播放地址不是正片\$地址', () {
    final mjvDoc = _mjvDoc();
    final missingKey = Map<String, dynamic>.from(mjvDoc)..remove('jx');
    expect(
      () => validateActressJsonDocument(missingKey, '缺键'),
      throwsFormatException,
    );
    final badOrder = jsonDecode(jsonEncode(mjvDoc)) as Map<String, dynamic>;
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
    final badUrl = jsonDecode(jsonEncode(mjvDoc)) as Map<String, dynamic>;
    (badUrl['list'] as List).first['vod_play_url'] =
        'https://example.test/x.m3u8';
    expect(
      () => validateActressJsonDocument(badUrl, '地址错'),
      throwsFormatException,
    );
  });

  test('加载器只读本地文件：按番号与女优名匹配，两站各留各的', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final localDir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    File('${localDir.path}/mjv.json').writeAsStringSync(_doc(
      (_mjvDoc()['list'] as List).cast<Map<String, dynamic>>(),
    ));
    File('${localDir.path}/whos.json').writeAsStringSync(_doc(
      (_whosDoc()['list'] as List).cast<Map<String, dynamic>>(),
    ));
    final fallback = ActressJsonFallback(documentsDir: temp);
    await fallback.load();
    expect(fallback.loaded, isTrue);
    expect(fallback.counts['mjv'], 3);
    expect(fallback.counts['whos'], 1);

    final byCode = fallback.entriesForCode('SSIS1');
    expect(byCode, hasLength(1));
    expect(byCode.single.codeKey, 'SSIS1');
    final byName = fallback.entriesForActress('波多野結衣');
    // mjv 两行（a1、a3）+ whos 合演行（b1 也挂她的名），共三条。
    expect(byName, hasLength(3));
    expect(byName.every((e) => e.vodActor.contains('波多野結衣')), isTrue);
    // 同番号两站各留一条。
    expect(fallback.entriesForCode('SSIS3'), hasLength(2));
    // 站点限定：只取 mjv 的。
    expect(
      fallback.entriesForCode('SSIS1', site: 'mjv').isNotEmpty,
      isTrue,
    );
    expect(fallback.entriesForCode('SSIS1', site: 'whos'), isEmpty);
    // 没番号没名字查不到。
    expect(fallback.entriesForCode(''), isEmpty);
    expect(fallback.entriesForActress('不存在的名字'), isEmpty);
  });

  test('不读随包 asset：本地目录为空即零条目（回归）', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    // 树里随包文件若还在，加载器也不许碰；这里只断言空目录即空池。
    final fallback = ActressJsonFallback(documentsDir: temp);
    await fallback.load();
    expect(fallback.loaded, isTrue);
    expect(fallback.entries, isEmpty);
    expect(fallback.counts, isEmpty);
  });

  test('同文件内同键同链接跳过、不同链接后写替换', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final localDir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    File('${localDir.path}/mjv.json').writeAsStringSync(_doc([
      _row(
        id: 'a1',
        name: '作品一',
        actor: '测试演员',
        playFrom: 'mjv011',
        playUrl: '正片\$https://x/1.m3u8',
        code: 'SSIS-123',
      ),
      _row(
        id: 'a1',
        name: '作品一',
        actor: '测试演员',
        playFrom: 'mjv011',
        playUrl: '正片\$https://x/1.m3u8',
        code: 'SSIS-123',
      ),
      _row(
        id: 'a1',
        name: '作品一新版',
        actor: '测试演员',
        playFrom: 'mjv011',
        playUrl: '正片\$https://x/new.m3u8',
        code: 'SSIS-123',
      ),
    ]));
    final fallback = ActressJsonFallback(documentsDir: temp);
    await fallback.load();
    final rows = fallback.entriesForCode('SSIS123');
    expect(rows, hasLength(1));
    expect(rows.single.playUrl, 'https://x/new.m3u8');
  });

  test('兜底卡点播用的合成详情：单集正片、集 id 就是直链、走潮流蜘蛛', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final localDir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    File('${localDir.path}/mjv.json').writeAsStringSync(_doc(
      (_mjvDoc()['list'] as List).cast<Map<String, dynamic>>(),
    ));
    final fallback = ActressJsonFallback(documentsDir: temp);
    await fallback.load();
    final entry = fallback.entries.firstWhere(
      (e) => e.playable && e.codeKey.isNotEmpty,
    );
    expect(entry.playUrl, startsWith('https://'));
    final detail = entry.toDramaDetail();
    expect(detail.drama.source, ActressJsonFallback.playSource);
    expect(detail.episodes.length, 1);
    expect(detail.episodes.single.title, '正片');
    expect(detail.episodes.single.id, entry.playUrl);
  });
}
