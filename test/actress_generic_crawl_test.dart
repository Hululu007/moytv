// 任意站点现爬（2026-11-21 用户令「不管什么站点都可以爬取」）：
// 卡片聚类 / 翻页规律 / 详情字段 / 落盘管线，全部按实测页面口径验。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_generic_crawl.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_site_crawl.dart';
import 'package:moyi/content_http.dart';

import 'fixtures.dart';

/// 一页列表：卡片锚点 + 导航噪声 + 分页链接。
String listPage({required int page, required int count}) {
  final buffer = StringBuffer('<html><body>');
  buffer.write('<a href="/">首页</a><a href="/login">登录</a>');
  buffer.write('<div class="grid">');
  for (var i = 0; i < count; i++) {
    final n = (page - 1) * count + i + 1;
    final code = 'TEST-${n.toString().padLeft(3, '0')}';
    buffer.write(
      '<div class="card">'
      '<a href="/videos/test-$n" title="$code 标题$n">'
      '<img data-src="/img/$n.jpg" alt="$code 标题$n">'
      '</a></div>',
    );
  }
  buffer.write('</div>');
  buffer.write(
    '<div class="pager">'
    '<a href="/videos?page=${page + 1}" rel="next">下一页</a>'
    '</div>',
  );
  buffer.write('</body></html>');
  return buffer.toString();
}

String detailPage(int n) {
  final code = 'TEST-${n.toString().padLeft(3, '0')}';
  return '''
<html><head>
<meta property="og:image" content="https://cdn.site.com/cover/$n.jpg">
<meta name="description" content="这是第 $n 部作品的简介">
</head><body>
<h1>$code 标题$n</h1>
<p>演员：<a href="/actress/rui">明日花キララ</a>、<a href="/actress/mikami">三上悠亚</a></p>
<video controls src="https://cdn.site.com/media/$n.m3u8"></video>
</body></html>
''';
}

ContentResponse html(String body, {int status = 200}) => ContentResponse(
  statusCode: status,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  bodyBytes: Uint8List.fromList(utf8.encode(body)),
);

void main() {
  group('卡片解析', () {
    test('同一类详情链接聚成一簇，导航与登录链不进卡片', () {
      final cards = parseGenericCards(
        listPage(page: 1, count: 12),
        Uri.parse('https://site.com/videos'),
      );
      expect(cards.length, 12);
      expect(cards.first.title, 'TEST-001 标题1');
      expect(cards.first.url, 'https://site.com/videos/test-1');
      expect(cards.first.cover, 'https://site.com/img/1.jpg');
      expect(cards.first.code, 'TEST-001');
    });

    test('认不出列表（最大簇不足 3 张）时返回空，不造假卡片', () {
      final cards = parseGenericCards(
        '<html><body><a href="/about">关于</a>'
        '<a href="/v/1">一</a><a href="/v/2">二</a></body></html>',
        Uri.parse('https://site.com/'),
      );
      expect(cards, isEmpty);
    });
  });

  group('翻页识别', () {
    test('rel=next 直接给模板', () {
      final template = detectGenericPageTemplate(
        listPage(page: 1, count: 12),
        Uri.parse('https://site.com/videos'),
      );
      expect(template, 'https://site.com/videos?page={page}');
    });

    test('数字分页两个以上不同页码才认', () {
      final template = detectGenericPageTemplate(
        '<html><body><div class="pager">'
        '<a href="/list/2.html">2</a><a href="/list/3.html">3</a>'
        '</div></body></html>',
        Uri.parse('https://site.com/list/1.html'),
      );
      expect(template, 'https://site.com/list/{page}.html');
    });

    test('只有一个页码链接不认（避免把热链当分页）', () {
      final template = detectGenericPageTemplate(
        '<html><body><a href="/videos?page=2">下一页</a></body></html>'
        .replaceAll('下一页', '2'),
        Uri.parse('https://site.com/videos'),
      );
      expect(template, isNull);
    });
  });

  group('详情解析', () {
    test('演员多路抽取 + 直链 + 封面 + 番号', () {
      final detail = parseGenericDetail(
        detailPage(1),
        Uri.parse('https://site.com/videos/test-1'),
      );
      expect(detail.title, 'TEST-001 标题1');
      expect(detail.actor, contains('明日花キララ'));
      expect(detail.actor, contains('三上悠亚'));
      expect(detail.cover, 'https://cdn.site.com/cover/1.jpg');
      expect(detail.mediaUrl, 'https://cdn.site.com/media/1.m3u8');
      expect(detail.code, 'TEST-001');
    });

    test('只有播放页没有直链时，直链留空、播放页单独给出', () {
      final detail = parseGenericDetail(
        '<html><body><h1>ABP-123 标题</h1>'
        '<iframe src="https://player.site.com/embed/123"></iframe>'
        '</body></html>',
        Uri.parse('https://site.com/v/abp-123'),
      );
      expect(detail.mediaUrl, '');
      expect(detail.playPageUrl, 'https://player.site.com/embed/123');
    });

    test('盾页识别：小体积挑战页被认出', () {
      expect(
        looksLikeShieldBody(
          '<html><title>Just a moment...</title>'
          '<body>Checking your browser before accessing</body></html>',
        ),
        isTrue,
      );
      expect(
        looksLikeShieldBody('<html><body>' + '正常内容' * 4000 + '</body></html>'),
        isFalse,
      );
    });
  });

  group('MacCMS 采集接口', () {
    test('接口响应解析出女优名与播放地址', () {
      final body = jsonEncode({
        'code': 1,
        'list': [
          {
            'vod_id': 11,
            'vod_name': 'SSIS-001 标题',
            'vod_pic': '/pic/1.jpg',
            'vod_actor': '女优甲,女优乙',
            'vod_play_url': r'正片$https://cdn.site.com/a.m3u8',
            'vod_pubdate': '2026-01-02',
          },
        ],
      });
      final cards = parseMacCmsCards(body, 'https://site.com');
      expect(cards.length, 1);
      expect(cards.first.title, 'SSIS-001 标题');
      expect(cards.first.actor, '女优甲,女优乙');
      expect(cards.first.playUrl, 'https://cdn.site.com/a.m3u8');
      expect(cards.first.cover, 'https://site.com/pic/1.jpg');
      expect(cards.first.code, 'SSIS-001');
    });

    test('不是采集接口的响应不误认', () {
      expect(looksLikeMacCmsPayload('<html>404</html>'), isFalse);
      expect(looksLikeMacCmsPayload('{"code":0}'), isFalse);
    });
  });

  group('现爬落盘', () {
    late Directory temp;
    late MemoryActressDatabase db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync();
      db = MemoryActressDatabase();
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('两页列表 + 详情补全：条目进单文件 json、断点收尾、站身份固定', () async {
      final service = ActressSiteCrawlService(
        repository: FixtureRepository(),
        db: db,
        documentsDir: temp,
      );
      addTearDown(service.dispose);

      final crawler = GenericSiteCrawler(
        fetch: (url) async {
          if (url.contains('?page=2')) {
            return html(listPage(page: 2, count: 12));
          }
          if (url.contains('/videos/test-')) {
            final n = int.parse(RegExp(r'test-(\d+)').firstMatch(url)!.group(1)!);
            return html(detailPage(n));
          }
          if (url.endsWith('/api.php/provide/vod/?ac=list') ||
              url.contains('/api.php/provide/vod/')) {
            return html('<html>404</html>', status: 404);
          }
          return html(listPage(page: 1, count: 12));
        },
      );

      await service.startGenericSite(
        'https://site.com/videos',
        maxPages: 2,
        enrichPerPage: 24,
        crawler: crawler,
      );

      expect(service.current.error, '');
      expect(service.current.done, isTrue);
      expect(service.current.items, 24);
      expect(service.current.site, 'custom_site_com');

      final file = File('${temp.path}/actress_json/mjv011.json');
      expect(file.existsSync(), isTrue);
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final rows = (doc['list'] as List).cast<Map<String, dynamic>>();
      expect(rows.length, 24);
      expect(rows.every((r) => r['vod_play_from'] == 'custom_site_com'), isTrue);
      final first = rows.first;
      expect(first['vod_actor'], contains('明日花キララ'));
      expect(
        first['vod_play_url'],
        startsWith(r'正片$https://cdn.site.com/media/'),
      );
      expect(first['vod_code'], 'TEST-001');

      final checkpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'site_crawl_generic_custom_site_com',
      );
      expect(checkpoint, isNotNull);
      expect(checkpoint!.finished, isTrue);
      expect(checkpoint.total, 24);

      // 人进库：演员名按详情页抽到的两个人建。
      final overview = await db.overview();
      expect(overview.persons, greaterThanOrEqualTo(2));
    });

    test('认不出列表时报原因，不静默写空文件', () async {
      final service = ActressSiteCrawlService(
        repository: FixtureRepository(),
        db: db,
        documentsDir: temp,
      );
      addTearDown(service.dispose);

      final crawler = GenericSiteCrawler(
        fetch: (url) async => html(
          '<html><body><div id="app"></div>'
          '<script>window.__DATA__ = {}</script></body></html>',
        ),
      );

      await service.startGenericSite(
        'https://spa-site.com',
        crawler: crawler,
      );

      expect(service.current.error, contains('没从这个地址认出作品列表'));
      expect(service.current.items, 0);
      expect(
        File('${temp.path}/actress_json/mjv011.json').existsSync(),
        isFalse,
      );
    });

    test('撞盾报人话原因，不把挑战页当数据', () async {
      final service = ActressSiteCrawlService(
        repository: FixtureRepository(),
        db: db,
        documentsDir: temp,
      );
      addTearDown(service.dispose);

      final crawler = GenericSiteCrawler(
        fetch: (url) async => html(
          '<html><title>Just a moment...</title>'
          '<body>Checking your browser before accessing site.com</body></html>',
        ),
      );

      await service.startGenericSite(
        'https://shielded-site.com',
        crawler: crawler,
      );

      expect(service.current.error, contains('人机验证'));
      expect(service.current.items, 0);
    });
  });
}
