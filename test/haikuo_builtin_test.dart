import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

Map<String, dynamic> _builtinRule(String title, String mark) => {
  'title': title,
  'type': 'video',
  'author': '皇帝影院',
  'group': '🔞 成人专区',
  'url': 'hiker://empty##https://example.com/$title',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([{title: "$mark"}]);',
  'version': 1,
  'fixlog': 'v1：内置测试版。',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-builtin-');
    store = HaikuoStore(rootOverride: temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('首次播种：内置规则进库，来源标为内置规则', () async {
    final bundle = jsonEncode([
      _builtinRule('甲', 'v1'),
      _builtinRule('乙', 'v1'),
    ]);
    final seeded = await store.ensureBuiltinRules(bundleText: bundle);
    expect(seeded, 2);
    final programs = await store.list();
    expect(programs.map((p) => p.name).toSet(), {'甲', '乙'});
    expect(programs.map((p) => p.origin).toSet(), {'内置规则'});
  });

  test('第二次播种是空操作，不重复堆叠', () async {
    final bundle = jsonEncode([_builtinRule('甲', 'v1')]);
    expect(await store.ensureBuiltinRules(bundleText: bundle), 1);
    expect(await store.ensureBuiltinRules(bundleText: bundle), 0);
    expect(await store.list(), hasLength(1));
  });

  test('用户导入的规则不受播种影响', () async {
    await store.importText(
      jsonEncode([
        {
          'title': '用户自带',
          'type': 'video',
          'url': 'hiker://empty##https://example.com/user',
          'find_rule': 'js:\nsetResult([]);',
        },
      ]),
      origin: '文件',
    );
    await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v1')]),
    );
    final programs = await store.list();
    expect(programs.map((p) => p.name).toSet(), {'用户自带', '甲'});
    expect(programs.firstWhere((p) => p.name == '用户自带').origin, '文件');
  });

  test('用户删掉内置规则后不再自动补回，强制恢复才补回', () async {
    final bundle = jsonEncode([_builtinRule('甲', 'v1')]);
    await store.ensureBuiltinRules(bundleText: bundle);
    final programs = await store.list();
    await store.remove(programs.single.id);
    expect(await store.list(), isEmpty);
    expect(await store.ensureBuiltinRules(bundleText: bundle), 0);
    expect(await store.list(), isEmpty);
    expect(await store.ensureBuiltinRules(bundleText: bundle, force: true), 1);
    expect(await store.list(), hasLength(1));
  });

  test('同名规则出新版时按标题替换，不留重复项', () async {
    await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v1')]),
    );
    // 删掉版本标记，模拟内置包升级后的再次播种。
    final marker = File('${temp.path}/builtin_seeded.json');
    expect(await marker.exists(), isTrue);
    await marker.delete();
    final reseeded = await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v2')]),
    );
    expect(reseeded, 1);
    final programs = await store.list();
    expect(programs, hasLength(1));
    expect(programs.single.rawJson, contains('v2'));
  });

  test('空包不播种、不写标记', () async {
    expect(await store.ensureBuiltinRules(bundleText: '[]'), 0);
    expect(await File('${temp.path}/builtin_seeded.json').exists(), isFalse);
  });

  test('真实内置包能播种 146 条（读 asset 文件本身），23 条已删工具规则不在包里', () async {
    final seeded = await store.ensureBuiltinRules();
    expect(seeded, 146);
    final programs = await store.list();
    expect(programs, hasLength(146));
    expect(programs.map((p) => p.origin).toSet(), {'内置规则'});
    final names = programs.map((p) => p.name).toSet();
    expect(names, containsAll(['🔞鉴黄师', '🔞黄果短剧', '🔞4K.AI短剧', '🔞草榴视频']));
    // v7 删掉的 26 条工具规则（上一批用户令），除 v10 复核验过重新入包
    // 的 3 条（成人翻墙合集/查询IP地址/模板·Q：2026-11-17 用户令内置，
    // 真站补验通过，修复版可用）外，包里一个都不该有。
    const removed23 = {
      'AI软件PC',
      'AI软搜Andoird',
      'GithubApp',
      'MyFieldᴰⁿ',
      'Q',
      'undefined',
      '✨免费节点✨(增量版)',
      '✨魔曰✨',
      '书源仓库',
      '发哥专属',
      '影搜聚合',
      '心魔',
      '星集Media',
      '比价.拒绝套路',
      '游戏集𝔥',
      '破解APP',
      '聚图库',
      '聚阅',
      '聚阅√',
      '规则查重',
      '规则生成器Pro',
      '道长仓库Pro',
      '𝐉𝐌𝐂𝐨𝐦𝐢𝐜𝟐本地',
    };
    expect(names.intersection(removed23), isEmpty);
  });

  test('播种标记写当前包版本 13', () async {
    await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v1')]),
    );
    final marker = jsonDecode(
      await File('${temp.path}/builtin_seeded.json').readAsString(),
    );
    expect(marker['version'], HaikuoStore.builtinBundleVersion);
    expect(marker['version'], 13);
    expect(marker['names'], ['甲']);
  });

  test('升版清理：撤包的内置副本被清掉，用户导入的同名规则保留', () async {
    // 上一版播种过的状态：库里有内置版“甲”v1；“规则生成器Pro”与内置
    // 版内容相同、但来源是用户导入（同 id 更新会连来源一起换成“文件”，
    // 这正是“用户自己导入的同名规则”的真实形态）；标记版本 6、记了上一版标题。
    await store.importText(
      jsonEncode([_builtinRule('甲', 'v1'), _builtinRule('规则生成器Pro', 'v1')]),
      origin: '内置规则',
    );
    await store.importText(
      jsonEncode([_builtinRule('规则生成器Pro', 'v1')]),
      origin: '文件',
    );
    await File('${temp.path}/builtin_seeded.json').writeAsString(
      jsonEncode({
        'version': 6,
        'seededAt': DateTime.now().toIso8601String(),
        'names': ['甲', '规则生成器Pro'],
      }),
    );
    // 新包只有“甲”v2：规则生成器Pro 已撤包。
    final seeded = await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v2')]),
    );
    expect(seeded, 1);
    final programs = await store.list();
    expect(programs.map((p) => p.name).toSet(), {'甲', '规则生成器Pro'});
    final kept = programs.firstWhere((p) => p.name == '规则生成器Pro');
    expect(kept.origin, '文件');
    expect(kept.rawJson, contains('v1'));
    final jia = programs.firstWhere((p) => p.name == '甲');
    expect(jia.origin, '内置规则');
    expect(jia.rawJson, contains('v2'));
    final marker = jsonDecode(
      await File('${temp.path}/builtin_seeded.json').readAsString(),
    );
    expect(marker['version'], 13);
  });

  test('标记损坏时当没播种过：整包播种、不崩溃、标记重写', () async {
    await File('${temp.path}/builtin_seeded.json').writeAsString('不是 json{{{');
    final seeded = await store.ensureBuiltinRules(
      bundleText: jsonEncode([_builtinRule('甲', 'v1')]),
    );
    expect(seeded, 1);
    expect(await store.list(), hasLength(1));
    final marker = jsonDecode(
      await File('${temp.path}/builtin_seeded.json').readAsString(),
    );
    expect(marker['version'], 13);
  });
}
