import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 模块式详情页海报藏匿的落点测试：模块式规则详情页走列表分支渲染，
/// 头项不是经典详情页的 .d-head，上一轮内嵌播放修复后海报仍显示在
/// 播放器下方。本轮修复：render() 在 pageIsDetail 时给头项元素打
/// .hk-detail-head 标记，body.hk-inline-playing 时 CSS 藏起它，与
/// 经典详情页 .d-head 同一口径。行为级验证见工作目录 Node harness
/// （~/workspace/fixbatch_20261118/groups/w2_haikuo_poster/harness/
/// poster_hide_harness.cjs，真实 MissAV 规则 + jsdom，8 场景 46 断言全过，
/// 修复前备份跑同一桩验 8 处失败）。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  test('藏匿规则：经典头项与列表分支头项同一口径，且只出现一次', () {
    has('body.hk-inline-playing .d-head,');
    has('body.hk-inline-playing .hk-detail-head { display: none; }');
    expect(
      'body.hk-inline-playing .d-head,'.allMatches(html).length,
      1,
      reason: '藏匿规则不得重复出现',
    );
    expect(
      'body.hk-inline-playing .hk-detail-head'.allMatches(html).length,
      1,
      reason: '藏匿规则不得重复出现',
    );
  });

  test('藏匿规则在样式表末尾，后于各版式自身的 display 声明', () {
    // 头项自身的版式规则（如 .rowitem/.picgrid img）也带 display 声明：
    // 藏匿规则须后于它们，特异性与顺序双保险，任何引擎都藏得住。
    final hideAt = html.indexOf(
      'body.hk-inline-playing .hk-detail-head { display: none; }',
    );
    expect(hideAt, greaterThan(html.indexOf('.rowitem { display: flex;')));
    expect(
      hideAt,
      greaterThan(html.indexOf('.picgrid img { width: 100%; display: block;')),
    );
    expect(hideAt, lessThan(html.indexOf('</style>')));
  });

  test('render() 列表分支给详情形态头项打标记', () {
    has("var headEl = listEl.querySelector('[data-index=\"0\"]');");
    has("headEl.classList.add('hk-detail-head');");
    // 标记打在渲染赋值之后、点按绑定之前：只随本次渲染的 DOM 走，
    // 每次渲染重打，播放中重渲染也不露海报。
    final markAt = html.indexOf("headEl.classList.add('hk-detail-head');");
    expect(
      markAt,
      greaterThan(
        html.indexOf('html += sectionHtml(sec.col, sec.indexes, items);'),
      ),
    );
    expect(
      markAt,
      lessThan(html.indexOf('openItem(items[idx], pageIsDetail, idx);')),
    );
  });

  test('打标记只认详情形态页，x5 占位不打', () {
    has('if (pageIsDetail) {');
    has("!headEl.hasAttribute('data-x5-slot')");
  });

  test('经典详情页藏法不动：body 开关仍只改 hk-inline-playing 类', () {
    has('window.__haikuoSetInlinePlaying = function (on) {');
    has("document.body.classList.add('hk-inline-playing');");
    has("document.body.classList.remove('hk-inline-playing');");
  });

  test('设计口径：运行时页无“立即播放”按钮文案', () {
    expect(html, isNot(contains('立即播放')));
  });
}
