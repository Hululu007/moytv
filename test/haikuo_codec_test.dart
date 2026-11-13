import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';

Map<String, dynamic> _rule({
  String title = '测试小程序',
  String findRule = 'js:\nvar d = []; d.push({title: "a", url: "https://a.com/1.m3u8"}); setResult(d);',
}) => {
  'title': title,
  'author': '作者',
  'version': '2',
  'type': 'video',
  'url': 'hiker://empty##https://example.com/list',
  'col_type': 'movie_3',
  'find_rule': findRule,
  'searchFind': '',
  'pages': '[{"path":"ad","rule":"js:return \\"1\\""}]',
  'icon': '',
};

void main() {
  group('海阔 JSON 解析', () {
    test('单条海阔规则：标题、脚本、子页数量都能认出来', () {
      final programs = HaikuoCodec.parseJsonText(
        jsonEncode(_rule()),
        origin: '测试',
      );
      expect(programs, hasLength(1));
      final program = programs.single;
      expect(program.name, '测试小程序');
      expect(program.author, '作者');
      expect(program.kind, HaikuoKind.rule);
      expect(program.script, contains('setResult'));
      expect(program.entries, 1);
      expect(program.url, contains('example.com'));
      expect(program.origin, '测试');
    });

    test('数组形态（多小程序合集）逐条解析', () {
      final payload = jsonEncode([
        _rule(title: '甲'),
        _rule(title: '乙', findRule: 'js:\nsetResult([]);'),
      ]);
      final programs = HaikuoCodec.parseJsonText(payload);
      expect(programs.map((p) => p.name), ['甲', '乙']);
    });

    test('外面套一层 data 包裹也能解析', () {
      final payload = jsonEncode({
        'name': '合集',
        'data': [_rule(title: '内层小程序')],
      });
      final programs = HaikuoCodec.parseJsonText(payload);
      expect(programs.single.name, '内层小程序');
    });

    test('script 形态（小程序包）走脚本类型', () {
      final payload = jsonEncode({
        'name': '脚本小程序',
        'version': '1.0',
        'script': 'var d=[]; d.push({title:"x"}); setResult(d);',
      });
      final programs = HaikuoCodec.parseJsonText(payload);
      expect(programs.single.kind, HaikuoKind.script);
      expect(programs.single.runnable, isTrue);
    });

    test('认不出的 JSON 给出人话错误而不是崩溃', () {
      expect(
        () => HaikuoCodec.parseJsonText('{"foo":1}'),
        throwsA(isA<HaikuoFormatException>()),
      );
      expect(
        () => HaikuoCodec.parseJsonText('{bad json'),
        throwsA(isA<HaikuoFormatException>()),
      );
    });
  });

  group('口令解码', () {
    test('官方口令分段（￥home_rule￥…）能抽出载荷', () {
      final payload = jsonEncode(_rule(title: '口令小程序'));
      final command = '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
      final candidates = HaikuoCodec.extractCandidates(command);
      expect(candidates, contains(payload));
    });

    test('base64://@标题@载荷 能解出 JSON', () {
      final payload = jsonEncode(_rule(title: '编码口令'));
      final encoded = base64Encode(utf8.encode(payload));
      final command = 'base64://@编码口令@$encoded';
      final candidates = HaikuoCodec.extractCandidates(command);
      expect(candidates.any((c) => c.contains('编码口令')), isTrue);
    });

    test('rule:// 整段 base64 能还原成口令', () {
      final payload = jsonEncode(_rule(title: '双层口令'));
      final command = '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
      final wrapped = 'rule://${base64Encode(utf8.encode(command))}';
      final candidates = HaikuoCodec.extractCandidates(wrapped);
      expect(candidates.any((c) => c.contains('双层口令')), isTrue);
    });

    test('直接贴 JSON 正文也算合法载荷', () {
      final payload = jsonEncode(_rule(title: '直贴'));
      expect(HaikuoCodec.looksLikeJson(payload), isTrue);
      expect(HaikuoCodec.parseText(payload).single.name, '直贴');
    });

    test('base64 编码的 JSON 包能解析', () {
      final payload = jsonEncode(_rule(title: 'BASE64包'));
      final bytes = utf8.encode(payload);
      final programs = HaikuoCodec.parseBytes(
        base64Encode(bytes).codeUnits,
      );
      expect(programs.single.name, 'BASE64包');
    });
  });

  group('id 与去重', () {
    test('同名同主体生成同一个 id', () {
      final rule = jsonEncode(_rule());
      final first = HaikuoCodec.parseJsonText(rule).single;
      final second = HaikuoCodec.parseJsonText(rule).single;
      expect(first.id, second.id);
    });

    test('主体不同则 id 不同', () {
      final a = HaikuoCodec.parseJsonText(
        jsonEncode(_rule(title: '同名', findRule: 'js:\nsetResult([1]);')),
      ).single;
      final b = HaikuoCodec.parseJsonText(
        jsonEncode(_rule(title: '同名', findRule: 'js:\nsetResult([2]);')),
      ).single;
      expect(a.id, isNot(b.id));
    });
  });

  group('真实海阔规则（公开仓库取样）', () {
    test('两条真实规则能完整解析，脚本与入口都在', () {
      final file = File('test/fixtures/haikuo_real_rules.json');
      final programs = HaikuoCodec.parseText(
        file.readAsStringSync(),
        origin: '真实样本',
      );
      expect(programs, hasLength(2));
      final names = programs.map((p) => p.name).toSet();
      expect(names, containsAll(['吾爱破解', '热榜']));
      for (final program in programs) {
        expect(program.kind, HaikuoKind.rule);
        expect(program.script.length, greaterThan(50));
        expect(program.url, contains('hiker://empty'));
        expect(program.rawJson, contains('find_rule'));
      }
    });

    test('真实规则走口令路径也能导入', () {
      final raw = File('test/fixtures/haikuo_real_rules.json').readAsStringSync();
      final payload = raw.substring(raw.indexOf('['));
      final command = '海阔视界规则分享，当前分享的是：小程序￥home_rule￥$payload￥';
      final candidates = HaikuoCodec.extractCandidates(command);
      final parsed = <HaikuoProgram>[];
      for (final candidate in candidates) {
        if (!candidate.trim().startsWith('[')) continue;
        try {
          parsed.addAll(HaikuoCodec.parseText(candidate));
        } on HaikuoFormatException {
          // 分段候选里必然有几个是残缺片段，跳过即可（正式导入也是这样逐个试）
        }
      }
      expect(parsed, isNotEmpty);
      expect(parsed.map((p) => p.name), contains('吾爱破解'));
    });
  });

  group('生成口令分享', () {
    test('生成的口令走现有导入路径能原样认回，分类声明不丢', () {
      final ruleJson = jsonEncode({
        'title': '口令往返源',
        'author': '皇帝影院',
        'version': '3',
        'url': 'hiker://empty##fyclass##fypage',
        'class_name': '中文字幕&国产传媒',
        'class_url': '7&8',
        'sort_name': '最新&最热',
        'sort_url': 'latest&hot',
        'find_rule': 'js:\nsetResult([{title:"a", url:"https://a.com/1.m3u8"}]);',
      });
      final program = HaikuoCodec.parseText(ruleJson).single;
      final code = HaikuoCodec.buildShareCode(program);
      expect(code.startsWith('海阔视界规则分享，当前分享的是：小程序￥home_rule￥'), isTrue);
      expect(code.endsWith('￥'), isTrue);
      // 走与正式导入同一条路径：extractCandidates 逐个试 parseText。
      final reparsed = <HaikuoProgram>[];
      for (final candidate in HaikuoCodec.extractCandidates(code)) {
        try {
          reparsed.addAll(HaikuoCodec.parseText(candidate));
        } on HaikuoFormatException {
          // 分段候选里有残缺片段，跳过即可。
        }
      }
      expect(reparsed, isNotEmpty);
      final back = reparsed.firstWhere((p) => p.name == '口令往返源');
      expect(back.script, contains('setResult'));
      expect(back.url, 'hiker://empty##fyclass##fypage');
      // 原始 JSON 原样进了载荷：分类/排序声明在 rawJson 里都在。
      expect(back.rawJson, contains('class_name'));
      expect(back.rawJson, contains('sort_url'));
    });

    test('没有原始 JSON 的程序也能生成可导入的口令', () {
      final program = HaikuoProgram(
        id: 'test-manual',
        name: '手写源',
        author: '某人',
        version: '1',
        url: 'https://example.com/list',
        script: 'setResult([{title:"x"}]);',
      );
      final code = HaikuoCodec.buildShareCode(program);
      final reparsed = <HaikuoProgram>[];
      for (final candidate in HaikuoCodec.extractCandidates(code)) {
        try {
          reparsed.addAll(HaikuoCodec.parseText(candidate));
        } on HaikuoFormatException {
          // 分段候选里有残缺片段，跳过即可。
        }
      }
      expect(reparsed.map((p) => p.name), contains('手写源'));
      expect(
        reparsed.firstWhere((p) => p.name == '手写源').script,
        contains('setResult'),
      );
    });
  });
}
