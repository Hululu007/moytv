import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/tg_list_postprocess.dart';

/// TG 列表后处理测试：广告过滤、去重、归拢、组 id 编解码、
/// Movie 组详情合成，以及标题归一/集号与 jar 的逐条对照。
///
/// 对照表（parityFixtures）由 Java harness 逐条跑出：函数与模式
/// 从 ZakaTgAllAmns 反编译原文摘录，未改一字；harness 与输入见
/// ~/workspace/tg11_decompile/parity/。Dart 移植必须与之一致，
// 对照表由脚本生成，勿手改。

Drama _drama(
  String id,
  String title, {
  String source = 'jar:zakatv:ZakaTg',
  String cover = '',
  String description = '',
  String category = '',
  String kind = 'video',
  String folderId = '',
}) {
  return Drama(
    id: id,
    source: source,
    title: title,
    cover: cover,
    description: description,
    category: category,
    kind: kind,
    folderId: folderId,
  );
}

CatalogPage _page(List<Drama> items) => CatalogPage(items, hasMore: true);

void main() {
  setUp(TgGroupMembers.clear);
  tearDown(TgGroupMembers.clear);

  group('Java parity: tgTitleKey / tgEpisodeNumber', () {
    const parityFixtures = <_ParityFixture>[
      _ParityFixture("《甜蜜暴击》第1集", "甜蜜暴击", 1),
      _ParityFixture("《甜蜜暴击》第2集", "甜蜜暴击", 2),
      _ParityFixture("甜蜜暴击 第3集 1080P", "甜蜜暴击", 3),
      _ParityFixture("甜蜜暴击 EP04", "甜蜜暴击", 4),
      _ParityFixture("甜蜜暴击 E5", "甜蜜暴击", 5),
      _ParityFixture("甜蜜暴击 S01E06", "甜蜜暴击", 6),
      _ParityFixture("甜蜜暴击 1-3集", "甜蜜暴击", 1),
      _ParityFixture("甜蜜暴击 07", "甜蜜暴击", 7),
      _ParityFixture("甜蜜暴击07", "甜蜜暴击07", 7),
      _ParityFixture("甜蜜暴击 (1080P) 第8集", "甜蜜暴击", 8),
      _ParityFixture("【甜蜜暴击】第9集", "", 9),
      _ParityFixture("甜蜜暴击.mp4", "甜蜜暴击", 0),
      _ParityFixture("甜蜜暴击 第10话", "甜蜜暴击", 10),
      _ParityFixture("甜蜜暴击 更新至第11集", "甜蜜暴击", 11),
      _ParityFixture("甜蜜暴击 全12集", "甜蜜暴击", 12),
      _ParityFixture("甜蜜暴击共12集", "甜蜜暴击", 12),
      _ParityFixture("甜蜜暴击 t.me/abc123 第13集", "甜蜜暴击", 13),
      _ParityFixture("甜蜜暴击 @someuser 第14集", "甜蜜暴击", 14),
      _ParityFixture("<b>甜蜜暴击</b> 第15集", "甜蜜暴击", 15),
      _ParityFixture("甜蜜暴击 4K 无码 第16集", "甜蜜暴击", 16),
      _ParityFixture("S02E03 甜蜜暴击", "甜蜜暴击", 3),
      _ParityFixture("甜蜜暴击 EP 17", "甜蜜暴击", 17),
      _ParityFixture("甜蜜暴击 ep-18", "甜蜜暴击", 18),
      _ParityFixture("甜蜜暴击 19-20集", "甜蜜暴击", 19),
      _ParityFixture("甜蜜暴击 第21期", "甜蜜暴击", 21),
      _ParityFixture("甜蜜暴击 第22节", "甜蜜暴击", 22),
      _ParityFixture("甜蜜暴击 2024", "甜蜜暴击", 2024),
      _ParityFixture("甜蜜暴击 12345", "甜蜜暴击12345", 0),
      _ParityFixture("AB123 甜蜜暴击", "AB123甜蜜暴击", 0),
      _ParityFixture("甜蜜暴击 S1 E7", "甜蜜暴击", 7),
      _ParityFixture("甜蜜暴击[中字]第23集", "甜蜜暴击", 23),
      _ParityFixture("甜蜜暴击（高清）第24集", "甜蜜暴击", 24),
      _ParityFixture(
        "《甜蜜暴击之再续前缘特别篇加长版第二季第三季第四季第五季第六季第七季第八季第九季第十季》第1集",
        "甜蜜暴击之再续前缘特别篇加长版第二季第三季第四季第五季第六季第七季第八季第九季第",
        1,
      ),
      _ParityFixture("甜蜜暴击 第25集 完结", "甜蜜暴击", 25),
      _ParityFixture("甜蜜暴击 第26集 115直链", "甜蜜暴击", 26),
      _ParityFixture("纯标题无集数", "纯标题无集数", 0),
      _ParityFixture("第1集", "", 1),
      _ParityFixture("甜蜜暴击 1", "甜蜜暴击", 1),
      _ParityFixture("甜蜜暴击-27", "甜蜜暴击", 27),
      _ParityFixture("甜蜜暴击_28", "甜蜜暴击", 28),
      _ParityFixture("Sweet Strike S01E01", "SweetStrike", 1),
      _ParityFixture("Sweet Strike EP02", "SweetStrike", 2),
      _ParityFixture("Sweet.Strike.03", "SweetStrike", 3),
      _ParityFixture("甜蜜暴击 第29集 中文字幕 国语", "甜蜜暴击", 29),
      _ParityFixture("甜蜜暴击 第30集 [1080P][中字]", "甜蜜暴击", 30),
    ];
    for (final fixture in parityFixtures) {
      test('parity: ${fixture.title}', () {
        expect(tgTitleKey(fixture.title), fixture.key);
        expect(tgEpisodeNumber(fixture.title), fixture.epNo);
      });
    }
  });

  group('ad filter', () {
    test('screenshot ad posts are filtered', () {
      const ads = [
        '先说清楚：这是广告，我按月收钱，Hi VPN 限时优惠',
        '这里是「时光无水印SVIP」内群介绍',
        '没有关注的失联频道的，请关注下，备用频道防失联',
        '香草AI 全网最火性爱游戏',
        '黄游神话，巅峰人气',
        'Telegram必备的搜索引擎，极搜JISOU',
        'TG免费高速代理-免费VPN高速节点',
        '点击下载APP看更多，扫码加微信',
        '进群领取免费节点，机场直达',
        'QQ群交流，电报群备用',
      ];
      for (final title in ads) {
        expect(
          tgIsAdPost(title: title, description: ''),
          isTrue,
          reason: '应过滤：$title',
        );
      }
    });

    test('description hits also filter', () {
      expect(tgIsAdPost(title: '甜蜜暴击 第1集', description: '推广：加微信领资源'), isTrue);
    });

    test('normal videos pass, bare 关注/游戏 do not filter', () {
      const ok = ['甜蜜暴击 第1集', '关注的她 第2集', '游戏人生 第1集', '黄昏游侠 第3集'];
      for (final title in ok) {
        expect(
          tgIsAdPost(title: title, description: ''),
          isFalse,
          reason: '不应过滤：$title',
        );
      }
      // 词表按字面命中：标题真含 VPN 字样时照样过滤，不猜意图。
      expect(tgIsAdPost(title: 'VPN 居然在标题里', description: ''), isTrue);
    });

    test('postProcessPage filters ads for TG classes only', () {
      final items = [
        _drama('u|1', '甜蜜暴击 第1集'),
        _drama('u|2', 'Hi VPN 限时优惠 按月收钱'),
      ];
      final kept = tgPostProcessPage(
        _page(items),
        className: tgAllAmnsClass,
        category: '',
      );
      expect(kept.items.map((d) => d.id), ['u|1']);
      expect(kept.hasMore, isTrue);
      final samePage = _page(items);
      expect(
        identical(
          tgPostProcessPage(
            samePage,
            className: 'com.github.catvod.spider.SomeOther',
            category: '',
          ),
          samePage,
        ),
        isTrue,
      );
    });
  });

  group('dedupe', () {
    test('same title + same cover keeps first only', () {
      final items = [
        _drama('u|1', 'Telegram必备的搜索引擎', cover: 'https://x/1.jpg'),
        _drama('u|2', 'Telegram必备的搜索引擎', cover: 'https://x/1.jpg'),
        _drama('u|3', '甜蜜暴击 第1集', cover: 'https://x/2.jpg'),
      ];
      final kept = tgDedupeItems(items);
      expect(kept.map((d) => d.id), ['u|1', 'u|3']);
    });

    test('whitespace/case differences still dedupe', () {
      final items = [
        _drama('u|1', 'Sweet  Strike', cover: 'https://x/1.jpg'),
        _drama('u|2', ' sweet strike ', cover: 'https://x/1.jpg'),
      ];
      expect(tgDedupeItems(items), hasLength(1));
    });

    test('different cover or empty cover keeps both', () {
      final items = [
        _drama('u|1', '同名帖', cover: 'https://x/1.jpg'),
        _drama('u|2', '同名帖', cover: 'https://x/2.jpg'),
        _drama('u|3', '同名帖'),
        _drama('u|4', '同名帖'),
      ];
      expect(tgDedupeItems(items), hasLength(4));
    });
  });

  group('grouping', () {
    test('multi-spelling episode titles group into one card', () {
      final items = [
        _drama('u|1', '甜蜜暴击 第1集', cover: 'https://x/1.jpg'),
        _drama('u|2', '甜蜜暴击 EP02', cover: 'https://x/2.jpg'),
        _drama('u|3', '甜蜜暴击 S01E03'),
        _drama('u|4', '甜蜜暴击 04'),
        _drama('u|5', '甜蜜暴击 E5'),
        _drama('u|6', '甜蜜暴击 6-7集'),
        _drama('u|7', '另一部片 第1集'),
      ];
      final grouped = tgGroupItems(items, isMovie: false);
      expect(grouped, hasLength(2));
      final card = grouped.first;
      expect(card.title, '甜蜜暴击');
      expect(card.episodes, 6);
      expect(card.heat, '6集');
      expect(card.cover, 'https://x/1.jpg');
      expect(card.id.startsWith('t|'), isTrue);
      expect(grouped.last.title, '另一部片 第1集');
    });

    test('movie groups use shelltg ids and are cached', () {
      final items = [
        _drama('u|1', '甜蜜暴击 第1集', source: 'jar:zakatv:ZakaTgMovie'),
        _drama('u|2', '甜蜜暴击 第2集', source: 'jar:zakatv:ZakaTgMovie'),
      ];
      final grouped = tgGroupItems(items, isMovie: true);
      expect(grouped, hasLength(1));
      expect(grouped.first.id.startsWith('shelltg|'), isTrue);
      expect(TgGroupMembers.lookup(grouped.first.id), hasLength(2));
    });

    test('zakatg groups are not cached (jar owns detail)', () {
      final items = [_drama('u|1', '甜蜜暴击 第1集'), _drama('u|2', '甜蜜暴击 第2集')];
      final grouped = tgGroupItems(items, isMovie: false);
      expect(TgGroupMembers.lookup(grouped.first.id), isNull);
    });

    test('singles, same-episode dupes and short keys stay ungrouped', () {
      final items = [
        _drama('u|1', '独苗 第1集'),
        _drama('u|2', '重发 第1集'),
        _drama('u|3', '重发 第1集'),
        _drama('u|4', '第1集'),
        _drama('u|5', '第2集'),
        _drama('u|6', '无集数标题'),
        _drama('u|7', '无集数标题'),
      ];
      final grouped = tgGroupItems(items, isMovie: false);
      expect(identical(grouped, items), isTrue);
      expect(grouped, hasLength(7));
    });

    test('already-grouped ids and folders are untouched', () {
      final items = [
        _drama('t|abc|u', '甜蜜暴击'),
        _drama('g|u|tag', '标签组'),
        _drama('shelltg|abc|u', '甜蜜暴击'),
        _drama('u|9', '甜蜜暴击 第1集', kind: 'folder', folderId: 'f1'),
        _drama('u|1', '甜蜜暴击 第1集'),
        _drama('u|2', '甜蜜暴击 第2集'),
      ];
      final grouped = tgGroupItems(items, isMovie: false);
      expect(grouped.map((d) => d.id).take(4).toList(), [
        't|abc|u',
        'g|u|tag',
        'shelltg|abc|u',
        'u|9',
      ]);
      expect(grouped.last.title, '甜蜜暴击');
      expect(grouped.last.episodes, 2);
    });

    test('group card sits at first member position', () {
      final items = [
        _drama('u|0', '头条 第1集'),
        _drama('u|1', '甜蜜暴击 第2集'),
        _drama('u|2', '中间 第1集'),
        _drama('u|3', '甜蜜暴击 第1集'),
        _drama('u|4', '尾巴 第1集'),
      ];
      final grouped = tgGroupItems(items, isMovie: false);
      expect(grouped.map((d) => d.title).toList(), [
        '头条 第1集',
        '甜蜜暴击',
        '中间 第1集',
        '尾巴 第1集',
      ]);
    });

    test('pic category skips grouping but still filters and dedupes', () {
      final items = [
        _drama('u|1', '甜蜜暴击 第1集', cover: 'https://x/1.jpg'),
        _drama('u|2', '甜蜜暴击 第2集', cover: 'https://x/1.jpg'),
        _drama('u|3', 'Hi VPN 广告帖', cover: 'https://x/3.jpg'),
        _drama('u|4', '甜蜜暴击 第1集', cover: 'https://x/1.jpg'),
      ];
      final page = tgPostProcessPage(
        _page(items),
        className: tgAllAmnsClass,
        category: 'pic',
      );
      // 去重后剩 u|1、u|2（同标题同封面的 u|4 被去重），不归拢。
      expect(page.items.map((d) => d.id), ['u|1', 'u|2']);
    });
  });

  group('group id codec', () {
    test('round-trip with CJK key and users', () {
      const key = '甜蜜暴击';
      const users = ['hbzh66', 'jav_all'];
      for (final id in [tgJarGroupId(key, users), tgShellGroupId(key, users)]) {
        expect(id.contains('='), isFalse);
        expect(id.contains('+'), isFalse);
        expect(id.contains('/'), isFalse);
        final ref = tgParseGroupId(id);
        expect(ref, isNotNull);
        expect(ref!.key, key);
        expect(ref.users, users);
      }
      expect(tgJarGroupId(key, users).startsWith('t|'), isTrue);
      expect(tgShellGroupId(key, users).startsWith('shelltg|'), isTrue);
    });

    test('invalid ids parse to null', () {
      expect(tgParseGroupId(''), isNull);
      expect(tgParseGroupId('u|123'), isNull);
      expect(tgParseGroupId('t|'), isNull);
      expect(tgParseGroupId('t|!!!|u'), isNull);
      expect(tgParseGroupId('g|u|tag'), isNull);
    });

    test('channel user extraction', () {
      expect(tgChannelUserOf('hbzh66|12345'), 'hbzh66');
      expect(tgChannelUserOf('p|hbzh66|12345'), 'hbzh66');
      expect(tgChannelUserOf('nobar'), '');
      expect(tgChannelUserOf('|123'), '');
    });
  });

  group('movie group detail synthesis', () {
    test('cache hit builds episodes in episode order', () async {
      final members = [
        _drama('u|2', '甜蜜暴击 第2集', source: 'jar:zakatv:ZakaTgMovie'),
        _drama('u|1', '甜蜜暴击 第1集', source: 'jar:zakatv:ZakaTgMovie'),
        _drama('u|3', '甜蜜暴击 EP03', source: 'jar:zakatv:ZakaTgMovie'),
      ];
      final grouped = tgGroupItems(members, isMovie: true);
      expect(grouped, hasLength(1));
      final card = grouped.first;
      var searched = 0;
      final detail = await tgSynthesizeMovieGroupDetail(
        drama: card,
        search: (_) async {
          searched++;
          return CatalogPage(const []);
        },
      );
      expect(searched, 0);
      expect(detail.drama.title, '甜蜜暴击');
      expect(detail.drama.heat, '3集');
      expect(detail.episodes.map((e) => e.title).toList(), [
        '第1集',
        '第2集',
        '第3集',
      ]);
      expect(detail.episodes.map((e) => e.raw['playId']).toList(), [
        'u|1',
        'u|2',
        'u|3',
      ]);
      expect(detail.episodes.map((e) => e.raw['flag']).toSet(), {'TG直连'});
      expect(detail.episodes.map((e) => e.number).toList(), [1, 2, 3]);
    });

    test('search fallback collects key-matched members only', () async {
      final card = _drama(
        tgShellGroupId('甜蜜暴击', ['u']),
        '甜蜜暴击',
        source: 'jar:zakatv:ZakaTgMovie',
      );
      // 搜索结果里混一张别组卡（缓存成员含同键与异键），验展开时逐条验键。
      final otherMembers = [
        _drama('u|9', '甜蜜暴击 第9集'),
        _drama('u|8', '甜蜜暴击番外 第1集'),
      ];
      final otherId = tgShellGroupId('甜蜜暴击番外', ['u']);
      TgGroupMembers.remember(otherId, otherMembers);
      final detail = await tgSynthesizeMovieGroupDetail(
        drama: card,
        search: (_) async => CatalogPage([
          _drama('u|2', '甜蜜暴击 第2集'),
          _drama(otherId, '甜蜜暴击番外'),
          _drama('u|1', '甜蜜暴击 第1集'),
          _drama('u|1', '甜蜜暴击 第1集'),
          _drama('u|7', '另一部片 第1集'),
        ]),
      );
      expect(detail.episodes.map((e) => e.raw['playId']).toList(), [
        'u|1',
        'u|2',
        'u|9',
      ]);
      // 回捞结果已记入缓存，下次直接命中。
      expect(TgGroupMembers.lookup(card.id), hasLength(3));
    });

    test('search fallback with no members throws honestly', () async {
      final card = _drama(
        tgShellGroupId('甜蜜暴击', ['u']),
        '甜蜜暴击',
        source: 'jar:zakatv:ZakaTgMovie',
      );
      await expectLater(
        tgSynthesizeMovieGroupDetail(
          drama: card,
          search: (_) async => CatalogPage(const []),
        ),
        throwsA(isA<TgGroupDetailFailure>()),
      );
    });

    test('non-shell id throws', () async {
      final card = _drama('u|1', '甜蜜暴击 第1集');
      await expectLater(
        tgSynthesizeMovieGroupDetail(
          drama: card,
          search: (_) async => CatalogPage(const []),
        ),
        throwsA(isA<TgGroupDetailFailure>()),
      );
    });
  });
}

class _ParityFixture {
  const _ParityFixture(this.title, this.key, this.epNo);

  final String title;
  final String key;
  final int epNo;
}
