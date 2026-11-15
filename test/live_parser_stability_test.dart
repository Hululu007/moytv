import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/live_parser.dart';

void main() {
  group('EXTINF 频道名', () {
    test('频道名含逗号时不被截断', () {
      final parsed = LiveParser.parse(
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="cctv1" group-title="央视",CCTV-1, 高清\n'
        'http://example.com/cctv1.m3u8\n',
        source: 'test',
      );
      expect(parsed.channelCount, 1);
      expect(parsed.groups.single.channels.single.name, 'CCTV-1, 高清');
    });

    test('属性值里的逗号不被误认作分隔符', () {
      final parsed = LiveParser.parse(
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-name="A,B" group-title="测试",正经频道\n'
        'http://example.com/a.m3u8\n',
        source: 'test',
      );
      expect(parsed.groups.single.channels.single.name, '正经频道');
    });

    test('无逗号时回空名走未命名频道', () {
      final parsed = LiveParser.parse(
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="x"\n'
        'http://example.com/a.m3u8\n',
        source: 'test',
      );
      expect(parsed.groups.single.channels.single.name, '未命名频道');
    });
  });

  group('JSON 分组', () {
    test('同名分组出现两次时频道合并，不丢后一段', () {
      final parsed = LiveParser.parse(
        '[{"group": "电影", "channels": ['
        '{"name": "片A", "url": "http://example.com/a.m3u8"}]},'
        '{"group": "电影", "channels": ['
        '{"name": "片B", "url": "http://example.com/b.m3u8"}]}]',
        source: 'test',
      );
      expect(parsed.groups, hasLength(1));
      expect(parsed.groups.single.name, '电影');
      expect(
        parsed.groups.single.channels.map((c) => c.name),
        ['片A', '片B'],
      );
    });

    test('同名同频道多地址合并为多线路', () {
      final parsed = LiveParser.parse(
        '[{"group": "电影", "channels": ['
        '{"name": "片A", "url": "http://example.com/a1.m3u8"}]},'
        '{"group": "电影", "channels": ['
        '{"name": "片A", "url": "http://example.com/a2.m3u8"}]}]',
        source: 'test',
      );
      final channel = parsed.groups.single.channels.single;
      expect(channel.urls, [
        'http://example.com/a1.m3u8',
        'http://example.com/a2.m3u8',
      ]);
    });

    test('不同名分组互不干扰', () {
      final parsed = LiveParser.parse(
        '[{"group": "电影", "channels": ['
        '{"name": "片A", "url": "http://example.com/a.m3u8"}]},'
        '{"group": "体育", "channels": ['
        '{"name": "赛A", "url": "http://example.com/s.m3u8"}]}]',
        source: 'test',
      );
      expect(parsed.groups.map((g) => g.name), ['电影', '体育']);
    });

    test('全空分组回落到文本解析，不产出空结果', () {
      final parsed = LiveParser.parse(
        '[{"group": "空组", "channels": []}]',
        source: 'test',
      );
      expect(parsed.isEmpty, isTrue);
    });
  });
}
