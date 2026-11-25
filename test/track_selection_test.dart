import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/idj_contract.dart';
import 'package:moyi/models.dart';
import 'package:moyi/py_contract.dart';
import 'package:moyi/track_selection.dart';

void main() {
  group('parseSubtitleSources', () {
    test('对象形态：字段齐全原样保留', () {
      final subs = parseSubtitleSources([
        {
          'url': 'https://a.example/zh.srt',
          'name': '中文',
          'lang': 'zh',
          'format': 'srt',
        },
      ]);
      expect(subs, hasLength(1));
      expect(subs.single.name, '中文');
      expect(subs.single.lang, 'zh');
      expect(subs.single.format, 'srt');
    });

    test('format 缺失按扩展名推断，忽略查询串', () {
      final subs = parseSubtitleSources([
        {'url': 'https://a.example/en.vtt?token=1'},
      ]);
      expect(subs.single.format, 'vtt');
    });

    test('别名 n/v 与裸字符串形态', () {
      final subs = parseSubtitleSources([
        {'n': '英字', 'v': 'https://a.example/en.ass'},
        'https://a.example/ja.ssa',
      ]);
      expect(subs, hasLength(2));
      expect(subs[0].name, '英字');
      expect(subs[0].format, 'ass');
      expect(subs[1].format, 'ssa');
    });

    test('无地址条目丢弃、同地址去重、非数组回空', () {
      final subs = parseSubtitleSources([
        {'name': '没有地址'},
        {'url': 'https://a.example/x.srt'},
        {'url': 'https://a.example/x.srt', 'name': '重复'},
        '',
      ]);
      expect(subs, hasLength(1));
      expect(parseSubtitleSources(null), isEmpty);
      expect(parseSubtitleSources('not-a-list'), isEmpty);
    });
  });

  group('chooseDefaultSubtitle', () {
    test('空列表回 -1', () {
      expect(chooseDefaultSubtitle(const []), -1);
    });

    test('中文语言优先于顺序第一条', () {
      const subs = [
        SubtitleSource(url: 'https://a/en.srt', lang: 'en'),
        SubtitleSource(url: 'https://a/zh.srt', lang: 'zh-CN'),
      ];
      expect(chooseDefaultSubtitle(subs), 1);
    });

    test('lang 无命中时按名字含中文选', () {
      const subs = [
        SubtitleSource(url: 'https://a/1.srt', name: 'English'),
        SubtitleSource(url: 'https://a/2.srt', name: '简体中文'),
      ];
      expect(chooseDefaultSubtitle(subs), 1);
    });

    test('都没有时选第一条', () {
      const subs = [
        SubtitleSource(url: 'https://a/1.srt', lang: 'en'),
        SubtitleSource(url: 'https://a/2.srt', lang: 'ja'),
      ];
      expect(chooseDefaultSubtitle(subs), 0);
    });

    test('自定义偏好生效', () {
      const subs = [
        SubtitleSource(url: 'https://a/1.srt', lang: 'zh'),
        SubtitleSource(url: 'https://a/2.srt', lang: 'ja'),
      ];
      expect(chooseDefaultSubtitle(subs, preferredLanguages: ['ja']), 1);
    });
  });

  group('轨道菜单模型映射', () {
    test('音轨：顺序保留、选中态、标签回落语言/序号', () {
      final entries = buildAudioTrackEntries(
        const [
          TrackChoice(id: '1', language: 'jpn'),
          TrackChoice(id: '2', title: '国语'),
        ],
        selectedId: '2',
      );
      expect(entries.map((e) => e.label), ['jpn', '国语']);
      expect(entries.map((e) => e.selected), [false, true]);
      expect(entries.every((e) => e.kind == TrackMenuEntryKind.audio), isTrue);
    });

    test('字幕：关闭恒第一条，外挂在内嵌之后', () {
      final entries = buildSubtitleTrackEntries(
        const [TrackChoice(id: '3', language: 'eng')],
        external: const [
          SubtitleSource(url: 'https://a/zh.srt', name: '中文'),
        ],
        selectedEmbeddedId: '3',
      );
      expect(entries, hasLength(3));
      expect(entries[0].kind, TrackMenuEntryKind.subtitleOff);
      expect(entries[0].selected, isFalse);
      expect(entries[1].selected, isTrue);
      expect(entries[2].kind, TrackMenuEntryKind.subtitleExternal);
      expect(entries[2].externalUrl, 'https://a/zh.srt');
    });

    test('字幕：选中外挂时内嵌不标选中', () {
      final entries = buildSubtitleTrackEntries(
        const [TrackChoice(id: '3')],
        external: const [SubtitleSource(url: 'https://a/zh.srt')],
        selectedEmbeddedId: '3',
        selectedExternalUrl: 'https://a/zh.srt',
      );
      expect(entries[1].selected, isFalse);
      expect(entries[2].selected, isTrue);
    });

    test('字幕：关闭时只有关闭条目选中', () {
      final entries = buildSubtitleTrackEntries(
        const [TrackChoice(id: '3')],
        selectedEmbeddedId: '3',
        subtitlesOff: true,
      );
      expect(entries[0].selected, isTrue);
      expect(entries[1].selected, isFalse);
    });
  });

  group('subs 透传', () {
    test('PlaybackPlan.fromJson 读 subs', () {
      final plan = PlaybackPlan.fromJson({
        'url': 'https://a/v.m3u8',
        'subs': [
          {'url': 'https://a/zh.srt', 'name': '中文', 'lang': 'zh'},
        ],
      });
      expect(plan.subs, hasLength(1));
      expect(plan.subs.single.lang, 'zh');
      // with* 复制必须透传 subs
      expect(plan.withUrl('https://a/w.m3u8').subs, hasLength(1));
      expect(plan.withNeedsParse(true).subs, hasLength(1));
    });

    test('PyContract.planFromResult 读 subs', () {
      final plan = PyContract.planFromResult({
        'url': 'https://a/v.mp4',
        'subs': [
          {'url': 'https://a/en.vtt', 'lang': 'en'},
        ],
      });
      expect(plan.subs.single.format, 'vtt');
    });

    test('IdjContract.planFromResult 读顶层与流内 subs', () {
      final top = IdjContract.planFromResult({
        'streams': [
          {'url': 'https://cdn.example.com/v.m3u8'},
        ],
        'subs': [
          {'url': 'https://a/zh.srt', 'lang': 'zh'},
        ],
      });
      expect(top.subs, hasLength(1));
      final inStream = IdjContract.planFromResult({
        'streams': [
          {
            'url': 'https://cdn.example.com/v.m3u8',
            'subs': [
              {'url': 'https://a/ja.srt'},
            ],
          },
        ],
      });
      expect(inStream.subs.single.url, 'https://a/ja.srt');
    });
  });
}
