// 演员库六源扩线测试（2026-11-26）：
// - AV01/Jable 解析层照 AvPlay 反编译（Av01Parser/JableParser）
//   的真形状造夹具验真；
// - py 复用四源（AVDB/JavMenu/MemoJav/MissAV）走仓库
//   search→detail→resolve 链的命中/未命中/解析型剔除；
// - 线路区：py 行（仓库在场才出现）、懒查询行点按才查。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_online_lines.dart';
import 'package:moyi/actress/actress_online_parse.dart';
import 'package:moyi/actress/actress_online_sources.dart';
import 'package:moyi/actress/actress_py_lines.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

class _PyFakeRepository extends FixtureRepository {
  final searchCalls = <String>[];
  var planNeedsParse = false;
  var planUrl = 'https://cdn.example.com/movie.m3u8';

  @override
  Future<CatalogPage> searchProgress(String source, String query) async {
    searchCalls.add(source);
    if (source == 'avdb' && query.contains('SSIS-001')) {
      return CatalogPage(const [
        Drama(id: '12345', source: 'avdb', title: 'SSIS-001 示例标题'),
        Drama(id: '999', source: 'avdb', title: 'ABF-999 别的片'),
      ]);
    }
    return CatalogPage(const []);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    return DramaDetail(drama, [
      Episode({'id': '${drama.source}:play-id', 'title': '正片'}, 1),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    bool adBlock = true,
    int quality = 0,
    int route = 0,
  }) async {
    return PlaybackPlan(
      url: planUrl,
      headers: const {'Referer': 'https://example.com/'},
      needsParse: planNeedsParse,
    );
  }
}

void main() {
  group('AV01 解析（Av01Parser 移植）', () {
    const searchHtml = '''
<a href="/cn/video/12345/ssis-001">一</a>
<a href="/cn/video/12346/ssis-001-uncensored">二</a>
<a href="/cn/video/12347/ssis-002">三</a>
<a href="https://www.av01.media/cn/video/12345/ssis-001">重复</a>
<a href="/cn/video/abc/ssis-001">无数字 id</a>
''';

    test('搜索页：slug 相等与带后缀命中、无关与无 id 剔除、去重', () {
      final cards = parseAv01SearchCards(searchHtml, 'SSIS-001');
      expect(cards, hasLength(2));
      expect(cards[0].pageUrl, 'https://www.av01.media/cn/video/12345/ssis-001');
      expect(
        cards[1].pageUrl,
        'https://www.av01.media/cn/video/12346/ssis-001-uncensored',
      );
    });

    test('slug 规整与番号归一', () {
      expect(av01SlugForm(' SSIS_001 '), 'ssis-001');
      expect(av01SlugForm('ssis--001'), 'ssis-001');
      expect(av01NormalizeCode('SSIS-001 标题'), 'ssis001');
      expect(av01VideoIdOf('https://www.av01.media/cn/video/777/x'), 777);
      expect(av01VideoIdOf('https://www.av01.media/cn/search?q=x'), isNull);
    });

    const detailHtml = '''
<link rel="canonical" href="https://www.av01.media/cn/video/12345/ssis-001">
<h1>SSIS-001 示例标题</h1>
<video>
<source src="/api/v1/videos/99999/manifest/master.m3u8">
<source src="/api/v1/videos/12345/manifest/master.m3u8?token=abc">
</video>
''';
    const pageUrl = 'https://www.av01.media/cn/video/12345/ssis-001';

    test('详情页：三关校验过、取本片主清单（带 token 查询串）', () {
      final parsed = parseAv01DetailManifest(detailHtml, pageUrl);
      expect(parsed, isNotNull);
      expect(parsed!.title, 'SSIS-001 示例标题');
      expect(
        parsed.manifest,
        'https://www.av01.media/api/v1/videos/12345/manifest/master.m3u8?token=abc',
      );
    });

    test('详情页：canonical id 对不上回 null', () {
      final html = detailHtml.replaceAll(
        'video/12345/ssis-001',
        'video/54321/ssis-001',
      );
      expect(parseAv01DetailManifest(html, pageUrl), isNull);
    });

    test('详情页：h1 不是这部片回 null', () {
      final html = detailHtml.replaceAll('SSIS-001 示例标题', 'ABF-999 别的片');
      expect(parseAv01DetailManifest(html, pageUrl), isNull);
    });

    test('详情页：没有主清单回 null', () {
      const html = '''
<link rel="canonical" href="https://www.av01.media/cn/video/12345/ssis-001">
<h1>SSIS-001 示例标题</h1>
<video><source src="/files/preview.mp4"></video>
''';
      expect(parseAv01DetailManifest(html, pageUrl), isNull);
    });
  });

  group('Jable 解析（JableParser 移植）', () {
    const searchHtml = '''
<a href="https://jable.tv/videos/ssis-001/">一</a>
<a href="/videos/SSIS-001/">重复</a>
<a href="/videos/ssis-0012/">近似不算</a>
<a href="/videos/abf-999/">别的片</a>
''';

    test('搜索页：slug 与番号相等才认、去重、地址统一拼', () {
      final cards = parseJableSearchCards(searchHtml, 'ssis-001');
      expect(cards, hasLength(1));
      expect(cards.single.pageUrl, 'https://jable.tv/videos/ssis-001/');
    });

    test('详情页取流：hlsUrl 转义形解出、只认 https m3u8', () {
      expect(
        extractJableHls(
          r"var hlsUrl = 'https:\/\/cdn.example.com\/abc\/index.m3u8';",
        ),
        'https://cdn.example.com/abc/index.m3u8',
      );
      expect(
        extractJableHls('var hlsUrl = "http://cdn.example.com/x.m3u8";'),
        '',
      );
      expect(extractJableHls('<html>没有</html>'), '');
    });

    test('盾页特征识别', () {
      expect(
        actressPageLooksChallenged('<title>Just a moment...</title>'),
        isTrue,
      );
      expect(actressPageLooksChallenged('<html>正常页</html>'), isFalse);
    });
  });

  group('AV01/Jable 源（假取数）', () {
    test('Jable 默认懒查询、AV01 不懒', () {
      expect(const JableActressSource().lazySearch, isTrue);
      expect(const Av01ActressSource().lazySearch, isFalse);
    });

    test('Jable 撞盾页抛失败（不冒充未找到）', () async {
      Future<String> fetch(String url, Map<String, String> headers) async =>
          '<title>Just a moment...</title>';
      expect(
        () => const JableActressSource().fetchCards(
          primaryId: 'search',
          secondaryId: '',
          query: 'SSIS-001',
          page: 1,
          fetch: fetch,
        ),
        throwsA(isA<AppFailure>()),
      );
    });

    test('Jable 取流：详情页 hlsUrl 成播放地址', () async {
      Future<String> fetch(String url, Map<String, String> headers) async =>
          r"var hlsUrl = 'https:\/\/cdn.example.com\/abc\/index.m3u8';";
      final play = await const JableActressSource().resolvePlay(
        const OnlineVideoCard(
          pageUrl: 'https://jable.tv/videos/ssis-001/',
          title: 'SSIS-001',
        ),
        fetch: fetch,
      );
      expect(play.streamUrl, 'https://cdn.example.com/abc/index.m3u8');
    });

    test('AV01 取流：搜索→详情校验→主清单', () async {
      Future<String> fetch(String url, Map<String, String> headers) async {
        if (url.contains('/search?')) {
          return '<a href="/cn/video/12345/ssis-001">一</a>';
        }
        if (url.contains('geo.js')) {
          return '{"token_v2":"t","ttl":600}';
        }
        return '''
<link rel="canonical" href="https://www.av01.media/cn/video/12345/ssis-001">
<h1>SSIS-001 示例标题</h1>
<source src="/api/v1/videos/12345/manifest/master.m3u8">
''';
      }

      const source = Av01ActressSource();
      final cards = await source.fetchCards(
        primaryId: 'search',
        secondaryId: '',
        query: 'SSIS-001',
        page: 1,
        fetch: fetch,
      );
      expect(cards, hasLength(1));
      final play = await source.resolvePlay(cards.single, fetch: fetch);
      expect(
        play.streamUrl,
        'https://www.av01.media/api/v1/videos/12345/manifest/master.m3u8',
      );
    });
  });

  group('py 复用链（假仓库）', () {
    test('AVDB：搜索命中→详情→直链计划成线路', () async {
      final repo = _PyFakeRepository();
      final hit = await actressPyLineHit(
        repository: repo,
        sourceId: 'avdb',
        code: 'SSIS-001',
      );
      expect(hit, isNotNull);
      expect(hit!.plan.url, 'https://cdn.example.com/movie.m3u8');
      final detail = actressPyLineDetail(
        source: kActressPyLineSources.first,
        code: 'SSIS-001',
        hit: hit,
      );
      expect(detail.episodes.single.id, 'https://cdn.example.com/movie.m3u8');
    });

    test('AVDB：搜索只有别的片回 null（不拿别片充数）', () async {
      final repo = _PyFakeRepository();
      final hit = await actressPyLineHit(
        repository: repo,
        sourceId: 'avdb',
        code: 'ABF-000',
      );
      expect(hit, isNull);
    });

    test('解析型计划不算线路', () async {
      final repo = _PyFakeRepository()..planNeedsParse = true;
      final hit = await actressPyLineHit(
        repository: repo,
        sourceId: 'avdb',
        code: 'SSIS-001',
      );
      expect(hit, isNull);
    });

    test('MissAV：按番号直达详情、不走搜索', () async {
      final repo = _PyFakeRepository();
      final hit = await actressPyLineHit(
        repository: repo,
        sourceId: 'missav',
        code: 'SSIS-001',
      );
      expect(hit, isNotNull);
      expect(repo.searchCalls, isEmpty);
    });
  });

  group('线路区（py 行 + 懒查询）', () {
    Future<String> failingFetch(
      String url,
      Map<String, String> headers,
    ) async => throw AppFailure('合成失败');

    testWidgets('仓库在场：py 行出现，AVDB 自动查到、MissAV 懒查询点后才查', (
      tester,
    ) async {
      final repo = _PyFakeRepository();
      DramaDetail? played;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressOnlineLinesSection(
              code: 'SSIS-001',
              onPlay: (detail) => played = detail,
              fetch: failingFetch,
              sources: const [],
              repository: repo,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      // AVDB 自动查（py 链命中）；MissAV 懒查询还停在「点击查询」。
      expect(find.text('AVDB'), findsOneWidget);
      expect(find.text('已找到 · 点播'), findsOneWidget);
      expect(find.text('点击查询'), findsOneWidget);
      expect(repo.searchCalls, contains('avdb'));
      // 点 MissAV 行才查（按番号直达，查到后变已找到）。
      await tester.tap(
        find.byKey(const ValueKey('actress-online-line-missav')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('点击查询'), findsNothing);
      // 点 AVDB 行直接出预组装的直链详情。
      await tester.tap(find.byKey(const ValueKey('actress-online-line-avdb')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(played, isNotNull);
      expect(
        played!.episodes.single.id,
        'https://cdn.example.com/movie.m3u8',
      );
    });

    testWidgets('没传仓库：py 行不出现（与扩线前行为一致）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressOnlineLinesSection(
              code: 'SSIS-001',
              onPlay: (_) {},
              fetch: failingFetch,
              sources: const [],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('AVDB'), findsNothing);
      expect(find.text('MissAV'), findsNothing);
    });
  });
}
