// 女优库 JSON 兜底（2026-11-19）：随包 mjv011.json / whos.json 原样对接。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';

Future<String> _readRealAsset(String asset) async =>
    File(asset).readAsString();

void main() {
  late final Map<String, dynamic> mjvDoc;
  late final Map<String, dynamic> whosDoc;

  setUpAll(() {
    mjvDoc =
        jsonDecode(File('assets/actress_json/mjv011.json').readAsStringSync())
            as Map<String, dynamic>;
    whosDoc =
        jsonDecode(File('assets/actress_json/whos.json').readAsStringSync())
            as Map<String, dynamic>;
  });

  test('随包两份 JSON 合 hsck 格式：顶层四键、每行 15 字段同顺序', () {
    for (final entry in {'mjv011': mjvDoc, 'whos': whosDoc}.entries) {
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
    // 本次快照条数（爬取还在涨，只断言下限，不钉死具体数；下限按
    // 2026-11-20 内置的 5337/201 行快照取，旧 321/171 行文件
    // 若被误恢复，下限即拦住）。
    expect((mjvDoc['list'] as List).length, greaterThanOrEqualTo(5000));
    expect((whosDoc['list'] as List).length, greaterThanOrEqualTo(200));
  });

  test('格式不对就报错：缺顶层键、字段顺序错、播放地址不是正片\$地址', () {
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

  test('加载器：按番号与女优名匹配，两站各留各的', () async {
    final fallback = ActressJsonFallback(assetReader: _readRealAsset);
    await fallback.load();
    expect(fallback.loaded, isTrue);
    // 随包文件本身按（分类，番号）合并不去重：同键同链接的被合掉，
    // 所以加载后的条数 ≤ 原始行数。
    int mergedCount(Map<String, dynamic> doc) {
      final keys = <String>{};
      for (final row in (doc['list'] as List).cast<Map<String, dynamic>>()) {
        final code = normalizeAvCode(row['vod_code'] as String);
        keys.add(
          '${row['type_name']}|${code.isNotEmpty ? code : row['vod_id']}',
        );
      }
      return keys.length;
    }

    expect(fallback.counts['mjv'], mergedCount(mjvDoc));
    expect(fallback.counts['whos'], mergedCount(whosDoc));

    // 取 mjv 文件里第一条既有番号又有女优名的真条目作样例。
    final sample =
        (mjvDoc['list'] as List).cast<Map<String, dynamic>>().firstWhere(
          (row) =>
              (row['vod_code'] as String).isNotEmpty &&
              (row['vod_actor'] as String).isNotEmpty,
        );
    final sampleCode = normalizeAvCode(sample['vod_code'] as String);
    final sampleActor = sample['vod_actor'] as String;
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
    expect(
      fallback.entriesForCode(sampleCode, site: 'whos'),
      isEmpty,
    );
    // 没番号没名字查不到。
    expect(fallback.entriesForCode(''), isEmpty);
    expect(fallback.entriesForActress('不存在的名字'), isEmpty);
  });

  test('本地现爬文件叠加：同番号同链接跳过，任一字段不同就替换', () async {
    final temp = Directory.systemTemp.createTempSync();
    addTearDown(() => temp.deleteSync(recursive: true));
    final localDir = Directory('${temp.path}/actress_json')
      ..createSync(recursive: true);
    // 本地放一条：与随包第一条同（分类，番号）同链接（应跳过），
    // 再放一条同番号不同链接（应替换）。
    final first =
        (mjvDoc['list'] as List).cast<Map<String, dynamic>>().firstWhere(
          (row) => (row['vod_code'] as String).isNotEmpty,
        );
    final same = Map<String, dynamic>.from(first);
    final replaced = Map<String, dynamic>.from(first)
      ..['vod_play_url'] = '正片\$https://example.test/new.m3u8';
    final localDoc = {
      'list': [same, replaced],
      'parse': 0,
      'jx': 0,
      'last_update': '2026-11-19T18:00:00',
    };
    File('${localDir.path}/mjv.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(localDoc),
    );
    final fallback = ActressJsonFallback(
      assetReader: _readRealAsset,
      documentsDir: temp,
    );
    await fallback.load();
    final codeKey = normalizeAvCode(first['vod_code'] as String);
    final rows = fallback.entriesForCode(codeKey, site: 'mjv');
    // 同键只剩一条，且是替换后的新链接。
    expect(rows.length, 1);
    expect(rows.single.playUrl, 'https://example.test/new.m3u8');
  });

  test('兜底卡点播用的合成详情：单集正片、集 id 就是直链、走潮流蜘蛛', () async {
    final fallback = ActressJsonFallback(assetReader: _readRealAsset);
    await fallback.load();
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
