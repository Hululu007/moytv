import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_json_fallback.dart';

// 2026-11-22 回归测试：作品侧 codeKey 是库里的 vod_id 原样（rki-6042），
// 兜底条目的 codeKey 是 normalizeAvCode 归一化后的番号（RKI6042）。
// 两者直接比字符串永远不相等 → 库里 32 万条 m3u8 直链一条都取不到，
// 点播放只能回退去跨站爬，表现出来就是「有数据库却播不了」。
// 这里锁住「统一归一化后再匹配」这条口径。

ActressJsonEntry _entry({
  required String code,
  String url = 'https://v.hersav.me/hash/hash.m3u8',
  String site = 'whos',
}) => ActressJsonEntry(
  site: site,
  vodId: code.toLowerCase(),
  vodName: '测试片 $code',
  vodPic: 'https://v.hersav.me/images/av/hash.jpg',
  vodActor: '波多野結衣',
  vodDirector: '',
  vodRemarks: 'HD高清',
  vodPubdate: '2026-05-06',
  vodArea: '',
  vodYear: '',
  vodContent: '',
  vodPlayFrom: site,
  vodPlayUrl: url.isEmpty ? '' : '正片\$$url',
  typeName: '成人影片',
  vodCode: code,
  vodActressPic: '',
  directPlay: url.isNotEmpty,
);

void main() {
  group('jsonEntriesForWorkCode（库直链取流）', () {
    test('库里的 vod_id 原样能命中归一化后的条目', () {
      final pool = [
        _entry(code: 'rki-6042'),
        _entry(code: 'abc-123', url: 'https://v.hersav.me/b/b.m3u8'),
      ];
      final hit = jsonEntriesForWorkCode(pool, 'rki-6042');
      expect(hit, hasLength(1));
      expect(hit.first.playUrl, 'https://v.hersav.me/hash/hash.m3u8');
    });

    test('大小写、无横杠、多前导零都认（RKI6042 / rki6042 / RKI-06042）', () {
      final pool = [_entry(code: 'RKI-6042')];
      for (final workCode in ['rki-6042', 'RKI6042', 'rki6042', 'RKI-06042']) {
        expect(
          jsonEntriesForWorkCode(pool, workCode),
          hasLength(1),
          reason: '作品番号 $workCode 应该命中库里的 RKI-6042',
        );
      }
    });

    test('库行排在最前时按池子顺序返回（点播先试库里的地址）', () {
      final pool = [
        _entry(code: 'ssis-001', site: 'whos'),
        _entry(code: 'ssis-001', site: 'mjv'),
      ];
      final hit = jsonEntriesForWorkCode(pool, 'ssis-001');
      expect(hit, hasLength(2));
      expect(hit.first.site, 'whos');
    });

    test('没有播放地址的行不返回（不能拿空地址去开播放器）', () {
      final pool = [_entry(code: 'ssis-001', url: '')];
      expect(jsonEntriesForWorkCode(pool, 'ssis-001'), isEmpty);
    });

    test('番号对不上就不返回（不串片）', () {
      final pool = [_entry(code: 'ssis-001')];
      expect(jsonEntriesForWorkCode(pool, 'ssis-002'), isEmpty);
    });

    test('空番号返回空', () {
      final pool = [_entry(code: 'ssis-001')];
      expect(jsonEntriesForWorkCode(pool, ''), isEmpty);
      expect(jsonEntriesForWorkCode(pool, '---'), isEmpty);
    });
  });
}
