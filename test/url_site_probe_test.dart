import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/content_http.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/url_site_probe.dart';

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
<div class="list"><a href="/detail/1.html"><img src="/c1.jpg">影片甲</a></div>
<div class="pages"><a href="/list/1-2.html">下一页</a></div>
</body></html>
''';

const _noCategoryHtml = '''
<html><head><title>只有首页的站</title></head><body>
<nav><a href="/">首页</a><a href="/about.html">关于我们</a></nav>
<p>hello</p>
</body></html>
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UrlSiteProbe probeWith(Map<String, ContentResponse> pages, {Object? error}) {
    return UrlSiteProbe(
      fetchHtml: (url) async {
        if (error != null) throw error;
        final hit = pages[url];
        if (hit != null) return hit;
        return _resp('not found', status: 404);
      },
    );
  }

  test('MacCMS 风格站：分类模板 + 翻页 + 搜索全部探到', () async {
    final probe = probeWith({
      'https://example.com/': _resp(_homeHtml),
      'https://example.com/api.php/provide/vod/?ac=list&pg=1': _resp(
        'nope',
        status: 404,
      ),
      'https://example.com/list/1-1.html': _resp(_categoryHtml),
    });
    final site = await probe.probe('https://example.com/');
    expect(site.name, '测试影院');
    expect(site.base, 'https://example.com');
    expect(site.isMacCMS, isFalse);
    expect(site.categories.map((c) => c.id), ['1', '2', '3']);
    expect(site.categories.map((c) => c.name), ['电影', '电视剧', '综艺']);
    final rule = jsonDecode(site.rule) as Map<String, dynamic>;
    expect(rule['主页url'], 'https://example.com/');
    expect(
      rule['分类url'],
      'https://example.com/list/{cateId}-{catePg}.html',
    );
    expect(rule['分类'], '电影\$1#电视剧\$2#综艺\$3');
    expect(rule['搜索url'], 'https://example.com/search.html?wd={wd}');
    expect(site.evidence.any((e) => e.contains('已探到')), isTrue);
  });

  test('MacCMS 采集接口探到则只记 base，不生成规则', () async {
    final probe = probeWith({
      'https://maccms.example/': _resp(_homeHtml),
      'https://maccms.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        '{"code":1,"list":[{"vod_id":1,"vod_name":"x"}],"total":1}',
      ),
    });
    final site = await probe.probe('https://maccms.example/');
    expect(site.isMacCMS, isTrue);
    expect(site.rule, '');
    expect(site.base, 'https://maccms.example');
  });

  test('验证页不绕过：403 直接报错不生成记录', () async {
    final probe = probeWith({
      'https://shield.example/': _resp('forbidden', status: 403),
    });
    expect(
      () => probe.probe('https://shield.example/'),
      throwsA(
        isA<ProbeFailure>().having(
          (e) => e.message,
          'message',
          contains('验证页'),
        ),
      ),
    );
  });

  test('验证页不绕过：200 挑战页含 Just a moment 也报错', () async {
    final probe = probeWith({
      'https://shield2.example/': _resp(
        '<html><head><title>Just a moment...</title></head><body>checking</body></html>',
      ),
    });
    expect(
      () => probe.probe('https://shield2.example/'),
      throwsA(isA<ProbeFailure>()),
    );
  });

  test('无分类结构：诚实报错不生成记录', () async {
    final probe = probeWith({
      'https://plain.example/': _resp(_noCategoryHtml),
      'https://plain.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        'nope',
        status: 404,
      ),
    });
    expect(
      () => probe.probe('https://plain.example/'),
      throwsA(
        isA<ProbeFailure>().having(
          (e) => e.message,
          'message',
          contains('分类结构'),
        ),
      ),
    );
  });

  test('抓不到：传输失败转中文报错', () async {
    final probe = probeWith({}, error: AppFailure('无法连接内容源'));
    expect(
      () => probe.probe('https://down.example/'),
      throwsA(
        isA<ProbeFailure>().having(
          (e) => e.message,
          'message',
          contains('无法连接内容源'),
        ),
      ),
    );
  });

  test('非法输入：空网址与非 http 协议都报错', () async {
    final probe = probeWith({});
    expect(() => probe.probe('  '), throwsA(isA<ProbeFailure>()));
    expect(() => probe.probe('ftp://x.com/'), throwsA(isA<ProbeFailure>()));
    expect(() => probe.probe('not a url'), throwsA(isA<ProbeFailure>()));
  });

  test('站名取标题第一段且截断 40 字', () async {
    final longTitle = '这是一个名字非常非常非常非常非常非常非常非常非常非常非常长的影院 - 口号';
    final probe = probeWith({
      'https://long.example/': _resp(
        '<html><head><title>$longTitle</title></head><body><nav>'
        '<a href="/a/1.html">甲</a><a href="/a/2.html">乙</a></nav></body></html>',
      ),
      'https://long.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        'nope',
        status: 404,
      ),
      'https://long.example/a/1.html': _resp(
        '<html><body><a href="/d/1.html">x</a></body></html>',
      ),
    });
    final site = await probe.probe('https://long.example/');
    expect(site.name.runes.length, lessThanOrEqualTo(40));
    expect(site.name, startsWith('这是一个名字'));
  });

  test('无翻页链接时模板不带页码且证据如实写明', () async {
    final probe = probeWith({
      'https://nopage.example/': _resp(_homeHtml),
      'https://nopage.example/api.php/provide/vod/?ac=list&pg=1': _resp(
        'nope',
        status: 404,
      ),
      'https://nopage.example/list/1-1.html': _resp(
        '<html><body><a href="/d/1.html">x</a></body></html>',
      ),
    });
    final site = await probe.probe('https://nopage.example/');
    final rule = jsonDecode(site.rule) as Map<String, dynamic>;
    expect(rule['分类url'], 'https://nopage.example/list/{cateId}-1.html');
    expect(
      site.evidence.any((e) => e.contains('翻页规律：未探到')),
      isTrue,
    );
  });
}
