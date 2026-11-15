import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/playback_parse.dart';
import 'package:moyi/source_compat.dart';

void main() {
  group('classifySiteApi', () {
    test('csp_ prefix is a jar spider', () {
      expect(
        classifySiteApi(api: 'csp_Demo').kind,
        SiteApiKind.jarCsp,
      );
    });

    test('dotted full class name is a jar spider', () {
      expect(
        classifySiteApi(api: 'com.github.catvod.spider.YouTube').kind,
        SiteApiKind.jarClass,
      );
      expect(
        classifySiteApi(api: 'com.example.MySpider').kind,
        SiteApiKind.jarClass,
      );
    });

    test('bare domain is not a class name', () {
      expect(
        classifySiteApi(api: 'example.com').kind,
        SiteApiKind.unsupported,
      );
    });

    test('remote .py and .js files with query strings', () {
      expect(
        classifySiteApi(api: 'https://cdn.example.test/spider.py?v=2').kind,
        SiteApiKind.remotePy,
      );
      expect(
        classifySiteApi(api: 'https://cdn.example.test/alist.JS#x').kind,
        SiteApiKind.remoteJs,
      );
    });

    test('type 4 and string t4 are t4 aggregate apis', () {
      expect(
        classifySiteApi(api: 'https://t4.example.test/vod', typeValue: 4).kind,
        SiteApiKind.t4,
      );
      expect(
        classifySiteApi(
          api: 'https://t4.example.test/vod',
          typeValue: 't4',
        ).kind,
        SiteApiKind.t4,
      );
      // type:4 without an http api is not a t4 site.
      expect(
        classifySiteApi(api: 'csp_Bad', typeValue: 4).kind,
        SiteApiKind.jarCsp,
      );
    });

    test('plain http api and unsupported shapes', () {
      expect(
        classifySiteApi(api: 'https://api.example.test/vod/').kind,
        SiteApiKind.httpApi,
      );
      expect(classifySiteApi(api: '').kind, SiteApiKind.unsupported);
      expect(classifySiteApi(api: 'demo').kind, SiteApiKind.unsupported);
    });
  });

  group('parseSpiderRefValue', () {
    test('string url;md5 form', () {
      final ref = parseSpiderRefValue(
        'https://x.test/a.jar;0123456789abcdef0123456789abcdef',
      );
      expect(ref.url, 'https://x.test/a.jar');
      expect(ref.md5, '0123456789abcdef0123456789abcdef');
    });

    test('map form', () {
      final ref = parseSpiderRefValue({
        'url': 'https://x.test/a.jar',
        'md5': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'.toLowerCase(),
      });
      expect(ref.url, 'https://x.test/a.jar');
      expect(ref.md5, 'a' * 32);
    });

    test('list form and bare url', () {
      final ref = parseSpiderRefValue([
        'https://x.test/a.jar',
        'b' * 32,
      ]);
      expect(ref.url, 'https://x.test/a.jar');
      expect(ref.md5, 'b' * 32);
      expect(parseSpiderRefValue('https://x.test/a.jar').md5, '');
      expect(parseSpiderRefValue(null).url, '');
    });
  });

  group('tryDecodeBase64Config', () {
    test('base64-wrapped config decodes', () {
      final json = '{"name":"x","sites":[{"key":"a","name":"A","api":"https://a.test/"}]}';
      final encoded = base64Encode(utf8.encode(json));
      expect(tryDecodeBase64Config(encoded), json);
    });

    test('plain json and garbage return null', () {
      expect(tryDecodeBase64Config('{"sites": []}'), isNull);
      expect(tryDecodeBase64Config(base64Encode(utf8.encode('hello'))), isNull);
      expect(tryDecodeBase64Config('not base64!!!'), isNull);
      expect(tryDecodeBase64Config(''), isNull);
    });
  });

  group('looksLikeXbpqRuleJson', () {
    test('two rule keys are enough, one is not', () {
      expect(
        looksLikeXbpqRuleJson('{"主页url":"https://a.test/","数组":"x"}'),
        isTrue,
      );
      expect(
        looksLikeXbpqRuleJson('{"请求":"get","分类":"c"}'),
        isTrue,
      );
      expect(looksLikeXbpqRuleJson('{"主页url":"https://a.test/"}'), isFalse);
      expect(looksLikeXbpqRuleJson('not json'), isFalse);
    });
  });

  group('classifyJsSource', () {
    test('function spider', () {
      expect(
        classifyJsSource('function homeContent() { return {}; }'),
        JsSourceShape.functionSpider,
      );
    });

    test('cat script with @header and export default', () {
      const cat = '''
// @header({"lang": "cat"})
import { load } from "assets://cheerio";
function home(filter) { return JSON.stringify({}); }
function play(flag, id, flags) { return JSON.stringify({}); }
export default { home, play };
''';
      expect(classifyJsSource(cat), JsSourceShape.catScript);
    });

    test('module.exports script', () {
      expect(
        classifyJsSource('module.exports = { homeContent() {} };'),
        JsSourceShape.moduleExports,
      );
    });

    test('drpy declarative rule is identified, not run', () {
      const rule = '''
var rule = {
  title: "示例",
  host: "https://example.test",
  url: "/fyclass/fypage.html",
  class_name: "电影&剧集",
  一级: "body&&.item",
  二级: "*",
  搜索: "body&&.item",
};
''';
      expect(classifyJsSource(rule), JsSourceShape.drpyRule);
    });

    test('rule object without spider functions, and unknown text', () {
      expect(
        classifyJsSource('var rule = { title: "x" };'),
        JsSourceShape.ruleObject,
      );
      expect(classifyJsSource('1 + 1'), JsSourceShape.unknown);
    });
  });

  group('parseEntryShape', () {
    test('type 1 with object header', () {
      final shape = parseEntryShape({
        'name': 'JSON 解析',
        'type': 1,
        'url': 'https://jx.example.test/?url=',
        'header': {'User-Agent': 'UA1'},
      }, 1);
      expect(shape.isJson, isTrue);
      expect(shape.headers['User-Agent'], 'UA1');
    });

    test('string type and json-string header, api alias', () {
      final shape = parseEntryShape({
        'name': '解析',
        'type': '1',
        'api': 'https://jx.example.test/?url=',
        'headers': '{"Cookie": "a=b"}',
      }, 2);
      expect(shape.typeValue, 1);
      expect(shape.url, 'https://jx.example.test/?url=');
      expect(shape.headers['Cookie'], 'a=b');
    });

    test('missing type defaults to 0', () {
      expect(parseEntryShape({'url': 'https://x.test/'}, 3).typeValue, 0);
    });
  });

  group('parseLiveEntry', () {
    test('array url picks the first http address, epg/group pass through', () {
      final live = parseLiveEntry({
        'name': '央视',
        'url': ['/local.m3u', 'https://live.example.test/tv.m3u'],
        'epg': 'https://epg.example.test/epg.xml',
        'group': '央视',
      }, 1);
      expect(live.url, 'https://live.example.test/tv.m3u');
      expect(live.epg, 'https://epg.example.test/epg.xml');
      expect(live.group, '央视');
    });
  });

  group('ParseInterface jsonApi/headers', () {
    test('round trip keeps jsonApi and headers', () {
      const item = ParseInterface(
        id: 'p1',
        name: 'JSON 解析',
        url: 'https://jx.example.test/?url=',
        jsonApi: true,
        headers: {'User-Agent': 'UA1'},
      );
      final decoded = ParseInterface.fromJson(item.toJson());
      expect(decoded.jsonApi, isTrue);
      expect(decoded.headers['User-Agent'], 'UA1');
    });

    test('empty jsonApi/headers are not serialized', () {
      const item = ParseInterface(id: 'p2', name: '普通', url: 'https://x.test/');
      expect(item.toJson().containsKey('jsonApi'), isFalse);
      expect(item.toJson().containsKey('headers'), isFalse);
    });

    test('applySelectedParse skips json apis', () {
      const jsonApi = ParseInterface(
        id: 'p3',
        name: 'JSON',
        url: 'https://jx.example.test/?url=',
        jsonApi: true,
      );
      expect(
        applySelectedParse(
          url: 'https://a.test/play',
          needsParse: true,
          selected: jsonApi,
        ),
        isNull,
      );
      const webApi = ParseInterface(
        id: 'p4',
        name: '网页',
        url: 'https://jx.example.test/?url=',
      );
      expect(
        applySelectedParse(
          url: 'https://a.test/play',
          needsParse: true,
          selected: webApi,
        ),
        'https://jx.example.test/?url=https://a.test/play',
      );
    });
  });
}
