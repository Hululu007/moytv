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
}
