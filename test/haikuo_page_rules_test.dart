import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runtime_html.dart';

/// 第 9 项（海阔小程序“国外精品”整页失败）回归测试。
///
/// 根因：子页 rule 不带 js: 前缀、直接写 JS（var d = []; 开头）时，
/// 运行时 runPageRule / loadModule 只认 js: 前缀，把脚本源码原样
/// 当数据返回，调用方 JSON.parse 拿到源码就报
/// Unexpected token 'v'。行为级复现与修复验证在 Node 桩 harness
/// 里做（跑真实 haikuo_runtime_html 脚本，见回报）；这里钉住
/// Dart 侧能验的部分：两种导入形态的解析、子页结构不被导入
/// 弄丢、内置规则文件 md5 与条数钉住、运行时修复点位仍在。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('两种导入形态', () {
    test('JSON 规则形态：find_rule + pages 数组，解析后结构完整', () {
      final programs = HaikuoCodec.parseText(
        jsonEncode({
          'title': '国外精品',
          'url': 'hiker://empty##fyclass##fypage',
          'find_rule':
              'js:var j = JSON.parse(fetch("hiker://page/data")); '
              'setResult(j);',
          'pages': [
            {
              'path': 'data',
              'rule':
                  'var d = []; d.push({title: "X", url: "https://example.com/1"}); '
                  'return JSON.stringify(d);',
            },
          ],
        }),
        origin: '测试',
      );
      expect(programs, hasLength(1));
      final program = programs.single;
      expect(program.name, '国外精品');
      expect(program.kind, HaikuoKind.rule);
      expect(program.script, contains('JSON.parse'));
      expect(program.script, contains('hiker://page/data'));
      // 子页裸 JS 原文必须原样留在 rawJson 里，运行时才有东西可执行。
      expect(program.rawJson, contains('var d = []'));
      final raw = jsonDecode(program.rawJson) as Map;
      final pages = raw['pages'] as List;
      expect((pages.single as Map)['path'], 'data');
      expect((pages.single as Map)['rule'], contains('return JSON.stringify'));
    });

    test('JS 脚本形态：script 字段含 JSON.parse，解析后原样保留', () {
      final programs = HaikuoCodec.parseText(
        jsonEncode({
          'title': '脚本小站',
          'url': 'https://api.example.com/',
          'script':
              'var d = []; var j = JSON.parse(fetch("https://api.example.com/list")); '
              'setResult(j.list);',
        }),
        origin: '测试',
      );
      expect(programs, hasLength(1));
      final program = programs.single;
      expect(program.name, '脚本小站');
      expect(program.kind, HaikuoKind.script);
      expect(program.script, contains('JSON.parse(fetch('));
      expect(program.runnable, isTrue);
    });

    test('pages 为 JSON 编码字符串形态（官方写法），解析后子页仍在', () {
      final programs = HaikuoCodec.parseText(
        jsonEncode({
          'title': '字符串子页',
          'url': 'hiker://empty##fyclass##fypage',
          'find_rule':
              'js:var m = \$.require("hiker://page/mod"); setResult(m.items());',
          'pages': jsonEncode([
            {
              'path': 'mod',
              'rule':
                  '\$.exports = {items: function() { return [{title: "M"}]; }};',
            },
          ]),
        }),
        origin: '测试',
      );
      expect(programs, hasLength(1));
      expect(programs.single.kind, HaikuoKind.rule);
      expect(programs.single.rawJson, contains('pages'));
      expect(programs.single.rawJson, contains('exports'));
    });
  });

  group('内置规则不受影响', () {
    test('内置规则文件 md5 钉住、146 条、含鉴黄师', () {
      final file = File('assets/haikuo_builtin_rules.json');
      expect(file.existsSync(), isTrue);
      final bytes = file.readAsBytesSync();
      expect(md5.convert(bytes).toString(), '68f0bd9c740cf3b70b26adf32974439b');
      final decoded = jsonDecode(utf8.decode(bytes)) as List;
      expect(decoded, hasLength(146));
      final titles = [for (final item in decoded) (item as Map)['title']];
      expect(titles, contains('🔞鉴黄师'));
      // 鉴黄师仍是 js: 首页脚本 + hiker://empty 入口，修复没动过它。
      final jhs =
          decoded.firstWhere((item) => (item as Map)['title'] == '🔞鉴黄师')
              as Map;
      expect('${jhs['find_rule']}', startsWith('js:'));
      expect(jhs['url'], 'hiker://empty##fyclass##fypage');
    });
  });

  group('运行时修复点位', () {
    test('裸 JS 子页判定与两处调用点仍在', () {
      expect(haikuoRuntimeHtml, contains('function isBareJsRule'));
      expect(
        haikuoRuntimeHtml,
        contains("trimmed.indexOf('js:') === 0 || isBareJsRule(text)"),
      );
      expect(haikuoRuntimeHtml, contains('!isBareJsRule(rule)'));
    });

    test('数据页原样返回与 js: 执行分支仍在', () {
      // JSON 数据页 / 选择器页仍走原样返回，不能被修法误伤成执行。
      expect(haikuoRuntimeHtml, contains('return text;'));
      expect(haikuoRuntimeHtml, contains('new Function(code)'));
      // 主脚本入口仍执行裸 JS（runSource 不依赖 js: 前缀）。
      expect(haikuoRuntimeHtml, contains('function runSource(source)'));
    });
  });
}
