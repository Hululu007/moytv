import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 选择器批（B04/B06/B10-A/B/C、F16 select/b64、looksDeclarative）落点
/// 测试：断言修复代码真实存在于运行时 HTML 与跑页里。行为级验证见
/// Node 抽取测试（~/workspace/shell_gap_sweep_20261117/impl/w2/，
/// 389 项全过）；此处只钉关键串，与 gapfix/header_suffix 测试同款。
void main() {
  final html = haikuoRuntimeHtml;

  void has(String needle) {
    expect(html, contains(needle), reason: '缺失：$needle');
  }

  void lacks(String needle) {
    expect(html, isNot(contains(needle)), reason: '不应存在：$needle');
  }

  test('B10-B：属性选择器归一化与 [attr!=val] 后置过滤', () {
    has('function normalizeAttrSelectors');
    has("filters.push({ kind: 'attrNe', attr: attr, value: unquotePseudoArg(rawVal) });");
    has("out += '[' + attr + op + '\"' + escaped + '\"' + flag + ']';");
    has("if (op === '!=') {");
  });

  test('B10-A：jsoup 伪类括号平衡提取与 :not 内嵌套', () {
    has('function findMatchingParen');
    has('function stripPseudoBlocks');
    has('function textFilterMatches');
    has('function nodeMatchesSelectorArg');
    has('function nodeHasDescendant');
    has("filters.push({ kind: 'not', arg: notStripped.blocks[ni].arg });");
    has("stripPseudoBlocks(text, ['matches', 'contains', 'matchesOwn', 'containsOwn'])");
    has("out = out.filter(function (n) { return !nodeMatchesSelectorArg(n, f.arg); });");
  });

  test('B10-A：禁止静默放宽，旧的剥全部伪类重试已删', () {
    has('禁止静默放宽');
    has('function queryWithin');
    lacks('剥掉除 :not 外的伪类再试一次');
    lacks("parsed.selector.replace(/:(?!not\\()[a-zA-Z-]+");
  });

  test('B04：-- 排除克隆-摘除模型', () {
    has('function splitTopLevel');
    has('function querySegment');
    has('var clone = node.cloneNode(true);');
    has('BEM 式含 `--` 的类名');
    has('原始文档绝不改动');
  });

  test('B06：|| 并集文档顺序去重与尾巴回退链', () {
    has('function queryAlternatives');
    has('compareDocumentPosition');
    has('function isTailChain');
    has("if (t.indexOf('||') >= 0) {");
    has("seg === 'Text' || seg === 'Html' || seg === 'OuterHtml'");
  });

  test('B10-C：声明式路径复用 selectWithAttrFallback', () {
    has('var sel = selectWithAttrFallback([contextNode], chain);');
    has('var sel = selectWithAttrFallback([docOf(html)], chain);');
    has('var value = valueOf(nodes[0], sel.tail);');
  });

  test('F16-SELECT：\$() 数组入参与 chained.select 生成 select:// 链接', () {
    has('var selectOptions = null;');
    has('selectOptions = selector.map(function (v) { return String(v); });');
    has('chained.select = function (fn) {');
    has('js: dollarToString.apply(null, [fn].concat(args))');
    has("return 'select://' + JSON.stringify(cfg);");
  });

  test('F16-B64：链式恒等一行', () {
    has('chained.b64 = function () { return chained; };');
  });

  test('F16-SELECT：openSelectDialog 设 MY_INDEX 并跟随返回值', () {
    has('var MY_INDEX = -1;');
    has('window.MY_INDEX = MY_INDEX;');
    has('MY_INDEX = idx;');
    has('try { window.MY_INDEX = idx; } catch (e0) {}');
    has('var out = (0, eval)(String(cfg.js));');
    has('if (typeof out === \'string\' && out) openItem({ url: out });');
  });

  test('looksDeclarative：.js: 段内 fetch 不触发非声明式', () {
    has(r"var withoutJs = t.replace(/\.js:[^;]*/g, '');");
    has('if (/\\b(var|let|const|function|return|fetch|setResult|eval|require)\\b/.test(withoutJs)) return false;');
  });

  test('select:// 对话框列数缺省为 3，显式 col 不变', () {
    final runner =
        File('lib/miniapp/haikuo/haikuo_runner_page.dart').readAsStringSync();
    expect(runner,
        contains("int.tryParse(params['col'] ?? '') ?? 3).clamp(1, 6)"));
    expect(runner,
        isNot(contains("int.tryParse(params['col'] ?? '') ?? 1).clamp(1, 6)")));
  });

  test('扫修 3 处修复与 W1 新增符号仍在', () {
    has("replace(/fyAll/g, String(selectedCls || ''))");
    has('function getResCode() { try { return fetchPageHtml(); }');
    has('function JavaPBEKeySpec');
    has('function extractPlayHeaderSuffix');
    has('function normalizePlayHeadersList');
    has('function getPastes');
    has('function sharePaste');
    has('function parsePaste');
    has('payload.lines = lines;');
  });
}
