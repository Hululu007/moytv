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
    final bundle = jsonEncode([_builtinRule('甲', 'v1'), _builtinRule('乙', 'v1')]);
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
    expect(
      programs.firstWhere((p) => p.name == '用户自带').origin,
      '文件',
    );
  });

  test('用户删掉内置规则后不再自动补回，强制恢复才补回', () async {
    final bundle = jsonEncode([_builtinRule('甲', 'v1')]);
    await store.ensureBuiltinRules(bundleText: bundle);
    final programs = await store.list();
    await store.remove(programs.single.id);
    expect(await store.list(), isEmpty);
    expect(await store.ensureBuiltinRules(bundleText: bundle), 0);
    expect(await store.list(), isEmpty);
    expect(
      await store.ensureBuiltinRules(bundleText: bundle, force: true),
      1,
    );
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
    expect(
      await File('${temp.path}/builtin_seeded.json').exists(),
      isFalse,
    );
  });

  test('真实内置包能播种 35 条（读 asset 文件本身）', () async {
    final seeded = await store.ensureBuiltinRules();
    expect(seeded, 35);
    final programs = await store.list();
    expect(programs, hasLength(35));
    expect(programs.map((p) => p.origin).toSet(), {'内置规则'});
    expect(
      programs.map((p) => p.name).toSet(),
      containsAll(['🔞鉴黄师', '🔞黄果短剧', '🔞4K.AI短剧', '🔞草榴视频']),
    );
  });
}
