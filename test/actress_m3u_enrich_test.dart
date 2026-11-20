// m3u 补全女优库（2026-11-20）：合演归属 + 合并规则 + 简介续补入口。
// 只用注入的假 asset 文本，不读树里的大 json、不碰磁盘。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';

Map<String, dynamic> _row({
  required String id,
  required String name,
  required String actor,
  required String playFrom,
  required String playUrl,
  required String code,
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
    'type_name': '日本AV',
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

void main() {
  final mjvJson = _doc([
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
      name: '作品一新版',
      actor: '波多野結衣',
      playFrom: 'mjv011',
      playUrl: '正片\$https://a.example/2.m3u8',
      code: 'SSIS-001',
    ),
    _row(
      id: 'a3',
      name: '作品二',
      actor: '大槻ひびき',
      playFrom: 'mjv011',
      playUrl: '正片\$https://a.example/3.m3u8',
      code: 'SSIS-002',
    ),
    _row(
      id: 'a4',
      name: '作品二重复',
      actor: '大槻ひびき',
      playFrom: 'mjv011',
      playUrl: '正片\$https://a.example/3.m3u8',
      code: 'SSIS-002',
    ),
    _row(
      id: 'a5',
      name: '作品三',
      actor: '波多野結衣',
      playFrom: 'mjv011',
      playUrl: '正片\$https://a.example/4.m3u8',
      code: 'SSIS-003',
    ),
  ]);
  final whosJson = _doc([
    _row(
      id: 'b1',
      name: '作品三合演',
      actor: '大槻響，波多野結衣',
      playFrom: 'whos',
      playUrl: '正片\$https://b.example/4.m3u8',
      code: 'SSIS-003',
    ),
    _row(
      id: 'b2',
      name: '无名作品',
      actor: '',
      playFrom: 'whos',
      playUrl: '正片\$https://b.example/5.m3u8',
      code: '',
    ),
  ]);

  Future<ActressJsonFallback> _load() async {
    final fallback = ActressJsonFallback(
      assetReader: (asset) async =>
          asset == ActressJsonFallback.mjvAsset ? mjvJson : whosJson,
    );
    await fallback.load();
    return fallback;
  }

  test('夹具两份 JSON 合 hsck 格式', () {
    for (final text in [mjvJson, whosJson]) {
      expect(
        () => validateActressJsonDocument(
          jsonDecode(text) as Map<String, dynamic>,
          'fixture',
        ),
        returnsNormally,
      );
    }
  });

  test('合并规则：同键同链接跳过、同键不同链接替换、同番号不同站都留', () async {
    final fallback = await _load();
    expect(fallback.counts['mjv'], 3);
    expect(fallback.counts['whos'], 2);
    expect(fallback.entries.length, 5);
    // SSIS-001：后一条（不同链接）替换了前一条。
    final ssis1 = fallback.entriesForCode('SSIS1');
    expect(ssis1.length, 1);
    expect(ssis1.first.playUrl, 'https://a.example/2.m3u8');
    // SSIS-002：同链接重复行被跳过，只留一条。
    expect(fallback.entriesForCode('SSIS2').length, 1);
    // SSIS-003：mjv 与 whos 各留一条。
    expect(fallback.entriesForCode('SSIS3').length, 2);
  });

  test('合演行按每个女优名都能查到', () async {
    final fallback = await _load();
    final hatano = fallback.entriesForActress('波多野結衣');
    expect(hatano.length, 3);
    final otsuki = fallback.entriesForActress('大槻響');
    expect(otsuki.length, 1);
    expect(otsuki.first.vodCode, 'SSIS-003');
  });

  test('简介续补：空简介不动，有简介追加并转义', () {
    final entry = ActressJsonEntry.fromRow(
      _row(
        id: 'c1',
        name: '作品',
        actor: '波多野結衣',
        playFrom: 'whos',
        playUrl: '正片\$https://b.example/6.m3u8',
        code: 'SSIS-004',
      ),
      'whos',
    );
    final unchanged = mergeWhosBioIntoRow(entry, '   ');
    expect(unchanged.vodContent, '<p>test</p>');
    final merged = mergeWhosBioIntoRow(entry, '身高 163cm <script>');
    expect(merged.vodContent, '<p>test</p><p>身高 163cm &lt;script&gt;</p>');
    expect(merged.vodName, '作品');
    expect(merged.vodCode, 'SSIS-004');
    expect(merged.vodPlayUrl, '正片\$https://b.example/6.m3u8');
  });
}
