import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/hongguo_series.dart';
import 'package:moyi/models.dart';

Drama drama(
  String id,
  String title, {
  String source = 'hongguo',
}) => Drama(id: id, source: source, title: title, episodes: 1);

void main() {
  group('hongguoSeriesInfo', () {
    test('第X季：阿拉伯数字', () {
      final info = hongguoSeriesInfo(drama('hongguo:1', '测试剧第2季'))!;
      expect(info.baseTitle, '测试剧');
      expect(info.season, 2);
      expect(info.unit, '季');
      expect(info.explicit, isTrue);
    });

    test('第X季：汉字数字', () {
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第一季'))!.season,
        1,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第十季'))!.season,
        10,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第十一季'))!.season,
        11,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第二十季'))!.season,
        20,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第一百季'))!.season,
        100,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第两百季'))!.season,
        200,
      );
    });

    test('第X季：零季与超大季号不认', () {
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第零季')),
        isNull,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第二百零一季')),
        isNull,
      );
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧第201季')), isNull);
    });

    test('第X部：部作单位，与季分开', () {
      final info = hongguoSeriesInfo(drama('hongguo:1', '测试剧第2部'))!;
      expect(info.season, 2);
      expect(info.unit, '部');
    });

    test('S 标记：分隔符后才认', () {
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧 S2'))!.season, 2);
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧 S02'))!.season, 2);
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧 Season 3'))!.season,
        3,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧-season 3'))!.season,
        3,
      );
      // 紧贴标题的 S 不认：XXS2 是标题本身的一部分。
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧S2')), isNull);
      expect(hongguoSeriesInfo(drama('hongguo:1', 'S2')), isNull);
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧 S201')), isNull);
    });

    test('上下部：上部为 1、下部为 2，单位是部', () {
      final first = hongguoSeriesInfo(drama('hongguo:1', '测试剧上部'))!;
      expect(first.season, 1);
      expect(first.unit, '部');
      final second = hongguoSeriesInfo(drama('hongguo:1', '测试剧下部'))!;
      expect(second.season, 2);
      expect(hongguoSeriesInfo(drama('hongguo:1', '上部')), isNull);
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧上部曲')), isNull);
    });

    test('非续季标题不误判', () {
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧前传')), isNull);
      expect(hongguoSeriesInfo(drama('hongguo:1', '第一滴血')), isNull);
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧季')), isNull);
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第3季预告片')),
        isNull,
      );
      expect(
        hongguoSeriesInfo(drama('hongguo:1', '测试剧第二季花絮')),
        isNull,
      );
      // 续集没有季号，排不了序，不认。
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧续集')), isNull);
    });

    test('非红果剧不认', () {
      expect(
        hongguoSeriesInfo(drama('other:1', '测试剧第2季', source: 'other')),
        isNull,
      );
    });

    test('无标记标题：无单位上下文时不认，有单位上下文时作隐含第 1 季', () {
      // 单独解析无标记标题时没有季信息，不认。
      expect(hongguoSeriesInfo(drama('hongguo:1', '测试剧')), isNull);
      // 分组时由调用方传入已确定的单位，无标记锚点作隐含第 1 季。
      final info = hongguoSeriesInfo(
        drama('hongguo:1', '测试剧'),
        unit: '季',
      )!;
      expect(info.season, 1);
      expect(info.unit, '季');
      expect(info.explicit, isFalse);
    });
  });

  group('hongguoSeriesEntries', () {
    test('同系列按季号升序，沾边标题与异站排除', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      final entries = hongguoSeriesEntries(anchor, {
        drama('hongguo:3', '测试剧第三季'),
        drama('hongguo:2', '测试剧第二季'),
        drama('hongguo:9', '测试剧前传'),
        drama('hongguo:8', '别的剧第一季'),
        drama('other:2', '测试剧第二季', source: 'other'),
        drama('hongguo:4', '测试剧第二部'),
      });
      expect(entries.map((e) => e.season), [1, 2, 3]);
      expect(entries.map((e) => e.drama.id), ['hongguo:1', 'hongguo:2', 'hongguo:3']);
    });

    test('无标记锚点与有标记候选组成系列', () {
      final anchor = drama('hongguo:1', '测试剧');
      final entries = hongguoSeriesEntries(anchor, {
        drama('hongguo:2', '测试剧第二季'),
        drama('hongguo:3', '测试剧第三季'),
      });
      expect(entries.map((e) => e.season), [1, 2, 3]);
    });

    test('无兄弟季时为空', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      expect(hongguoSeriesEntries(anchor, {}), isEmpty);
      expect(
        hongguoSeriesEntries(anchor, {drama('hongguo:2', '别的剧第一季')}),
        isEmpty,
      );
    });

    test('同季不同写法都归入同组（去重在合并层做）', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      final entries = hongguoSeriesEntries(anchor, {
        drama('hongguo:2', '测试剧第二季'),
        drama('hongguo:2b', '测试剧第 2 季'),
      });
      // 标题规律分组本身不去重：两条同季上架都列出；相关区走
      // hongguoMergedSeasonEntries，那里同季只留一个（见合并组测试）。
      expect(entries.map((e) => e.season), [1, 2, 2]);
    });

    test('上下部与第X部同一单位分组', () {
      final anchor = drama('hongguo:1', '测试剧上部');
      final entries = hongguoSeriesEntries(anchor, {
        drama('hongguo:2', '测试剧下部'),
        drama('hongguo:3', '测试剧第3部'),
        drama('hongguo:4', '测试剧第二季'),
      });
      expect(entries.map((e) => e.season), [1, 2, 3]);
      expect(entries.map((e) => e.label), ['第 1 部', '第 2 部', '第 3 部']);
    });
  });

  group('hongguoMergedSeasonEntries', () {
    test('站方季号直接信任，与标题规律合并', () {
      final anchor = drama('hongguo:2', '测试剧第二季');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: [
          (drama: drama('hongguo:1', '测试剧'), seasonIndex: 1),
          (drama: drama('hongguo:3', '测试剧'), seasonIndex: 3),
        ],
        candidates: {drama('hongguo:4', '测试剧第四季')},
      );
      expect(entries.map((e) => e.season), [1, 2, 3, 4]);
    });

    test('站方季号不可信时按标题复核', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: [
          (drama: drama('hongguo:2', '测试剧第二季'), seasonIndex: 0),
          (drama: drama('hongguo:9', '别的剧第一季'), seasonIndex: 0),
          (drama: drama('hongguo:8', '测试剧第八季'), seasonIndex: 201),
        ],
        candidates: const {},
      );
      expect(entries.map((e) => e.season), [1, 2, 8]);
    });

    test('同季去重：锚点优先', () {
      final anchor = drama('hongguo:1', '测试剧');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: [
          (drama: drama('hongguo:1b', '测试剧第一季'), seasonIndex: 1),
        ],
        candidates: const {},
      );
      // 只有同季重复、没有真兄弟季，相关区隐藏。
      expect(entries, isEmpty);
    });

    test('同季不同 id 的重复上架只留一个', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: const [],
        candidates: {
          drama('hongguo:2', '测试剧第二季'),
          drama('hongguo:2b', '测试剧第 2 季'),
        },
      );
      expect(entries.map((e) => e.season), [1, 2]);
    });

    test('同 id 站方季号优先于标题规律', () {
      final anchor = drama('hongguo:1', '测试剧第一季');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: [
          (drama: drama('hongguo:2', '测试剧第九季'), seasonIndex: 3),
        ],
        candidates: {drama('hongguo:2', '测试剧第九季')},
      );
      expect(entries.map((e) => e.season), [1, 3]);
    });

    test('非红果锚点没有相关季', () {
      final anchor = drama('other:1', '测试剧第一季', source: 'other');
      final entries = hongguoMergedSeasonEntries(
        anchor: anchor,
        apiSeasons: [
          (drama: drama('other:2', '测试剧第二季', source: 'other'), seasonIndex: 2),
        ],
        candidates: {drama('other:2', '测试剧第二季', source: 'other')},
      );
      expect(entries, isEmpty);
    });
  });

  group('hongguoNextSeasonEntry', () {
    final entries = [
      HongguoSeriesEntry(
        drama: drama('hongguo:1', '测试剧第一季'),
        season: 1,
        unit: '季',
      ),
      HongguoSeriesEntry(
        drama: drama('hongguo:2', '测试剧第二季'),
        season: 2,
        unit: '季',
      ),
      HongguoSeriesEntry(
        drama: drama('hongguo:3', '测试剧第三季'),
        season: 3,
        unit: '季',
      ),
    ];

    test('返回季号最小的下一季', () {
      expect(hongguoNextSeasonEntry(entries, 'hongguo:1')!.season, 2);
      expect(hongguoNextSeasonEntry(entries, 'hongguo:2')!.season, 3);
    });

    test('最后一季与锚点不在列表里时为空', () {
      expect(hongguoNextSeasonEntry(entries, 'hongguo:3'), isNull);
      expect(hongguoNextSeasonEntry(entries, 'hongguo:9'), isNull);
      expect(hongguoNextSeasonEntry(const [], 'hongguo:1'), isNull);
    });
  });
}
