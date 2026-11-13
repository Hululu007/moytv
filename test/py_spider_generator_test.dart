import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/py_spider_generator.dart';
import 'package:moyi/url_site_probe.dart';
import 'package:moyi/web_scrape_analyzer.dart';

const _methods = <String>[
  'getName',
  'getDependence',
  'init',
  'destroy',
  'homeContent',
  'homeVideoContent',
  'categoryContent',
  'detailContent',
  'searchContent',
  'playerContent',
  'localProxy',
  'isVideoFormat',
  'manualVideoCheck',
  'action',
];

ScrapedSiteData htmlFixture({
  bool noCategories = false,
  bool noTemplate = false,
  bool noListItems = false,
  bool noDetailPattern = false,
  bool noDetailSample = false,
  bool noSearch = false,
  ScrapedDetailSample? detailSample,
  PlayChain? playChain,
  String? base,
  String? siteName,
}) {
  return ScrapedSiteData(
    inputUrl: 'https://example.com/',
    base: base ?? 'https://example.com',
    siteName: siteName ?? '测试影院',
    pageTitle: '测试影院 - 最新电影',
    categories: noCategories
        ? const []
        : const [
            ProbedCategory(
              id: '1',
              name: '电影',
              url: 'https://example.com/list/1-1.html',
            ),
            ProbedCategory(
              id: '2',
              name: '电视剧',
              url: 'https://example.com/list/2-1.html',
            ),
          ],
    categoryUrlTemplate: noTemplate
        ? null
        : 'https://example.com/list/{cateId}-{catePg}.html',
    hasPagination: true,
    searchUrl: noSearch ? null : 'https://example.com/search.html?wd={wd}',
    listItems: noListItems
        ? const []
        : const [
            ScrapedListItem(
              title: '影片甲',
              cover: 'https://example.com/c1.jpg',
              url: 'https://example.com/detail/1.html',
            ),
            ScrapedListItem(
              title: '影片乙',
              cover: 'https://example.com/c2.jpg',
              url: 'https://example.com/detail/2.html',
            ),
          ],
    detailHrefPattern: noDetailPattern ? null : r'/detail/\d+\.html',
    detailSample: noDetailSample
        ? null
        : detailSample ??
            const ScrapedDetailSample(
              title: '影片甲',
              description: '简介',
              cover: 'https://example.com/c1.jpg',
              mediaUrls: ['https://cdn.example.com/v1.m3u8'],
            ),
    playChain: playChain ?? PlayChain.directMedia,
  );
}

ScrapedSiteData macCmsFixture() {
  return const ScrapedSiteData(
    inputUrl: 'https://maccms.example/',
    base: 'https://maccms.example',
    siteName: '采集影院',
    isMacCMS: true,
  );
}

void expectNoComments(String source) {
  for (final line in source.split('\n')) {
    expect(
      line.trimLeft().startsWith('#'),
      isFalse,
      reason: '注释行：$line',
    );
  }
  expect(source.contains('"""'), isFalse);
  expect(source.contains("'''"), isFalse);
}

void expectAllMethods(String source) {
  for (final name in _methods) {
    expect(source, contains('def $name('), reason: '缺方法 $name');
  }
}

void main() {
  test('HTML 完整夹具：文件名、类、14 方法、分类来自夹具', () {
    final generated = generatePySpider(htmlFixture());
    expect(generated.fileName, 'example.py');
    expect(generated.key, 'example');
    expect(generated.source, contains('class Spider(BaseSpider)'));
    expectAllMethods(generated.source);
    expect(generated.source, contains('电影'));
    expect(generated.source, contains('电视剧'));
    expect(
      generated.source,
      contains('https://example.com/list/{cateId}-{catePg}.html'),
    );
    expect(
      generated.source,
      contains('https://example.com/search.html?wd={wd}'),
    );
    expect(generated.source, contains('测试影院'));
  });

  test('HTML 完整夹具：零中文注释、dict 头、parse 0、urllib 保底', () {
    final generated = generatePySpider(htmlFixture());
    expectNoComments(generated.source);
    expect(
      generated.source,
      contains("header = {'User-Agent': UA, 'Referer': BASE + '/'}"),
    );
    expect(generated.source, contains("'parse': 0"));
    expect(generated.source, contains('urllib.request.urlopen'));
    expect(generated.source, contains('import requests'));
    expect(generated.source, contains('from base.spider import BaseSpider'));
  });

  test('MacCMS 夹具：走采集接口、14 方法、零注释', () {
    final generated = generatePySpider(macCmsFixture());
    expect(generated.fileName, 'maccms.py');
    expect(generated.source, contains('class Spider(BaseSpider)'));
    expectAllMethods(generated.source);
    expectNoComments(generated.source);
    expect(generated.source, contains('api.php/provide/vod'));
    expect(generated.source, contains('采集影院'));
  });

  test('播放页链路夹具：生成播放页解析代码', () {
    final generated = generatePySpider(
      htmlFixture(
        playChain: PlayChain.viaPlayPage,
        detailSample: const ScrapedDetailSample(
          title: '影片甲',
          description: '简介',
          cover: 'https://example.com/c1.jpg',
          playHrefPattern: r'/play/\d+-\d+\.html',
        ),
      ),
    );
    expect(generated.source, contains('_parse_play_links'));
    // 生成的 Python 字面量里正则反斜杠是转义后的双份，运行时求值为 \d+。
    expect(generated.source, contains(r'/play/\\d+-\\d+\\.html'));
    expectAllMethods(generated.source);
    expectNoComments(generated.source);
  });

  test('无搜索地址：searchContent 返回空列表，不编搜索规则', () {
    final generated = generatePySpider(htmlFixture(noSearch: true));
    expect(generated.source, contains('SEARCH_URL = ""'));
    expect(generated.source, contains('def searchContent'));
    expect(generated.source, isNot(contains('SEARCH_URL.replace')));
  });

  test('数据不足：分类不足时报错且无输出', () {
    final data = htmlFixture(noCategories: true);
    expect(generationBlockers(data), isNotEmpty);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('分类不足'),
        ),
      ),
    );
  });

  test('数据不足：无分类模板时报错', () {
    final data = htmlFixture(noTemplate: true);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('分类地址模板'),
        ),
      ),
    );
  });

  test('数据不足：无列表项时报错', () {
    final data = htmlFixture(noListItems: true);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('列表项'),
        ),
      ),
    );
  });

  test('数据不足：无详情链接规律时报错', () {
    final data = htmlFixture(noDetailPattern: true);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('详情链接规律'),
        ),
      ),
    );
  });

  test('数据不足：无详情示例时报错', () {
    final data = htmlFixture(noDetailSample: true);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('详情页示例'),
        ),
      ),
    );
  });

  test('数据不足：无播放链时报错', () {
    final data = htmlFixture(playChain: PlayChain.none);
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('可播放地址'),
        ),
      ),
    );
  });

  test('数据不足：播放页链路无播放页规律时报错', () {
    final data = htmlFixture(
      playChain: PlayChain.viaPlayPage,
      detailSample: const ScrapedDetailSample(
        title: '影片甲',
        description: '简介',
        cover: 'https://example.com/c1.jpg',
      ),
    );
    expect(
      () => generatePySpider(data),
      throwsA(
        isA<PyGeneratorException>().having(
          (e) => e.reasons.join('\n'),
          'reasons',
          contains('播放页链接规律'),
        ),
      ),
    );
  });

  test('数据不足：多项缺失时一次列全', () {
    final data = htmlFixture(
      noCategories: true,
      noTemplate: true,
      noListItems: true,
      noDetailPattern: true,
      noDetailSample: true,
      playChain: PlayChain.none,
    );
    final blockers = generationBlockers(data);
    expect(blockers.length, greaterThanOrEqualTo(5));
    expect(
      () => generatePySpider(data),
      throwsA(isA<PyGeneratorException>()),
    );
  });

  test('站点 key 推导：www/数字开头/非法字符', () {
    expect(pyKeyForSite('https://example.com'), 'example');
    expect(pyKeyForSite('https://www.foo-bar.com/'), 'foobar');
    expect(pyKeyForSite('https://123.example.com'), 'site_123');
    expect(pyKeyForSite('not a url'), isNull);
    expect(pyKeyForSite(''), isNull);
  });
}
