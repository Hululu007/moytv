import 'package:moyi/global_search_page.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sites = [
    SourceSite('hongguo', '红果短剧', '', section: SourceSite.sectionDrama),
    SourceSite(
      'vod1',
      '点播站',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originConfig,
    ),
    SourceSite(
      'mid1',
      '午夜站',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    ),
  ];

  test('results group by section then site, unknown sites go last', () {
    final groups = groupGlobalVideoResults(const [
      Drama(id: 'mid1:1', source: 'mid1', title: '午夜剧'),
      Drama(id: 'hongguo:1', source: 'hongguo', title: '短剧一'),
      Drama(id: 'vod1:1', source: 'vod1', title: '点播剧'),
      Drama(id: 'hongguo:2', source: 'hongguo', title: '短剧二'),
      Drama(id: 'ghost:1', source: 'ghost', title: '未知站剧'),
    ], sites);
    // 午夜区已并入点播区：内置视频站与配置视频站同属「点播」组，
    // 同区内按站名排序（「午夜站」<「点播站」），未知站最后。
    expect(groups.map((g) => g.section).toList(), ['短剧', '点播', '点播', '其他']);
    expect(groups.first.siteName, '红果短剧');
    expect(groups.first.items.map((d) => d.title).toList(), ['短剧一', '短剧二']);
    expect(groups[1].siteName, '午夜站');
    expect(groups[2].siteName, '点播站');
    expect(groups.last.siteName, 'ghost');
  });

  test('empty results group to nothing', () {
    expect(groupGlobalVideoResults(const [], sites), isEmpty);
  });

  test('增量追加最终与整批分组一致（组序、站序、站内条目序全同）', () {
    const all = [
      Drama(id: 'mid1:1', source: 'mid1', title: '午夜剧'),
      Drama(id: 'hongguo:1', source: 'hongguo', title: '短剧一'),
      Drama(id: 'vod1:1', source: 'vod1', title: '点播剧'),
      Drama(id: 'hongguo:2', source: 'hongguo', title: '短剧二'),
      Drama(id: 'ghost:1', source: 'ghost', title: '未知站剧'),
    ];
    final batch = groupGlobalVideoResults(all, sites);
    // 模拟流式到达：先点播，再红果分两次到，再午夜，最后未知站。
    var groups = const <GlobalVideoGroup>[];
    groups = appendGlobalVideoGroup(groups, [all[2]], sites);
    groups = appendGlobalVideoGroup(groups, [all[1]], sites);
    groups = appendGlobalVideoGroup(groups, [all[3]], sites);
    groups = appendGlobalVideoGroup(groups, [all[0]], sites);
    groups = appendGlobalVideoGroup(groups, [all[4]], sites);
    expect(
      groups.map((g) => (g.section, g.siteId, g.siteName)).toList(),
      batch.map((g) => (g.section, g.siteId, g.siteName)).toList(),
    );
    for (var i = 0; i < groups.length; i++) {
      expect(
        groups[i].items.map((d) => d.id).toList(),
        batch[i].items.map((d) => d.id).toList(),
      );
    }
  });

  test('同站两次追加合并为一组，条目按到达序拼接', () {
    var groups = appendGlobalVideoGroup(const [], const [
      Drama(id: 'hongguo:1', source: 'hongguo', title: '一'),
    ], sites);
    groups = appendGlobalVideoGroup(groups, const [
      Drama(id: 'hongguo:2', source: 'hongguo', title: '二'),
    ], sites);
    expect(groups, hasLength(1));
    expect(
      groups.first.items.map((d) => d.title).toList(),
      ['一', '二'],
    );
  });

  test('空追加不改变分组（返回同一列表）', () {
    final groups = groupGlobalVideoResults(const [
      Drama(id: 'vod1:1', source: 'vod1', title: '点播剧'),
    ], sites);
    expect(appendGlobalVideoGroup(groups, const [], sites), same(groups));
  });
}
