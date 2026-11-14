import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_models.dart';
import 'package:moyi/live_parser.dart';
import 'package:moyi/live_sources.dart';

/// 打包规格：资产文件名、源 id、manifest kept 条数、默认分组、期望分组集合。
/// 条数抄自 ~/workspace/tg_forward_read/m3u_clean/manifest.json（kept 列），
/// 合计 127432；12_wuma 与 18_mingxing 的打包副本各删 1 行孤地址
/// （地址哈希含 loli 子串），EXTINF 条数不受影响。
const _spec = <(
  String file,
  String id,
  int kept,
  String group,
  List<String> groups,
)>[
  ('01_zhubo.m3u', 'm3u_zhubo', 6889, '主播网红', ['主播网红']),
  ('02_luanlun.m3u', 'm3u_luanlun', 4181, '乱伦精品', ['乱伦精品']),
  ('03_huayu.m3u', 'm3u_huayu', 2868, '华语精品', ['华语精品']),
  ('04_guochan.m3u', 'm3u_guochan', 9763, '国产精品', ['国产精品']),
  ('05_xuesheng.m3u', 'm3u_xuesheng', 4229, '学生合集', ['学生合集']),
  ('06_tanhua.m3u', 'm3u_tanhua', 4876, '探花约炮', ['探花约炮']),
  ('07_riben.m3u', 'm3u_riben', 10540, '日本有码', ['日本有码']),
  ('08_oumei.m3u', 'm3u_oumei', 9671, '欧美大屌', ['欧美大屌']),
  ('09_heilian.m3u', 'm3u_heilian', 3349, '黑料吃瓜', ['黑料吃瓜']),
  (
    '10_community10.m3u8',
    'm3u_community10',
    3953,
    '社区合集 10',
    ['社区合集 10', 'ИНФО'],
  ),
  (
    '11_community11.m3u8',
    'm3u_community11',
    2671,
    '社区合集 11',
    ['社区合集 11'],
  ),
  ('12_wuma.m3u', 'm3u_wuma', 23236, '無碼專區', ['無碼專區']),
  ('13_wanghong.m3u', 'm3u_wanghong', 3826, '網紅頭條', ['網紅頭條']),
  ('14_xingba.m3u', 'm3u_xingba', 613, '杏吧原創', ['杏吧原創']),
  ('15_chengtou.m3u', 'm3u_chengtou', 2824, '成人頭條', ['成人頭條']),
  ('16_zhifu.m3u', 'm3u_zhifu', 2822, '制服絲襪', ['制服絲襪']),
  ('17_qunjiao.m3u', 'm3u_qunjiao', 1844, '群交淫亂', ['群交淫亂']),
  ('18_mingxing.m3u', 'm3u_mingxing', 2809, '明星換臉', ['明星換臉']),
  ('19_zipai.m3u', 'm3u_zipai', 22508, '自拍偷拍', ['自拍偷拍']),
  ('20_avxiongdi.m3u', 'm3u_avxiongdi', 576, 'AV兄弟无码', ['AV兄弟无码']),
  ('21_guochanse.m3u', 'm3u_guochanse', 11, '国产色情', ['国产色情']),
  ('22_riben2.m3u', 'm3u_riben2', 3373, '日本有码', ['日本有码']),
];

/// 安全硬线词表：命中任一词即失败。loli 不分大小写。
const _bannedWords = [
  '萝莉',
  '蘿莉',
  '幼女',
  '幼齿',
  '幼齒',
  '未成年',
  '小学生',
  '初中生',
  '儿童',
  '女童',
  '男童',
  '小女孩',
  '小男孩',
  '未满18',
  '未满十八',
  '10岁',
  '11岁',
  '12岁',
  '13岁',
  '14岁',
  '15岁',
  '16岁',
  '17岁',
];

String _readAsset(String file) =>
    File('assets/live/m3u/$file').readAsStringSync();

/// 独立于解析器的规格级重算：按 m3u 格式把（分组，标题）映射到地址列，
/// 返回（频道数，地址总数）。与 LiveParser 的输出交叉核对：同名同组
/// 的条目合并为多线路频道是既有语义，地址一条不丢才是硬指标。
({int channels, int urls}) _recount(String text, String defaultGroup) {
  final grouped = <String, Map<String, List<String>>>{};
  var pendingKey = '';
  var pendingGroup = '';
  for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
    if (raw.startsWith('#EXTINF:')) {
      final name = raw.substring(raw.lastIndexOf(',') + 1).trim();
      final title = name.isEmpty ? '未命名频道' : name;
      final lower = title.toLowerCase();
      if (lower.startsWith('更新时间') ||
          lower.startsWith('更新日期') ||
          lower.startsWith('update time') ||
          lower.startsWith('update date') ||
          lower.startsWith('last update')) {
        pendingKey = '';
        continue;
      }
      final match = RegExp('group-title="(.*?)"').firstMatch(raw);
      final group = (match?.group(1)?.trim() ?? '').isEmpty
          ? defaultGroup
          : match!.group(1)!.trim();
      pendingGroup = group;
      pendingKey = title;
      grouped
          .putIfAbsent(group, () => {})
          .putIfAbsent(title, () => []);
      continue;
    }
    if (pendingKey.isEmpty || raw.startsWith('#') || raw.isEmpty) continue;
    final url = raw.split('|').first.trim();
    if (!isPlayableLiveUrl(url)) continue;
    grouped[pendingGroup]![pendingKey]!.add(url);
  }
  var channels = 0;
  var urls = 0;
  for (final group in grouped.values) {
    for (final list in group.values) {
      if (list.isEmpty) continue;
      channels++;
      urls += list.length;
    }
  }
  return (channels: channels, urls: urls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('22 个 m3u 源注册齐全且走 asset 清单', () {
    for (final row in _spec) {
      final source = LiveSource.byId(row.$2);
      expect(source, isNotNull, reason: row.$2);
      expect(source!.protocol, LiveProtocol.list);
      expect(source.endpoints, ['asset://assets/live/m3u/${row.$1}']);
      expect(source.group, row.$4);
      expect(source.adult, isTrue);
      expect(source.builtin, isTrue);
    }
  });

  test('每文件 EXTINF 条数与 manifest 一致，合计 127432', () {
    var total = 0;
    for (final row in _spec) {
      final text = _readAsset(row.$1);
      final count = text
          .split('\n')
          .where((line) => line.startsWith('#EXTINF:'))
          .length;
      expect(count, row.$3, reason: row.$1);
      total += count;
    }
    expect(total, 127432);
  });

  test('安全扫描：打包数据全文 0 命中', () {
    for (final row in _spec) {
      final text = _readAsset(row.$1);
      for (final word in _bannedWords) {
        expect(text.contains(word), isFalse, reason: '${row.$1} 命中 $word');
      }
      expect(
        text.toLowerCase().contains('loli'),
        isFalse,
        reason: '${row.$1} 命中 loli',
      );
    }
  });

  test('解析：分组齐全、地址可播、条数与独立重算一致', () {
    for (final row in _spec) {
      final text = _readAsset(row.$1);
      final parsed = LiveParser.parse(
        text,
        source: row.$2,
        defaultGroup: row.$4,
      );
      expect(
        parsed.groups.map((g) => g.name).toSet(),
        row.$5.toSet(),
        reason: row.$1,
      );
      final expected = _recount(text, row.$4);
      expect(parsed.channelCount, expected.channels, reason: '${row.$1} 频道数');
      final urls = [
        for (final group in parsed.groups)
          for (final channel in group.channels) ...channel.urls,
      ];
      expect(urls.length, expected.urls, reason: '${row.$1} 地址数');
      for (final channel in [
        for (final group in parsed.groups) ...group.channels,
      ]) {
        expect(channel.playable, isTrue, reason: '${row.$1} ${channel.name}');
        expect(channel.source, row.$2);
        for (final url in channel.urls) {
          expect(isPlayableLiveUrl(url), isTrue);
        }
      }
    }
  });

  test('抽样播放地址：首/中/末频道地址为 http(s) 流地址', () {
    for (final row in _spec) {
      final parsed = LiveParser.parse(
        _readAsset(row.$1),
        source: row.$2,
        defaultGroup: row.$4,
      );
      final channels = [
        for (final group in parsed.groups) ...group.channels,
      ];
      expect(channels, isNotEmpty);
      for (final channel in [
        channels.first,
        channels[channels.length ~/ 2],
        channels.last,
      ]) {
        expect(channel.url, startsWith('http'));
        expect(
          channel.url.contains('.m3u') || channel.url.contains('.mp4'),
          isTrue,
          reason: '${row.$1} ${channel.name} ${channel.url}',
        );
      }
    }
  });

  testWidgets('asset 打包可读：最小清单经 rootBundle 解析', (tester) async {
    final text = await rootBundle.loadString(
      'assets/live/m3u/21_guochanse.m3u',
    );
    final parsed = LiveParser.parse(
      text,
      source: 'm3u_guochanse',
      defaultGroup: '国产色情',
    );
    expect(parsed.channelCount, 11);
    expect(parsed.groups.map((g) => g.name).toList(), ['国产色情']);
  });

  test('可见性：绿色模式整源隐藏，非绿色模式 22 源都在', () {
    final ids = _spec.map((row) => row.$2).toSet();
    final shown = LiveSource.visible(false).map((s) => s.id).toSet();
    expect(shown.intersection(ids), ids);
    final hidden = LiveSource.visible(true).map((s) => s.id).toSet();
    expect(hidden.intersection(ids), isEmpty);
  });
}
