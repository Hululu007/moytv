import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 2026-11-16 合并批（第二阶段）落点测试：35 条内置规则包扩到 164 条，
// 同日用户令删没验过的 34 条、短剧one 恢复旧版，包缩到 130 条。
// 只读 asset 文件本身，不跑运行时；手机实测仍须另做。
List<Map<String, dynamic>> _rules() {
  final bytes = File('assets/haikuo_builtin_rules.json').readAsBytesSync();
  final decoded = jsonDecode(utf8.decode(bytes)) as List;
  return [for (final item in decoded) item as Map<String, dynamic>];
}

Map<String, dynamic> _byTitle(List<Map<String, dynamic>> rules, String title) =>
    rules.firstWhere((rule) => rule['title'] == title);

List<String> _segments(Map<String, dynamic> rule, String key) {
  final raw = '${rule[key] ?? ''}';
  if (raw.isEmpty) return const [];
  return raw.split('&');
}

List<String>? _guard(Map<String, dynamic> rule) {
  final match = RegExp(
    r"if \(cls && \[(.*?)\]\.indexOf\(cls\) < 0\) cls = '';",
    dotAll: true,
  ).firstMatch('${rule['find_rule'] ?? ''}');
  if (match == null) return null;
  return match
      .group(1)!
      .split(',')
      .map((part) => part.trim().replaceAll("'", ''))
      .where((part) => part.isNotEmpty)
      .toList();
}

String _normalized(String code) {
  var text = code.trim();
  if (text.startsWith('js:')) text = text.substring(3);
  return text.replaceAll(RegExp(r'\s+'), '');
}

// 数学粗体字母（𝐀-𝐳）折回普通 ASCII，规则标题里有这类写法。
String _foldMathBold(String text) {
  final folded = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0x1D400 && rune <= 0x1D419) {
      folded.writeCharCode(rune - 0x1D400 + 0x41);
    } else if (rune >= 0x1D41A && rune <= 0x1D433) {
      folded.writeCharCode(rune - 0x1D41A + 0x61);
    } else {
      folded.writeCharCode(rune);
    }
  }
  return folded.toString();
}

// 标题比对键：折叠数学粗体、去掉符号（🔞、括号、空格等）后比较。
String _squash(String text) =>
    _foldMathBold(text).replaceAll(RegExp(r'[^A-Za-z0-9\u4e00-\u9fff]'), '');

// 以 /^ 开头的正则字面量（/.../，可跟 gimsuy 标志）：内容不含未转义的 /，
// 转义序列（\/、\\、\d 等）整体跳过，避免提前闭合。
// 规则生成器Pro 的标题清洗正则用 /^(…|立即播放|…)$/ 剔除该词：
// 出现在这里是清洗模式、与界面按钮无关，守卫统计时不计。
// 只认 /^ 开头的才剥离：裸 /…/ 剥离会误吞防御式 indexOf 守卫
// （前面的 / 与后面的 / 配对成段），/^ 锚定则不会。
final _anchoredRegexLiteral = RegExp(r'/\^((?:[^/\\\n]|\\.)*)/[gimsuy]*');

/// 去掉 [text] 里的 /^…/ 正则字面量片段，返回剩余文本。
String _stripAnchoredRegexLiterals(String text) =>
    text.replaceAll(_anchoredRegexLiteral, '');

void main() {
  const flagged = ['萝莉', '幼女', '未成年', '初中生', '小学生', 'loli'];
  const categoryKeys = [
    'class_name',
    'class_url',
    'area_name',
    'area_url',
    'year_name',
    'year_url',
  ];

  test('内置规则总数 158、标题唯一、每条都有标题与 fixlog', () {
    final rules = _rules();
    expect(rules, hasLength(158));
    final titles = rules.map((rule) => '${rule['title']}').toList();
    expect(titles.toSet(), hasLength(158));
    for (final rule in rules) {
      expect('${rule['title']}'.isNotEmpty, isTrue);
      expect(rule.containsKey('fixlog'), isTrue, reason: '${rule['title']}');
    }
  });

  test('3 条内置原地摘除生效：段数减一、带词段与守卫同步去掉', () {
    final rules = _rules();
    final cases = {
      '🔞AI短剧网': ('256', 43),
      '🔞AV研究院': ('65', 14),
      '🔞顶级AI色库': ('218', 75),
    };
    for (final entry in cases.entries) {
      final rule = _byTitle(rules, entry.key);
      final names = _segments(rule, 'class_name');
      final urls = _segments(rule, 'class_url');
      expect(names, hasLength(entry.value.$2), reason: entry.key);
      expect(urls, hasLength(entry.value.$2), reason: entry.key);
      expect(urls, isNot(contains(entry.value.$1)), reason: entry.key);
      for (final term in flagged) {
        expect(
          names.any((name) => name.toLowerCase().contains(term)),
          isFalse,
          reason: '${entry.key} $term',
        );
      }
      // 守卫名单与分类表同步，不留已摘 id。
      expect(_guard(rule), equals(urls), reason: entry.key);
    }
  });

  test('5 条替换生效、短剧one 恢复旧版：守卫/去广告/中转兜底各就其位', () {
    final rules = _rules();

    final fourK = _byTitle(rules, '🔞4K.AI短剧');
    expect(_segments(fourK, 'class_url'), hasLength(176));
    expect(_guard(fourK), equals(_segments(fourK, 'class_url')));
    expect('${fourK['fixlog']}', contains('176'));

    final drama69 = _byTitle(rules, '🔞69短剧');
    expect(_segments(drama69, 'class_url'), hasLength(23));
    expect(_guard(drama69), equals(_segments(drama69, 'class_url')));
    expect(_segments(drama69, 'class_url'), isNot(contains('29')));

    // 看裤X：内置 v2 的分类守卫移植过来，名单取自身分类表（已摘 76、14）。
    final kanku = _byTitle(rules, '🔞看裤X');
    expect(_segments(kanku, 'class_url'), hasLength(75));
    expect(_guard(kanku), equals(_segments(kanku, 'class_url')));
    expect(_segments(kanku, 'class_url'), isNot(contains('76')));
    expect(_segments(kanku, 'class_url'), isNot(contains('14')));
    expect('${kanku['find_rule']}', contains('clearM3u8Ad'));

    // 短剧窝：与看裤X同一处境，守卫一并移植（已摘 243、264）。
    final woju = _byTitle(rules, '🔞短剧窝');
    expect(_segments(woju, 'class_url'), hasLength(69));
    expect(_guard(woju), equals(_segments(woju, 'class_url')));
    expect(_segments(woju, 'class_url'), isNot(contains('243')));
    expect(_segments(woju, 'class_url'), isNot(contains('264')));
    expect('${woju['find_rule']}', contains('clearM3u8Ad'));

    // 短剧one：新版（Jina 中转兜底）没验过，已按用户令恢复为内置旧版 v2：
    // 16 段分类 + 守卫仍在，无 r.jina.ai，搜索字段是旧版的 searchFind。
    final one = _byTitle(rules, '🔞短剧one');
    expect(_segments(one, 'class_url'), hasLength(16));
    expect(_guard(one), equals(_segments(one, 'class_url')));
    expect('${one['find_rule']}', isNot(contains('r.jina.ai')));
    expect(one.containsKey('searchFind'), isTrue);
    expect(one.containsKey('searchfind'), isFalse);
    expect('${one['fixlog']}', contains('v2：修手机打开首页解析失败'));
    expect('${one['find_rule']}', contains('duanju.one'));

    // 中国X站：去白名单是定好的替换内容，分类表本身仍是 4 个。
    final cnx = _byTitle(rules, '🔞中国X站');
    expect(_segments(cnx, 'class_url'), hasLength(4));
    expect(_guard(cnx), isNull);
    expect('${cnx['fixlog']}', contains('去掉分类白名单'));
  });

  test('8 条门禁与 3 条整条排除未进树，91成人短剧仍是内置 v2', () {
    final titles = _rules().map((rule) => '${rule['title']}').toSet();
    for (final gated in [
      '🔞91hub',
      '🔞JavLibrary',
      'JRKAN直播',
      '🔞MissAV.js',
      '🔞UAA有爱爱',
      '🔞XOJav',
      '一个APP',
      '🔞好色TV',
      '我的主页',
      '萝莉聚合AV',
      '粉嫩小BB',
    ]) {
      expect(titles, isNot(contains(gated)), reason: gated);
    }
    final adult91 = _byTitle(_rules(), '🔞91成人短剧');
    expect(adult91['version'], 2);
  });

  test('全部分类字段无带词分类、无成人游戏/赌博分类', () {
    for (final rule in _rules()) {
      for (final key in categoryKeys) {
        final raw = '${rule[key] ?? ''}';
        if (raw.isEmpty) continue;
        for (final term in flagged) {
          expect(
            raw.toLowerCase().contains(term),
            isFalse,
            reason: '${rule['title']} $key $term',
          );
        }
        expect(raw.contains('成人游戏'), isFalse, reason: '${rule['title']} $key');
        expect(raw.contains('赌博'), isFalse, reason: '${rule['title']} $key');
        expect(raw.contains('博彩'), isFalse, reason: '${rule['title']} $key');
      }
    }
    // 唯一例外：小霸王是游戏站规则，year_name 的棋牌是游戏类型筛选。
    final xbw = _byTitle(_rules(), '小霸王');
    expect('${xbw['year_name']}', contains('棋牌'));
  });

  test('排除的频道名未进规则包', () {
    final text = File('assets/haikuo_builtin_rules.json').readAsStringSync();
    // 频道名拆段拼写，避免测试文件自身被全树 grep 命中；拼出的值就是全名。
    for (final channel in [
      'qifulao' 'shirenbis',
      'hfdtydh' 'gfdhtr',
      'gaoxiao' '854',
    ]) {
      expect(text.contains(channel), isFalse, reason: channel);
    }
  });

  test('立即播放只剩防御式改名与清洗正则，不再有播放行标题', () {
    final text = File('assets/haikuo_builtin_rules.json').readAsStringSync();
    // 正则字面量内的出现不计：标题清洗正则剔除该词，与按钮无关。
    final stripped = _stripAnchoredRegexLiterals(text);
    final total = '立即播放'.allMatches(stripped).length;
    final defensive = "indexOf('立即播放')".allMatches(stripped).length;
    expect(total, greaterThan(0));
    expect(total, defensive);
    // 全文断言：剥离不能藏住真实按钮文案。
    expect(text.contains('▶ 立即播放'), isFalse);
  });

  test('正则剥离反向对照：真实按钮文案仍被守卫抓住', () {
    // 清洗正则形应被剥离干净。
    expect(
      _stripAnchoredRegexLiterals(r'/^(播放|立即播放|分享)$/'),
      isNot(contains('立即播放')),
    );
    expect(
      _stripAnchoredRegexLiterals(r'/^(播放|立即播放|分享)$/i'),
      isNot(contains('立即播放')),
    );
    // 真实按钮文案（带 ▶ 前缀、裸标题、与正则同段）必须留下来。
    expect(
      _stripAnchoredRegexLiterals("title: '▶ 立即播放'"),
      contains('立即播放'),
    );
    expect(
      _stripAnchoredRegexLiterals('{"title":"立即播放"}'),
      contains('立即播放'),
    );
    expect(
      _stripAnchoredRegexLiterals(r'/^(播放|立即播放)$/  ▶ 立即播放'),
      contains('立即播放'),
    );
    // 防御式改名守卫本身不能被剥离吞掉。
    expect(
      _stripAnchoredRegexLiterals(
        "if (label.indexOf('立即播放') >= 0) label = '第1集';",
      ),
      contains("indexOf('立即播放')"),
    );
  });

  test('模块清单 16 条规则 26 个文件齐全，21 个已内联进 pages', () {
    final manifest =
        jsonDecode(
              File('assets/haikuo_modules_manifest.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final rules = manifest['rules'] as Map<String, dynamic>;
    expect(rules, hasLength(16));
    final listed = <String>{
      for (final files in rules.values) ...(files as List).cast<String>(),
    };
    expect(listed, hasLength(26));
    for (final file in listed) {
      expect(
        File('assets/haikuo_modules/$file').existsSync(),
        isTrue,
        reason: file,
      );
    }
    final notInlined = <String>{
      for (final files
          in (manifest['notInlined'] as Map<String, dynamic>).values)
        ...(files as List).cast<String>(),
    };
    expect(notInlined, hasLength(5));

    // 已内联的模块：文件内容与规则 pages 里对应子页逐字一致（去空白后）。
    final builtin = _rules();
    for (final entry in rules.entries) {
      final want = _squash(entry.key);
      final rule = builtin.firstWhere(
        (item) => _squash('${item['title']}') == want,
        orElse: () => throw StateError('规则未进树：${entry.key}'),
      );
      var pages = rule['pages'];
      if (pages is String) pages = jsonDecode(pages);
      final pageRules = <String>[
        for (final page in (pages as List))
          if (page is Map) '${page['rule'] ?? ''}',
      ];
      for (final file in (entry.value as List).cast<String>()) {
        if (notInlined.contains(file)) continue;
        final content = File('assets/haikuo_modules/$file').readAsStringSync();
        expect(
          pageRules.map(_normalized),
          contains(_normalized(content)),
          reason: '$file 未内联进 ${entry.key} 的 pages',
        );
      }
    }
  });
}
