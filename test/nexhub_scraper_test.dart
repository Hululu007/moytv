import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/nexhub_scraper/network/model/effective_network_profile.dart';
import 'package:moyi/nexhub_scraper/network/model/network_config.dart';
import 'package:moyi/nexhub_scraper/network/model/source_network_config.dart';
import 'package:moyi/nexhub_scraper/network/network_config_service.dart';
import 'package:moyi/nexhub_scraper/network/runtime/network_client_builder.dart';
import 'package:moyi/nexhub_scraper/network/runtime/sni_policy.dart';
import 'package:moyi/nexhub_scraper/network/runtime/system_proxy_resolver.dart';
import 'package:moyi/nexhub_scraper/network/source_network_override_store.dart';
import 'package:moyi/nexhub_scraper/resolver/image_extractor.dart';
import 'package:moyi/nexhub_scraper/resolver/m3u8_ad_filter.dart';
import 'package:moyi/nexhub_scraper/resolver/m3u8_parser.dart';
import 'package:moyi/nexhub_scraper/resolver/parse_diagnostics.dart';
import 'package:moyi/nexhub_scraper/resolver/video_extractor.dart';
import 'package:moyi/nexhub_scraper/scraper/cookie_store.dart';
import 'package:moyi/nexhub_scraper/scraper/verification_detector.dart';
import 'package:moyi/nexhub_scraper/scraper/web_scrape_service.dart';
import 'package:moyi/nexhub_scraper/utils/html_utils.dart';
import 'package:moyi/nexhub_scraper/utils/json_path.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VerificationDetector', () {
    test('403 一律判验证', () {
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 403,
          body: 'forbidden',
        ),
        isTrue,
      );
    });

    test('200 挑战页命中主动标记判验证', () {
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: '<html><title>Just a moment...</title></html>',
        ),
        isTrue,
      );
    });

    test('正常大内容页放行', () {
      final body = '<html><body>${'<p>正文内容</p>' * 200}</body></html>';
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: body,
        ),
        isFalse,
      );
    });

    test('Edge IP Restricted 可区分', () {
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 403,
          body: 'Error code: 1034 Edge IP Restricted',
        ),
        isTrue,
      );
      expect(
        VerificationDetector.isEdgeIpRestricted(
          statusCode: 200,
          body: 'Error code: 1034',
        ),
        isFalse,
      );
    });

    test('WAF 拦截词整段匹配', () {
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: 'closed',
        ),
        isTrue,
      );
      expect(
        VerificationDetector.isVerificationRequired(
          statusCode: 200,
          body: '<html><body><p>the shop is closed today</p></body></html>',
        ),
        isFalse,
      );
    });
  });

  group('HtmlUtils（CSS 可用，XPath 明确抛错）', () {
    const html =
        '<html><head><title>标题</title></head><body>'
        '<div class="item"><a href="/a">甲</a></div>'
        '<div class="item"><a href="/b">乙</a></div>'
        '<p>段落一</p><p>段落二</p></body></html>';

    test('CSS 查询', () {
      expect(HtmlUtils.query(html, 'title'), '标题');
      expect(HtmlUtils.queryAll(html, 'p'), ['段落一', '段落二']);
      expect(HtmlUtils.elements(html, 'div.item').length, 2);
      expect(HtmlUtils.queryAttr(html, 'a', 'href'), '/a');
      expect(HtmlUtils.queryAttrExpr(html, 'a@href'), '/a');
      expect(HtmlUtils.queryHtml(html, 'div.item'), contains('<a href="/a">甲</a>'));
    });

    test('clean 去掉脚本与注释', () {
      const dirty =
          '<html><body><script>var x=1;</script><!-- 注 --><p>留</p></body></html>';
      final cleaned = HtmlUtils.clean(dirty);
      expect(cleaned, contains('留'));
      expect(cleaned, isNot(contains('var x')));
      expect(cleaned, isNot(contains('注')));
    });

    test('XPath 选择器抛 UnsupportedError 而非静默空结果', () {
      expect(() => HtmlUtils.query(html, '//div[@class="item"]'), throwsUnsupportedError);
      expect(() => HtmlUtils.elements(html, '//a'), throwsUnsupportedError);
      expect(HtmlUtils.isXPath('//div'), isTrue);
      expect(HtmlUtils.isXPath('div.item'), isFalse);
      expect(HtmlUtils.isXPath('div[@class="x"]'), isTrue);
    });
  });

  group('M3u8 解析与去广告', () {
    const playlist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-KEY:METHOD=AES-128,URI="https://key.example/k.key"
#EXTINF:2.0,
https://ad.example/ad1.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://cdn.example/s1.ts
#EXTINF:10.0,
https://cdn.example/s2.ts
#EXTINF:10.0,
https://cdn.example/s3.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://ad.example/ad2.ts
#EXT-X-ENDLIST
''';

    test('解析出全部 5 个分片', () {
      final result = M3u8Parser.parse(playlist);
      expect(result.isMedia, isTrue);
      expect(result.segments.length, 5);
      expect(result.segments.first.url, contains('ad1.ts'));
    });

    test('去广告：头尾短组去掉、正片与组内 KEY 行保留', () {
      const keyed = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:2.0,
https://ad.example/ad1.ts
#EXT-X-DISCONTINUITY
#EXT-X-KEY:METHOD=AES-128,URI="https://key.example/k.key"
#EXTINF:10.0,
https://cdn.example/s1.ts
#EXTINF:10.0,
https://cdn.example/s2.ts
#EXTINF:10.0,
https://cdn.example/s3.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://ad.example/ad2.ts
#EXT-X-ENDLIST
''';
      final filtered = M3u8AdFilter.filter(keyed);
      expect(filtered, isNot(contains('ad1.ts')));
      expect(filtered, isNot(contains('ad2.ts')));
      expect(filtered, contains('s1.ts'));
      expect(filtered, contains('s2.ts'));
      expect(filtered, contains('s3.ts'));
      expect(filtered, contains('#EXT-X-KEY'));
    });

    test('上游行为：头部位置的 KEY 行随首组丢弃（调用方须知）', () {
      // KEY 行在第一个分片之前时，NexHub 原文的 _writeHeader 只保留
      // TARGETDURATION/VERSION 等标签，KEY 行不保留。此测试锁定该行为，
      // 提醒调用方：加密清单不要直接用本过滤器处理头部 KEY 行。
      final filtered = M3u8AdFilter.filter(playlist);
      expect(filtered, isNot(contains('#EXT-X-KEY')));
      expect(filtered, contains('s1.ts'));
    });

    test('无 discontinuity 的清单内容不变（仅格式重整）', () {
      const plain =
          '#EXTM3U\n#EXTINF:10.0,\nhttps://cdn.example/s1.ts\n#EXT-X-ENDLIST\n';
      final filtered = M3u8AdFilter.filter(plain);
      expect(filtered, startsWith('#EXTM3U'));
      expect(filtered, contains('https://cdn.example/s1.ts'));
      expect(filtered, contains('#EXT-X-ENDLIST'));
    });
  });

  group('提取器', () {
    test('VideoExtractor 提取 video 与已知嵌入站 iframe', () {
      const html =
          '<html><body><video src="https://cdn.example/v.mp4" poster="https://cdn.example/p.jpg"></video>'
          '<iframe src="https://www.youtube.com/embed/abc123"></iframe>'
          '<iframe src="https://player.example/embed/1"></iframe></body></html>';
      final videos = VideoExtractor.extract(html, baseUrl: 'https://example.com/');
      expect(videos.any((v) => v.url.contains('v.mp4')), isTrue);
      expect(
        videos.any(
          (v) => v.url.contains('youtube.com') && v.source == 'youtube',
        ),
        isTrue,
      );
      // 未知嵌入站的 iframe 不认（上游 _isVideoEmbed 白名单行为）。
      expect(videos.any((v) => v.url.contains('player.example')), isFalse);
    });

    test('ImageExtractor 懒加载属性与过滤', () {
      const html =
          '<html><body><img data-src="https://img.example/a.jpg">'
          '<img src="https://img.example/b.png"></body></html>';
      final images = ImageExtractor.extractLazyImagesFromHtml(html);
      expect(images, contains('https://img.example/a.jpg'));
      expect(ImageExtractor.isValidImageUrl('https://img.example/a.jpg'), isTrue);
      expect(ImageExtractor.isValidImageUrl('not a url'), isFalse);
    });
  });

  group('JsonPath', () {
    test('基本路径与索引', () {
      final root = {
        'data': {
          'list': [
            {'name': '甲'},
            {'name': '乙'},
          ],
        },
      };
      expect(JsonPath.eval(r'$.data.list[0].name', root), '甲');
      expect(JsonPath.eval(r'$.data.list[1].name', root), '乙');
      expect(JsonPath.eval(r'$.missing', root), isNull);
    });
  });

  group('CookieStore（SharedPreferences 改编版）', () {
    test('save/get/load/delete/clear 全流程', () async {
      SharedPreferences.setMockInitialValues({});
      await CookieStore.save('example.com', 'sid=1', 'UA-1');
      await CookieStore.save('other.com', 'sid=2', 'UA-2');
      expect((await CookieStore.get('example.com'))?['cookie'], 'sid=1');
      expect((await CookieStore.get('example.com'))?['ua'], 'UA-1');
      final loaded = await CookieStore.load();
      expect(loaded['example.com'], 'sid=1');
      expect(loaded['other.com'], 'sid=2');
      final detailed = await CookieStore.loadDetailed();
      expect(detailed['other.com']?['ua'], 'UA-2');
      await CookieStore.delete('other.com');
      expect(await CookieStore.get('other.com'), isNull);
      await CookieStore.clear();
      expect(await CookieStore.load(), isEmpty);
    });
  });

  group('网络配置服务与覆盖存储', () {
    test('NetworkConfig JSON 往返', () {
      const config = NetworkConfig();
      final roundTrip = NetworkConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.toJson(), config.toJson());
      expect(NetworkConfig.defaults.toJson(), config.toJson());
    });

    test('覆盖存储 set/get/remove', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SourceNetworkOverrideStore.instance;
      await store.init();
      const override = SourceNetworkConfig(
        sni: SniConfig(enabled: true, defaultSni: 'example.com'),
      );
      await store.set('src1', override);
      expect(store.get('src1')?.sni?.defaultSni, 'example.com');
      await store.remove('src1');
      expect(store.get('src1'), isNull);
    });

    test('服务加载默认 + effectiveFor 合并', () async {
      SharedPreferences.setMockInitialValues({});
      final service = NetworkConfigService.instance;
      await service.load();
      expect(service.loaded, isTrue);
      expect(service.config.toJson(), NetworkConfig.defaults.toJson());
      final global = service.globalProfile;
      expect(
        service.effectiveFor(null),
        same(global),
      );
      expect(
        service.effectiveFor('no-such-source').toString(),
        global.toString(),
      );
    });

    test('SniPolicy 与系统代理值解析', () {
      const sni = SniConfig(enabled: true, defaultSni: 'sni.example');
      expect(SniPolicy.resolve(sni, 'any.example'), 'sni.example');
      expect(SniPolicy.resolve(SniConfig.defaults, 'any.example'), isNull);
      expect(
        SystemProxyResolver.parseProxyServerValue('127.0.0.1:7890'),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        SystemProxyResolver.parseProxyServerValue(
          'http=127.0.0.1:7890;https=127.0.0.1:7891',
        ),
        'PROXY 127.0.0.1:7891',
      );
      expect(SystemProxyResolver.parseProxyServerValue(''), isNull);
      expect(
        SystemProxyResolver.parseProxyServerValue('http://x/pac.pac'),
        isNull,
      );
    });

    test('NetworkClientBuilder 能构建 HttpClient', () {
      final profile = EffectiveNetworkProfile.fromConfig(NetworkConfig.defaults);
      final client = NetworkClientBuilder.buildHttpClient(profile);
      client.close(force: true);
    });
  });

  group('WebScrapeService（注入式抓取）', () {
    ContentResponse resp(String body, {int status = 200}) => ContentResponse(
      statusCode: status,
      headers: const {'content-type': 'text/html; charset=utf-8'},
      bodyBytes: utf8.encode(body),
    );

    const page =
        '<html><head><title>页标题</title></head><body>'
        '<a href="/a">链甲</a><a href="https://out.example/b">链乙</a>'
        '<p>正文段落</p>'
        '<img src="/i.jpg">'
        '<video src="/v.mp4"></video>'
        '</body></html>';

    test('general 模式：标题 + 绝对地址链接', () async {
      final service = WebScrapeService.forTest((_) async => resp(page));
      final result = await service.scrape(
        'https://example.com/p',
        ScrapeMode.general,
      );
      expect(result.pageTitle, '页标题');
      expect(result.links.map((l) => l.url), [
        'https://example.com/a',
        'https://out.example/b',
      ]);
      expect(result.isEmpty, isFalse);
    });

    test('novel/comic/video 模式各取其字段', () async {
      final service = WebScrapeService.forTest((_) async => resp(page));
      final novel = await service.scrape('https://example.com/p', ScrapeMode.novel);
      expect(novel.paragraphs, ['正文段落']);
      final comic = await service.scrape('https://example.com/p', ScrapeMode.comic);
      expect(comic.imageUrls, ['https://example.com/i.jpg']);
      final video = await service.scrape('https://example.com/p', ScrapeMode.video);
      expect(video.videoUrls, ['https://example.com/v.mp4']);
    });

    test('验证页抛 VerificationRequiredException', () async {
      final service = WebScrapeService.forTest(
        (_) async => resp('forbidden', status: 403),
      );
      expect(
        () => service.scrape('https://example.com/p', ScrapeMode.general),
        throwsA(isA<VerificationRequiredException>()),
      );
    });
  });

  group('ParseDiagnostics', () {
    test('log/clear', () {
      ParseDiagnostics.clear();
      ParseDiagnostics.log('src1', '第一行');
      expect(ParseDiagnostics.lastSourceId, 'src1');
      expect(ParseDiagnostics.lastLog, contains('第一行'));
      ParseDiagnostics.clear();
      expect(ParseDiagnostics.lastLog, isNull);
    });
  });
}
