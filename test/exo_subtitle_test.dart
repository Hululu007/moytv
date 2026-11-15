import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/exo_subtitle.dart';

void main() {
  group('normalizeExoSubtitleText', () {
    test('ASS 换行转真换行', () {
      expect(
        normalizeExoSubtitleText(r'第一行\N第二行'),
        '第一行\n第二行',
      );
      expect(
        normalizeExoSubtitleText(r'第一行\n第二行'),
        '第一行\n第二行',
      );
    });

    test('硬空格转空格、行内覆盖块去掉', () {
      expect(
        normalizeExoSubtitleText(r'{\an8}顶部{\pos(100,20)}文字\h间隔'),
        '顶部文字 间隔',
      );
    });

    test('空行丢弃、首尾空白去掉', () {
      expect(
        normalizeExoSubtitleText('  第一行  \n\n  \n第二行  '),
        '第一行\n第二行',
      );
    });

    test('只有覆盖块时为空', () {
      expect(normalizeExoSubtitleText(r'{\pos(10,10)}{\an5}'), '');
    });

    test('真换行保留', () {
      expect(normalizeExoSubtitleText('a\nb'), 'a\nb');
    });
  });

  group('layoutExoSubtitleLines', () {
    test('同组两条 cue 各占一行不合并', () {
      final lines = layoutExoSubtitleLines(const [
        ExoSubtitleCue(text: '中文台词'),
        ExoSubtitleCue(text: 'English line'),
      ]);
      expect(lines, ['中文台词', 'English line']);
    });

    test('空 cue 与重复 cue 只留一条', () {
      final lines = layoutExoSubtitleLines(const [
        ExoSubtitleCue(text: '  '),
        ExoSubtitleCue(text: '同句'),
        ExoSubtitleCue(text: '同句'),
        ExoSubtitleCue(text: r'{\an8}同句'),
      ]);
      expect(lines, ['同句']);
    });

    test('带 line 的 cue 按上下位置排序', () {
      final lines = layoutExoSubtitleLines(const [
        ExoSubtitleCue(text: '底部对话', line: 0.9),
        ExoSubtitleCue(text: '顶部招牌', line: 0.1),
        ExoSubtitleCue(text: '无定位对话'),
      ]);
      expect(lines, ['顶部招牌', '底部对话', '无定位对话']);
    });

    test('line 超出分数范围时按解码顺序沉底', () {
      final lines = layoutExoSubtitleLines(const [
        ExoSubtitleCue(text: '行号形态', line: -1),
        ExoSubtitleCue(text: '分数形态', line: 0.5),
      ]);
      expect(lines, ['分数形态', '行号形态']);
    });

    test('cue 内多行保持为一项', () {
      final lines = layoutExoSubtitleLines(const [
        ExoSubtitleCue(text: r'第一行\N第二行'),
      ]);
      expect(lines, ['第一行\n第二行']);
    });
  });

  group('ExoSubtitleBuffer', () {
    ExoSubtitleGroup group(int timeUs, List<String> texts) =>
        ExoSubtitleGroup(
          presentationTimeUs: timeUs,
          cues: texts.map((text) => ExoSubtitleCue(text: text)).toList(),
        );

    test('取最新不超时的组', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(1000000, ['第一句']))
        ..push(group(3000000, ['第二句']));
      expect(buffer.activeCuesAt(1500).map((cue) => cue.text), ['第一句']);
      expect(buffer.activeCuesAt(3000).map((cue) => cue.text), ['第二句']);
      expect(buffer.activeCuesAt(500).map((cue) => cue.text), isEmpty);
    });

    test('空组清掉上一组', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(1000000, ['第一句']))
        ..push(group(2000000, []));
      expect(buffer.activeCuesAt(2500), isEmpty);
    });

    test('正偏移延后、负偏移提前', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(2000000, ['第二句']));
      // 偏移 +500ms：位置 2200 时仍显示 2000 之前的状态（无）。
      expect(
        buffer.activeCuesAt(2200, offsetMs: 500),
        isEmpty,
      );
      expect(
        buffer.activeCuesAt(2600, offsetMs: 500).map((cue) => cue.text),
        ['第二句'],
      );
      // 偏移 -500ms：位置 1600 时已提前显示 2000 的组。
      expect(
        buffer.activeCuesAt(1600, offsetMs: -500).map((cue) => cue.text),
        ['第二句'],
      );
    });

    test('seek 回退取回早期的组', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(1000000, ['第一句']))
        ..push(group(3000000, ['第二句']));
      expect(buffer.activeCuesAt(3500).map((cue) => cue.text), ['第二句']);
      expect(buffer.activeCuesAt(1500).map((cue) => cue.text), ['第一句']);
    });

    test('乱序到达按时间戳归位、同时间戳替换', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(3000000, ['第二句']))
        ..push(group(1000000, ['第一句']))
        ..push(group(1000000, ['第一句改']));
      expect(buffer.activeCuesAt(1500).map((cue) => cue.text), ['第一句改']);
      expect(buffer.activeCuesAt(3500).map((cue) => cue.text), ['第二句']);
    });

    test('clear 后无字幕', () {
      final buffer = ExoSubtitleBuffer()
        ..push(group(1000000, ['第一句']))
        ..clear();
      expect(buffer.activeCuesAt(1500), isEmpty);
    });
  });

  group('ExoSubtitleGroup.fromChannelMap', () {
    test('正常 map 解析', () {
      final group = ExoSubtitleGroup.fromChannelMap({
        'presentationTimeUs': 1234567,
        'cues': [
          {'text': '台词', 'line': 0.9, 'position': 0.5},
          {'text': 'plain'},
        ],
      });
      expect(group, isNotNull);
      expect(group!.presentationTimeUs, 1234567);
      expect(group.cues.length, 2);
      expect(group.cues[0].line, 0.9);
      expect(group.cues[0].position, 0.5);
      expect(group.cues[1].line, isNull);
    });

    test('形状不对返回 null、坏 cue 只跳过该条', () {
      expect(ExoSubtitleGroup.fromChannelMap(null), isNull);
      expect(ExoSubtitleGroup.fromChannelMap('nope'), isNull);
      expect(ExoSubtitleGroup.fromChannelMap({'cues': []}), isNull);
      expect(
        ExoSubtitleGroup.fromChannelMap({
          'presentationTimeUs': 1000,
          'cues': 'nope',
        }),
        isNull,
      );
      final group = ExoSubtitleGroup.fromChannelMap({
        'presentationTimeUs': 1000,
        'cues': [
          {'text': 42},
          'junk',
          {'text': '好的'},
        ],
      });
      expect(group!.cues.map((cue) => cue.text), ['好的']);
    });
  });

  group('ExoSubtitleOverlay', () {
    testWidgets('多行拼成一个 Text、不重叠', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExoSubtitleOverlay(lines: ['中文台词', 'English line']),
          ),
        ),
      );
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.data, '中文台词\nEnglish line');
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('无字幕时不画 Text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ExoSubtitleOverlay(lines: ['  ', '']),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });
}
