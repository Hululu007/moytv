import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 详情形态复判的落点测试：模块式规则（pages + .rule()）与子页渲染的
/// 详情页不走 openDetail，isDetail 恒为 false，点播放会被当成列表页
/// 推新页。运行时按条目形态复判（pageIsDetail），只定播放路由、不改
/// 渲染。行为级验证见工作目录 Node harness
/// （~/workspace/haikuo_inline_fix_20261118/harness/inline_play_harness.cjs，
/// 真实 MissAV 规则 + jsdom，5 场景全过）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('复判状态与判定函数存在', () {
    has('var pageIsDetail = false;');
    has('function isDetailFormPage(items, ruleColType)');
    has('function isPlayLinkUrl(rawUrl)');
    // 首项带图 + 选集形态入口：text_2..text_9、按钮/标题行 + 播放入口地址。
    has('if (!itemPic(head)) return false;');
    has("if (/^text_[2-9]\$/.test(col)) return true;");
    has("col === 'flex_button' || col === 'scroll_button'");
    has("col === 'text_1' || col === 'text_center_1'");
    // 播放入口地址：懒链接、嗅探 scheme、播放 JSON、媒体地址；@rule= 不算。
    has("u.indexOf('hiker://lazy#') >= 0 || u.indexOf('@lazyRule=') >= 0");
    has("u.indexOf('x5Rule://') === 0");
    has('parsePlayJson(u)');
    has('isMediaLink(u, rawUrl)');
  });

  test('render() 每次重算复判，列表点按传复判值', () {
    has('pageIsDetail = isDetail || isDetailFormPage(items, ruleColType);');
    has('openItem(items[idx], pageIsDetail, idx);');
    has('bindLongClick(el, items[Number(el.getAttribute(\'data-index\'))], pageIsDetail);');
    has('handleLazyResult(out, it, pageIsDetail);');
  });

  test('sendPlay 与 play() 兜底含复判值', () {
    has('detail: fromDetail === true ? true : (isDetail || pageIsDetail)');
    has("detail: isDetail || pageIsDetail }); }");
  });

  test('详情页渲染路径仍显式传 true，不受复判影响', () {
    has('openItem(items[idx], true, idx);');
    has('if (it) openItem(it, true);');
  });

  test('非条目页清掉复判值，不泄漏到下一页', () {
    // renderText 与 renderGallery 各清一次（render() 内重算那次不计）。
    final hits = 'pageIsDetail = false;'.allMatches(html).length;
    expect(hits, greaterThanOrEqualTo(2));
  });

  test('路由决策：详情内嵌、列表推页、已开播放器递送', () {
    expect(
      resolvePlayRoute(fromDetail: true, playerActive: false),
      HaikuoPlayRoute.inline,
    );
    expect(
      resolvePlayRoute(fromDetail: false, playerActive: false),
      HaikuoPlayRoute.push,
    );
    expect(
      resolvePlayRoute(fromDetail: true, playerActive: true),
      HaikuoPlayRoute.deliver,
    );
    expect(
      resolvePlayRoute(fromDetail: false, playerActive: true),
      HaikuoPlayRoute.deliver,
    );
  });
}
