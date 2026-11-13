import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/nexhub_scraper/scraper/web_scrape_service.dart';
import 'package:moyi/py_spider_generator.dart';
import 'package:moyi/url_site_probe.dart';
import 'package:moyi/web_scrape_analyzer.dart';

ContentResponse _resp(String body, {int status = 200}) => ContentResponse(
  statusCode: status,
  headers: const {'content-type': 'text/html; charset=utf-8'},
  bodyBytes: utf8.encode(body),
);

const _homeHtml = '''
<html><head><title>测试影院 - 最新电影在线观看</title>
<meta property="og:site_name" content="测试影院">
</head><body>
<nav class="nav">
<a href="/">首页</a>
<a href="/list/1-1.html">电影</a>
<a href="/list/2-1.html">电视剧</a>
<a href="/list/3-1.html">综艺</a>
<a href="/login.html">登录</a>
</nav>
<form action="/search.html" method="get"><input type="text" name="wd"></form>
<div class="list">
<a href="/detail/1.html"><img src="/c1.jpg">影片甲</a>
<a href="/detail/2.html"><img src="/c2.jpg">影片乙</a>
</div>
</body></html>
''';

const _categoryHtml = '''
<html><head><title>电影</title></head><body>
<div class="list">
<a href="/detail/1.html"><img src="/c1.jpg">影片甲</a>
<a href="/detail/2.html"><img src="/c2.jpg">影片乙</a>
<a href="/detail/3.html"><img src="/c3.jpg">影片丙</a>
</div>
<div class="pages"><a href="/list/1-2.html">下一页</a></div>
</body></html>
''';

const _detailDirectHtml = '''
<html><head><title>影片甲 - 测试影院</title>
<meta name="description" content="影片甲简介">
<meta property="og:image" content="https://example.com/poster1.jpg">
</head><body>
<h1>影片甲</h1>
<video src="https://cdn.example.com/v1.m3u8"></video>
</body></html>
''';

const _detailPlayHtml = '''
<html><head><title>影片甲 - 测试影院</title>
<meta name="description" content="影片甲简介">
</head><body>
<h1>影片甲</h1>
<div class="eps">
<a href="/play/1-1.html">第1集</a>
<a href="/play/1-2.html">第2集</a>
<a href="/play/1-3.html">第3集</a>
</div>
<div class="rel"><a href="/detail/2.html">影片乙</a></div>
</body></html>
''';

const _noCategoryHtml = '''
<html><head><title>只有首页的站</title></head><body>
<nav><a href="/">首页</a><a href="/about.html">关于我们</a></nav>
<p>hello</p>
</body></html>
''';

const _emptyHtml =
    '<html><head><title>空</title></head><body></body></html>';

const _macListJson =
    '{"code":1,"list":['
    '{"vod_id":11,"vod_name":"剧甲","vod_pic":"https://m.example/c1.jpg","vod_remarks":"完结"},'
    '{"vod_id":12,"vod_name":"剧乙","vod_pic":"https://m.example/c2.jpg","vod_remarks":"更新中"}],'
    '"class":[{"type_id":1,"type_name":"电影"}]}';

const _macDetailJson =
    '{"code":1,"list":[{'
    '"vod_id":11,"vod_name":"剧甲","vod_pic":"https://m.example/c1.jpg",'
    '"vod_content":"剧甲简介","vod_play_from":"在线播放",'
    '"vod_play_url":"第1集\$https://cdn.example.com/1.m3u8#第2集\$https://cdn.example.com/2.m3u8"}]}';

WebScrapeAnalyzer _analyzerWith(Map<String, ContentResponse> pages) {
  Future<ContentResponse> fetch(String url) async {
    final hit = pages[url];
    if (hit != null) return hit;
    return _resp('not found', status: 404);
  }

  return WebScrapeAnalyzer(
    fetchHtml: fetch,
    scrapeService: WebScrapeService.forTest(fetch),
    probe: UrlSiteProbe(fetchHtml: fetch),
  );
}

Map<String, ContentResponse> _htmlPages({String detailHtml = _detailDirectHtml}) {
  return {
    'https://example.com/': _resp(_homeHtml),
    'https://example.com': _resp(_homeHtml),
    'https://example.com/api.php/provide/vod/?ac=list&pg=1': _resp(
      'nope',
      status: 404,
    ),
    'https://example.com/list/1-1.html': _resp(_categoryHtml),
    'https://example.com/detail/1.html': _resp(detailHtml),
  };
}

void main() {
  test('HTML 正常路径：分类/模板/列表/详情/直链全部采到，可生成', () async {
    final analyzer = _analyzerWith(_htmlPages());
    final data = await analyzer.analyze('https://example.com/');
    expect(data.siteName, '测试影院');
    expect(data.base, 'https://example.com');
    expect(data.isMacCMS, isFalse);
    expect(data.categories.map((c) => c.id), ['1', '2', '3']);
    expect(data.categories.map((c) => c.name), ['电影', '电视剧', '综艺']);
    expect(
      data.categoryUrlTemplate,
      'https://example.com/list/{cateId}-{catePg}.html',
    );
    expect(data.hasPagination, isTrue);
    expect(data.searchUrl, 'https://example.com/search.html?wd={wd}');
    expect(data.listItems.map((e) => e.title), ['影片甲', '影片乙', '影片丙']);
    expect(data.detailHrefPattern, r'/detail/\d+\.html');
    expect(data.detailSample, isNotNull);
    expect(data.detailSample!.title, '影片甲');
    expect(data.detailSample!.description, '影片甲简介');
    expect(
      data.detailSample!.cover,
      'https://example.com/poster1.jpg',
    );
    expect(
      data.detailSample!.mediaUrls,
      ['https://cdn.example.com/v1.m3u8'],
    );
    expect(data.playChain, PlayChain.directMedia);
    expect(data.structureError, isNull);
    expect(generationBlockers(data), isEmpty);
  });

  test('播放页链路：详情页无直链、有播放页链接时归纳出播放规律', () async {
    final analyzer = _analyzerWith(_htmlPages(detailHtml: _detailPlayHtml));
    final data = await analyzer.analyze('https://example.com/');
    expect(data.playChain, PlayChain.viaPlayPage);
    expect(data.detailSample, isNotNull);
    expect(data.detailSample!.playHrefPattern, r'/play/1-\d+\.html');
    expect(data.detailSample!.playLinks.length, 3);
    expect(generationBlockers(data), isEmpty);
  });

  test('验证页不绕过：403 直接报错', () async {
    final analyzer = _analyzerWith({
      'https://shield.example/': _resp('forbidden', status: 403),
    });
    expect(
      () => analyzer.analyze('https://shield.example/'),
      throwsA(
        isA<ScrapeFailure>().having(
          (e) => e.message,
          'message',
          contains('验证页'),
        ),
      ),
    );
  });

  test('验证页不绕过：200 挑战页含 Just a moment 也报错', () async {
    final analyzer = _analyzerWith({
      'https://shield2.example/': _resp(
        '<html><head><title>Just a moment...</title></head><body>checking</body></html>',
      ),
    });
    expect(
      () => analyzer.analyze('https://shield2.example/'),
      throwsA(isA<ScrapeFailure>()),
    );
  });

  test('空数据：仅有标题的页面返回部分数据并记下原因，生成被拦住', () async {
    final analyzer = _analyzerWith({
      'https://empty.example/': _resp(_emptyHtml),
    });
    final data = await analyzer.analyze('https://empty.example/');
    expect(data.structureError, isNotNull);
    expect(data.links, isEmpty);
    expect(data.categories, isEmpty);
    expect(data.listItems, isEmpty);
    expect(generationBlockers(data), isNotEmpty);
  });

  test('结构失败但有链接：返回部分数据并记下原因，生成被拦住', () async {
    final analyzer = _analyzerWith({
      'https://plain.example/': _resp(_noCategoryHtml),
      'https://plain.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        'nope',
        status: 404,
      ),
    });
    final data = await analyzer.analyze('https://plain.example/');
    expect(data.structureError, isNotNull);
    expect(data.links, isNotEmpty);
    expect(data.categories, isEmpty);
    expect(generationBlockers(data), isNotEmpty);
  });

  test('MacCMS 路径：接口列表与详情采样，分类由接口运行时给出', () async {
    final analyzer = _analyzerWith({
      'https://m.example/': _resp(
        '<html><head><title>采集影院</title></head><body><p>hi</p></body></html>',
      ),
      'https://m.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        _macListJson,
      ),
      'https://m.example/api.php/provide/vod/?ac=detail&ids=11': _resp(
        _macDetailJson,
      ),
    });
    final data = await analyzer.analyze('https://m.example/');
    expect(data.isMacCMS, isTrue);
    expect(data.siteName, '采集影院');
    expect(data.listItems.map((e) => e.title), ['剧甲', '剧乙']);
    expect(data.detailSample, isNotNull);
    expect(data.detailSample!.title, '剧甲');
    expect(data.detailSample!.description, '剧甲简介');
    expect(data.playChain, PlayChain.directMedia);
    expect(generationBlockers(data), isEmpty);
  });

  test('网址归一化：缺协议补 https、空输入与非法协议报错', () async {
    final analyzer = _analyzerWith(_htmlPages());
    final data = await analyzer.analyze('example.com');
    expect(data.inputUrl, 'https://example.com');
    expect(data.base, 'https://example.com');
    expect(
      () => analyzer.analyze(''),
      throwsA(
        isA<ScrapeFailure>().having(
          (e) => e.message,
          'message',
          contains('请输入网址'),
        ),
      ),
    );
    expect(
      () => analyzer.analyze('ftp://example.com/'),
      throwsA(isA<ScrapeFailure>()),
    );
  });

  test('javmenu 真页：根级番号链 + 分离式卡片 + 原文直链，可生成', () async {
    final home = File('test/fixtures/javmenu_home.html').readAsStringSync();
    final censored =
        File('test/fixtures/javmenu_censored.html').readAsStringSync();
    final detail =
        File('test/fixtures/javmenu_detail.html').readAsStringSync();
    Future<ContentResponse> fetch(String url) async {
      if (url == 'https://javmenu.com/' || url == 'https://javmenu.com') {
        return _resp(home);
      }
      if (url.startsWith('https://javmenu.com/api.php/')) {
        return _resp('nope', status: 404);
      }
      final segments = Uri.parse(url).pathSegments;
      // 详情链：单段且含连字符（如 /START-094）；其余同站地址按分类页处理。
      if (segments.length == 1 && segments.first.contains('-')) {
        return _resp(detail);
      }
      return _resp(censored);
    }

    final analyzer = WebScrapeAnalyzer(
      fetchHtml: fetch,
      scrapeService: WebScrapeService.forTest(fetch),
      probe: UrlSiteProbe(fetchHtml: fetch),
    );
    final data = await analyzer.analyze('https://javmenu.com/');
    expect(data.siteName, 'JAV目錄大全');
    expect(data.categories.length, greaterThanOrEqualTo(2));
    expect(data.categoryUrlTemplate, 'https://javmenu.com/{cateId}');
    expect(data.searchUrl, 'https://javmenu.com/search?wd={wd}');
    expect(data.listItems.length, greaterThanOrEqualTo(2));
    expect(
      data.listItems.every(
        (e) => e.title.isNotEmpty && e.url.contains('javmenu.com/'),
      ),
      isTrue,
    );
    expect(data.detailHrefPattern, isNotNull);
    final hrefPattern = RegExp(data.detailHrefPattern!);
    expect(hrefPattern.hasMatch('/START-094'), isTrue);
    expect(hrefPattern.hasMatch('/DLDSS-121'), isTrue);
    expect(hrefPattern.hasMatch('/censored/online'), isFalse);
    expect(data.detailSample, isNotNull);
    expect(data.detailSample!.mediaUrls, isNotEmpty);
    expect(data.detailSample!.mediaUrls.first, contains('.m3u8'));
    expect(data.playChain, PlayChain.directMedia);
    expect(generationBlockers(data), isEmpty);
  });
}
