import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/hero_mix.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_home_view.dart';

import 'fixtures.dart';

Drama _drama(
  String source,
  String id, {
  String cover = 'https://example.test/cover.jpg',
  String kind = 'video',
}) => Drama(
  id: id,
  source: source,
  title: '$source-$id',
  cover: cover,
  kind: kind,
);

SourceSite _site(String id, String name) => SourceSite(id, name, '');

void main() {
  group('heroBaseSlides', () {
    test('跳过文件夹与无封面条目，上限 6 条', () {
      final items = [
        _drama('hongguo', 'a'),
        _drama('hongguo', 'folder', kind: 'folder'),
        _drama('hongguo', 'nocover', cover: ''),
        _drama('hongguo', 'b'),
        _drama('hongguo', 'c'),
        _drama('hongguo', 'd'),
        _drama('hongguo', 'e'),
        _drama('hongguo', 'f'),
        _drama('hongguo', 'g'),
      ];
      final base = heroBaseSlides(items);
      expect(base.map((d) => d.id), ['a', 'b', 'c', 'd', 'e', 'f']);
    });
  });

  group('sampleAdultSites', () {
    final sites = [
      _site('hongguo', '红果'),
      _site('missav', '🔞MissAV'),
      _site('supjav', '🔞SupJav'),
      _site('jav', 'JAV'),
      _site('x18', '🔞X18'),
      _site('yabo', '🔞亚博'),
      _site('plain', '普通站'),
    ];

    test('只抽 🔞 标记的站，不按站名猜', () {
      final picked = sampleAdultSites(
        sites,
        random: Random(1),
        count: 10,
      );
      expect(
        picked.map((s) => s.id),
        unorderedEquals(['missav', 'supjav', 'x18', 'yabo']),
      );
    });

    test('排除指定站源且不超过上限', () {
      final picked = sampleAdultSites(
        sites,
        random: Random(2),
        count: 2,
        excludeIds: {'missav'},
      );
      expect(picked.length, 2);
      expect(picked.map((s) => s.id), isNot(contains('missav')));
    });

    test('成人池为空时返回空', () {
      expect(
        sampleAdultSites(
          [_site('hongguo', '红果')],
          random: Random(3),
        ),
        isEmpty,
      );
    });

    test('同一种子抽站结果相同', () {
      final a = sampleAdultSites(sites, random: Random(42));
      final b = sampleAdultSites(sites, random: Random(42));
      expect(
        a.map((s) => s.id),
        b.map((s) => s.id),
      );
    });
  });

  group('adultHeroCandidates', () {
    test('取前 2 条带真封面的非文件夹条目', () {
      final items = [
        _drama('missav', 'folder', kind: 'folder'),
        _drama('missav', 'nocover', cover: '  '),
        _drama('missav', 'a'),
        _drama('missav', 'b'),
        _drama('missav', 'c'),
      ];
      expect(
        adultHeroCandidates(items).map((d) => d.id),
        ['a', 'b'],
      );
    });
  });

  group('mixHeroSlides', () {
    final base = List.generate(6, (i) => _drama('hongguo', 'h$i'));
    final adult = List.generate(5, (i) => _drama('missav', 'm$i'));

    test('6 基础 + 5 成人 → 9 张、成人 3 张、首位不动', () {
      final mixed = mixHeroSlides(
        base: base,
        adult: adult,
        random: Random(7),
      );
      expect(mixed.length, 9);
      expect(mixed.first.id, 'h0');
      expect(mixed.where((d) => d.source == 'missav').length, 3);
      expect(
        mixed.map((d) => '${d.source}|${d.id}').toSet().length,
        9,
      );
    });

    test('成人为空时原样回落基础位', () {
      expect(
        mixHeroSlides(base: base, adult: [], random: Random(7)),
        base,
      );
    });

    test('基础位为空时返回空', () {
      expect(
        mixHeroSlides(base: [], adult: adult, random: Random(7)),
        isEmpty,
      );
    });

    test('成人里与基础位重复的同一视频被去重', () {
      final dupes = [
        _drama('hongguo', 'h2'),
        _drama('missav', 'm0'),
        _drama('missav', 'm0'),
        _drama('missav', 'm1'),
      ];
      final mixed = mixHeroSlides(
        base: base,
        adult: dupes,
        random: Random(7),
      );
      expect(mixed.where((d) => d.source == 'missav').length, 2);
      expect(mixed.map((d) => d.id).where((id) => id == 'h2').length, 1);
    });

    test('同一种子混排结果相同，换种子首位始终不动', () {
      final a = mixHeroSlides(base: base, adult: adult, random: Random(99));
      final b = mixHeroSlides(base: base, adult: adult, random: Random(99));
      expect(
        a.map((d) => d.id),
        b.map((d) => d.id),
      );
      for (var seed = 0; seed < 20; seed++) {
        final mixed = mixHeroSlides(
          base: base,
          adult: adult,
          random: Random(seed),
        );
        expect(mixed.first.id, 'h0');
      }
    });
  });

  group('heroMixKey', () {
    test('同内容键相同，内容变化键变化', () {
      final base = heroBaseSlides(List.generate(3, (i) => _drama('hg', 'a$i')));
      expect(heroMixKey(base), heroMixKey(List.of(base)));
      expect(
        heroMixKey(base),
        isNot(heroMixKey([...base, _drama('hg', 'a3')])),
      );
    });
  });

  group('NeonHomeView featured wiring', () {
    var opened = <Drama>[];
    var featuredOpened = <Drama>[];

    Future<void> pumpView(
      WidgetTester tester, {
      List<Drama>? featuredItems,
      ValueChanged<Drama>? onOpenFeatured,
    }) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      opened.clear();
      featuredOpened.clear();
      final items = [
        _drama('hongguo', 'row0'),
        _drama('hongguo', 'row1'),
        _drama('hongguo', 'row2'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NeonHomeView(
              items: items,
              repository: FixtureRepository(),
              brand: '魔蚁box',
              sourceLabel: '红果 (1)',
              onOpen: opened.add,
              onSearch: () {},
              onSourceTap: () {},
              onLongPress: (_) {},
              featuredItems: featuredItems,
              onOpenFeatured: onOpenFeatured,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('轮播用覆盖位、两排用原列表，点成人幻灯片走 onOpenFeatured', (
      tester,
    ) async {
      final featured = [
        _drama('hongguo', 'hero0'),
        _drama('missav', 'adult1'),
      ];
      await pumpView(
        tester,
        featuredItems: featured,
        onOpenFeatured: featuredOpened.add,
      );
      // 轮播显示覆盖位标题，两排显示原列表标题。
      expect(find.text('hongguo-hero0'), findsOneWidget);
      expect(find.text('hongguo-row0'), findsWidgets);
      // 点第一张轮播卡（基础位），走 onOpenFeatured。
      await tester.tap(find.byKey(const ValueKey('neon-hero-hero0')));
      await tester.pump();
      expect(featuredOpened.map((d) => d.id), ['hero0']);
      expect(opened, isEmpty);
    });

    testWidgets('马上看与幻灯片点按同一条路', (tester) async {
      await pumpView(
        tester,
        featuredItems: [_drama('missav', 'adult0')],
        onOpenFeatured: featuredOpened.add,
      );
      await tester.tap(find.text('马上看').first);
      await tester.pump();
      expect(featuredOpened.map((d) => d.id), ['adult0']);
      expect(opened, isEmpty);
    });

    testWidgets('两排点按仍走 onOpen', (tester) async {
      await pumpView(
        tester,
        featuredItems: [_drama('missav', 'adult0')],
        onOpenFeatured: featuredOpened.add,
      );
      await tester.tap(find.text('hongguo-row0').first);
      await tester.pump();
      expect(opened.map((d) => d.id), ['row0']);
      expect(featuredOpened, isEmpty);
    });

    testWidgets('无覆盖位时轮播仍从原列表取前 6 条', (tester) async {
      await pumpView(tester);
      expect(find.text('hongguo-row0'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('neon-hero-row0')));
      await tester.pump();
      expect(opened.map((d) => d.id), ['row0']);
    });
  });
}
