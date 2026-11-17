import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// G3 列表翻页：滚到底自动加载下一页并追加。落点钉串测试：断言
/// 翻页机制真实存在于运行时 HTML 里；行为级验证走 Node 桩验
/// （真实运行时 + jsdom + 假后端，三条内置真规则，见
/// ~/workspace/g3_paging_20261117/stub.cjs，34 项全过）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('翻页状态与入口函数', () {
    has('var pagingCtx = null;');
    has('var pagingLoading = false;');
    has('var pagingExhaustedKey = null;');
    has('function pagingListKey()');
    has('function pagingEligible()');
    has('function bindPagingScroll()');
    has('function maybeLoadNextPage()');
    has('function loadNextListPage()');
    has('function runNextListPage(ctx, guardKey)');
    has('bindPagingScroll();');
  });

  test('页码改写：## 第 2 段与子页 page 参数', () {
    has('function withPageSegment(url, page)');
    has("if (seg !== 'fypage' && !/^\\d+\$/.test(seg)) return text;");
    has('function withQueryPage(url, page)');
    has("if (kv[0] === 'page'");
  });

  test('武装只看证据：fypage / ## / MY_PAGE', () {
    has('function pagingEvidence(scriptText)');
    has("return t.indexOf('MY_PAGE') >= 0");
    has("if (ruleUrl.indexOf('fypage') >= 0");
    has("if (String(MY_URL || '').indexOf('##') >= 0) return true;");
    has("if (String(rule.search_url || '').indexOf('fypage') >= 0) return true;");
  });

  test('触发条件：详情页不翻、未滚不翻、距底 200px', () {
    has('if (isDetail || pagingLoading || resultCapture) return false;');
    has('if (y <= 0) return;');
    has('if (y + vh < sh - 200) return;');
    has("footer.className = 'paging-more';");
    has('.paging-more {');
  });

  test('捕获模式重跑：三路脚本 + 监听恢复 + 去重追加', () {
    has('resultCapture = collected;');
    has('runSource(searchScriptText());');
    has('var text = resolveVirtual(vUrl);');
    has('runSource(homeScript);');
    has('preResultItems = savedPre;');
    has('function pagingItemKey(it)');
    has('render(currentItems.concat(fresh));');
    has("toast('没有更多了');");
  });

  test('上下文记账：渲染定稿 + 子页改记 + 聚合搜索清掉', () {
    has('if (!pagingRendering) {');
    has("pagingCtx = { kind: MY_TYPE === 'search' ? 'search' : 'home' };");
    has("pagingCtx = { kind: 'virtual', url: String(url || '') };");
    has('pagingCtx = null;\n  }\n\n  var API = {');
  });

  test('搜索地址与脚本抽取复用', () {
    has('function searchScriptText()');
    has('function buildSearchUrl(kw, page)');
    has('var script = searchScriptText();');
    has('var myUrl = buildSearchUrl(kw, page);');
  });

  test('刷新回第 1 页', () {
    has('setGlobals(withPageSegment(MY_URL, 1), 1);');
    has('pagingExhaustedKey = null;');
  });

  test('导航栈快照：已翻页列表返回恢复', () {
    has('if (MY_PAGE > 1 && !isDetail');
    has('entry.items = currentItems.slice();');
    has('if (prev && prev.page > 1 && prev.items && prev.items.length) {');
    has('render(prev.items.slice());');
  });

  test('既有机制未动：C12 自动拼接仍在', () {
    has('function armAutoPage');
    has('function bindAutoPageScroll');
    has('function maybeAutoPage');
    has('function loadNextAutoPage');
    has('function captureNextChapter');
  });
}
