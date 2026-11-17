import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 跑页去壳子顶栏：规则自带顶栏即顶栏，壳子按钮（收藏/搜索/刷新）
/// 并进规则顶栏、经桥消息回壳子。断言运行时模板里的落点
/// （与 haikuo_runtime_gapfix_test.dart 同一口径：无 jsdom 环境，
/// 行为级验证靠真机）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('规则顶栏带壳子按钮与常显返回钮', () {
    has('id="backBtn"');
    has('id="favBtn"');
    has('id="searchBtn"');
    has('id="reloadBtn"');
    has('class="hbtn"');
  });

  test('壳子按钮经桥消息回壳子', () {
    has("native({ type: 'shellFavorite' })");
    has("native({ type: 'shellSearch' })");
    has("native({ type: 'shellReload' })");
  });

  test('返回钮常显：详情页回退、首页发 pop', () {
    has('function showBack');
    has('function onBackBtn');
    has("native({ type: 'pop' })");
    has('goBack()');
  });

  test('标题省略不挤按钮', () {
    has('header h1 { flex: 1; min-width: 0;');
    has('text-overflow: ellipsis;');
  });

  group('haikuoSiteUrl：网站首页地址推导', () {
    HaikuoProgram program({String host = '', String url = ''}) =>
        HaikuoProgram(id: 'x', name: '站', host: host, url: url);

    test('host 优先，裸域名补 https', () {
      expect(
        haikuoSiteUrl(
          program(
            host: 'example.com',
            url: 'hiker://empty##https://other.example/x',
          ),
        ),
        'https://example.com',
      );
    });

    test('host 带路径时原样保留', () {
      expect(
        haikuoSiteUrl(program(host: 'https://a.example/path?q=1')),
        'https://a.example/path?q=1',
      );
    });

    test('入口链接嵌真实地址时取第一个 http(s) 地址', () {
      expect(
        haikuoSiteUrl(program(url: 'hiker://empty##https://b.example/list')),
        'https://b.example/list',
      );
    });

    test('hiker/js/空形态一律不认', () {
      expect(haikuoSiteUrl(program(url: 'hiker://empty')), isNull);
      expect(haikuoSiteUrl(program(url: 'js:setResult([]);')), isNull);
      expect(haikuoSiteUrl(program()), isNull);
      expect(haikuoSiteUrl(program(host: 'ftp://x.example')), isNull);
    });
  });
}
