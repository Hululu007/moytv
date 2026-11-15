import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/feed_adult_mix.dart';
import 'package:moyi/models.dart';

Drama _drama(String source, String id, {String cover = 'https://x/c.jpg'}) =>
    Drama(id: id, source: source, title: '$source-$id', cover: cover);

void main() {
  group('mixRecommendFeed', () {
    test('约五分之一为成人条目', () {
      final base = List.generate(20, (i) => _drama('base', 'b$i'));
      final adult = List.generate(10, (i) => _drama('adult', 'a$i'));
      final mixed = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(42),
      );
      expect(mixed.length, 25);
      expect(
        mixed.where((drama) => drama.source == 'adult').length,
        5,
      );
      // 基础条目顺序不变。
      expect(
        mixed.where((drama) => drama.source == 'base').map((d) => d.id),
        base.map((d) => d.id),
      );
    });

    test('同输入同种子同顺序', () {
      final base = List.generate(12, (i) => _drama('base', 'b$i'));
      final adult = List.generate(6, (i) => _drama('adult', 'a$i'));
      final first = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(7),
      );
      final second = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(7),
      );
      expect(
        first.map((d) => '${d.source}|${d.id}'),
        second.map((d) => '${d.source}|${d.id}'),
      );
    });

    test('无成人内容时原样不混', () {
      final base = List.generate(8, (i) => _drama('base', 'b$i'));
      final mixed = mixRecommendFeed(
        base: base,
        adult: const [],
        random: Random(1),
      );
      expect(mixed.map((d) => d.id), base.map((d) => d.id));
    });

    test('基础为空时返回空', () {
      final mixed = mixRecommendFeed(
        base: const [],
        adult: [_drama('adult', 'a0')],
        random: Random(1),
      );
      expect(mixed, isEmpty);
    });

    test('与基础重复的成人条目被去重', () {
      final base = List.generate(8, (i) => _drama('base', 'b$i'));
      final adult = [
        _drama('base', 'b2'),
        _drama('adult', 'a0'),
        _drama('adult', 'a1'),
      ];
      final mixed = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(3),
      );
      expect(
        mixed.where((drama) => drama.source == 'adult').length,
        2,
      );
      expect(
        mixed.where((drama) => drama.id == 'b2').length,
        1,
      );
    });
  });

  group('feedAdultCandidates', () {
    test('过滤文件夹与无封面条目并取前 N 条', () {
      final items = [
        _drama('s', 'ok1'),
        const Drama(id: 'f', source: 's', title: '夹', kind: 'folder'),
        _drama('s', 'nocover', cover: ''),
        _drama('s', 'ok2'),
        _drama('s', 'ok3'),
      ];
      expect(
        feedAdultCandidates(items, max: 2).map((d) => d.id),
        ['ok1', 'ok2'],
      );
    });
  });

  test('buildAdultFeed 按站序拼接并去重', () {
    final feed = buildAdultFeed([
      [_drama('s1', 'a'), _drama('s1', 'b')],
      [_drama('s1', 'a'), _drama('s2', 'c')],
    ]);
    expect(
      feed.map((d) => '${d.source}|${d.id}'),
      ['s1|a', 's1|b', 's2|c'],
    );
  });

  test('feedMixKey 随可见站与基础内容变化', () {
    expect(feedMixKey(['a'], 'k1'), feedMixKey(['a'], 'k1'));
    expect(feedMixKey(['a'], 'k1'), isNot(feedMixKey(['a', 'b'], 'k1')));
    expect(feedMixKey(['a'], 'k1'), isNot(feedMixKey(['a'], 'k2')));
  });

  group('recommendDenominatorFromHistory 口味分母', () {
    WatchEntry entry(String source, int i) => WatchEntry(
      drama: _drama(source, 'h$i'),
      episode: 1,
      position: 0,
      duration: 100,
      updatedAt: DateTime.utc(2026, 11, 15).subtract(Duration(minutes: i)),
    );

    // adult-site 成人、drama-site 短剧，其余站源 id 视为已不在
    // 站源表里、无法归类。
    bool? classify(String id) => switch (id) {
      'adult-site' => true,
      'drama-site' => false,
      _ => null,
    };

    List<WatchEntry> historyOf(List<String> sources) =>
        List.generate(sources.length, (i) => entry(sources[i], i));

    test('无历史 → 默认分母 5', () {
      expect(
        recommendDenominatorFromHistory(const [], isAdultSource: classify),
        recommendAdultMixDenominator,
      );
    });

    test('全看成人 → 分母 2（约一半成人）', () {
      final history = historyOf(List.filled(10, 'adult-site'));
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        2,
      );
    });

    test('全看短剧 → 分母 8（约八分之一成人）', () {
      final history = historyOf(List.filled(10, 'drama-site'));
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        8,
      );
    });

    test('一半一半 → 分母 5（回到默认）', () {
      final history = historyOf([
        ...List.filled(5, 'adult-site'),
        ...List.filled(5, 'drama-site'),
      ]);
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        5,
      );
    });

    test('四分之三成人 → 分母 4', () {
      final history = historyOf([
        ...List.filled(6, 'adult-site'),
        ...List.filled(2, 'drama-site'),
      ]);
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        4,
      );
    });

    test('无法归类的记录跳过不计', () {
      // 2 条成人 + 2 条未知站源：只计成人，占比 1 → 分母 2。
      final history = historyOf([
        'adult-site',
        'gone-site',
        'adult-site',
        'gone-site',
      ]);
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        2,
      );
      // 全是未知站源：无可分类记录 → 默认分母。
      final unknown = historyOf(['gone-site', 'gone-site']);
      expect(
        recommendDenominatorFromHistory(unknown, isAdultSource: classify),
        recommendAdultMixDenominator,
      );
    });

    test('站源为空的旧记录跳过不计', () {
      final history = historyOf(['', 'drama-site', '']);
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        8,
      );
    });

    test('只看最近 30 条：窗口外的成人记录不影响', () {
      final history = historyOf([
        ...List.filled(30, 'drama-site'),
        ...List.filled(10, 'adult-site'),
      ]);
      expect(
        recommendDenominatorFromHistory(history, isAdultSource: classify),
        8,
      );
    });

    test('分母落在 2 到 8 之间，永不越界', () {
      for (var adult = 0; adult <= 10; adult++) {
        final history = historyOf([
          ...List.filled(adult, 'adult-site'),
          ...List.filled(10 - adult, 'drama-site'),
        ]);
        final denom = recommendDenominatorFromHistory(
          history,
          isAdultSource: classify,
        );
        expect(
          denom,
          inInclusiveRange(
            recommendAdultMixMinDenominator,
            recommendAdultMixMaxDenominator,
          ),
        );
      }
    });
  });

  group('口味分母落到混排', () {
    test('分母 2 → 40 条基础里混入 40 条成人（约一半）', () {
      final base = List.generate(40, (i) => _drama('base', 'b$i'));
      final adult = List.generate(40, (i) => _drama('adult', 'a$i'));
      final mixed = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(3),
        denominator: 2,
      );
      expect(mixed.where((d) => d.source == 'adult').length, 40);
      expect(mixed.where((d) => d.source == 'base').length, 40);
    });

    test('分母 8 → 40 条基础里混入 5 条成人（约八分之一）', () {
      final base = List.generate(40, (i) => _drama('base', 'b$i'));
      final adult = List.generate(40, (i) => _drama('adult', 'a$i'));
      final mixed = mixRecommendFeed(
        base: base,
        adult: adult,
        random: Random(3),
        denominator: 8,
      );
      expect(mixed.where((d) => d.source == 'adult').length, 5);
      expect(mixed.where((d) => d.source == 'base').length, 40);
    });
  });
}
