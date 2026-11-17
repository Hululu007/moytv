import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// hiker://page/list 与 hiker://page/search 子页路由：查询串必须带进
/// 子页执行（getParam 读参），js: 子页靠 setResult 副作用渲染、返回
/// 空串时同样算已处理。旧代码丢查询串（runPageRule 传裸 'list'），且
/// 以返回文本为空就回首页/开原生搜索，把刚渲染出的子页抹掉（xhotvideo
/// 点标签后回首页、列表翻页卡永远到不了）。行为级验证走 Node 桩验
/// （真实运行时 + jsdom + 假后端，见
/// ~/workspace/haikuo_gaps_fix_20261117/stubs/drive2.cjs，140 三步
/// 链路：标签页 → 列表页 → 下一页取 /page/2 全过）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('list 分支：查询串带进子页', () {
    has("var listRef = splitPageRef(url.replace(/^hiker:\\/\\/page\\//i, ''));");
    has(
      "var listText = runPageRule(listPage.rule, listRef.path + (listRef.query ? '?' + listRef.query : ''));",
    );
  });

  test('list 分支：子页存在即已处理，空返回不回首页', () {
    has('if (listText) { renderVirtual(listText, url); }\n        return true;');
  });

  test('search 分支：同型修复', () {
    has(
      "var searchRef = splitPageRef(url.replace(/^hiker:\\/\\/page\\//i, ''));",
    );
    has(
      "var searchText = runPageRule(searchPage.rule, searchRef.path + (searchRef.query ? '?' + searchRef.query : ''));",
    );
    has('if (searchText) { renderVirtual(searchText, url); }');
  });
}
