import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_codec.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

Map<String, dynamic> _rule(String title) => {
  'title': title,
  'type': 'video',
  'url': 'hiker://empty##https://example.com/$title',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([{title: "$title"}]);',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-store-');
    store = HaikuoStore(rootOverride: temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('导入 JSON 文本后能列出来，并落盘', () async {
    final result = await store.importText(
      jsonEncode([_rule('甲'), _rule('乙')]),
      origin: '测试',
    );
    expect(result.added, hasLength(2));
    final programs = await store.list();
    expect(programs.map((p) => p.name).toSet(), {'甲', '乙'});
    expect(File('${temp.path}/programs.json').existsSync(), isTrue);
  });

  test('重复导入同一个小程序只更新，不重复堆叠', () async {
    final payload = jsonEncode(_rule('重复'));
    await store.importText(payload, origin: '第一次');
    final second = await store.importText(payload, origin: '第二次');
    expect(second.added, isEmpty);
    expect(second.updated, hasLength(1));
    final programs = await store.list();
    expect(programs, hasLength(1));
    expect(programs.single.origin, '第二次');
  });

  test('删除与清空', () async {
    await store.importText(jsonEncode([_rule('甲'), _rule('乙')]));
    final programs = await store.list();
    await store.remove(programs.first.id);
    expect(await store.list(), hasLength(1));
    await store.clear();
    expect(await store.list(), isEmpty);
  });

  test('口令导入：没有任何可用内容时给明确错误', () async {
    await expectLater(
      store.importText('一段随便的文字，什么也没有'),
      throwsA(isA<HaikuoFormatException>()),
    );
  });

  test('坏文件不拖垮读取：内容损坏按空库处理', () async {
    await File('${temp.path}/programs.json').writeAsString('{坏掉的');
    expect(await store.list(), isEmpty);
    // 损坏后仍能继续导入
    final result = await store.importText(jsonEncode(_rule('恢复')));
    expect(result.added, hasLength(1));
  });

  test('导出 JSON 能被再解析（往返一致）', () async {
    await store.importText(jsonEncode(_rule('往返')));
    final programs = await store.list();
    final exported = await store.exportJson(programs);
    final reparsed = HaikuoCodec.parseJsonText(exported);
    expect(reparsed.single.name, '往返');
  });

  Map<String, dynamic> ruleVersion(String title, String marker) => {
    'title': title,
    'type': 'video',
    'url': 'hiker://empty##https://example.com/$title',
    'col_type': 'movie_3',
    'find_rule': 'js:\nsetResult([{title: "$marker"}]);',
  };

  test('同名不同内容：选替换则覆盖旧的，只留一份', () async {
    await store.importText(jsonEncode(ruleVersion('同名', 'v1')));
    final seen = <HaikuoDuplicate>[];
    final result = await store.importText(
      jsonEncode(ruleVersion('同名', 'v2')),
      onDuplicates: (dups) async {
        seen.addAll(dups);
        return HaikuoDuplicateDecision.replace;
      },
    );
    expect(seen, hasLength(1));
    expect(seen.single.incoming.rawJson, contains('v2'));
    expect(seen.single.existing.rawJson, contains('v1'));
    expect(result.updated, hasLength(1));
    expect(result.added, isEmpty);
    final programs = await store.list();
    expect(programs, hasLength(1));
    expect(programs.single.name, '同名');
    expect(programs.single.rawJson, contains('v2'));
  });

  test('同名不同内容：选保留两者则新条目改名 _2，旧的不动', () async {
    await store.importText(jsonEncode(ruleVersion('同名', 'v1')));
    final result = await store.importText(
      jsonEncode(ruleVersion('同名', 'v2')),
      onDuplicates: (_) async => HaikuoDuplicateDecision.keepBoth,
    );
    expect(result.added, hasLength(1));
    final programs = await store.list();
    expect(programs.map((p) => p.name).toSet(), {'同名', '同名_2'});
    final kept = programs.firstWhere((p) => p.name == '同名_2');
    expect(kept.rawJson, contains('v2'));
    expect(
      programs.firstWhere((p) => p.name == '同名').rawJson,
      contains('v1'),
    );
    // 再来一个同名新版：_2 已被占，顺延成 _3。
    await store.importText(
      jsonEncode(ruleVersion('同名', 'v3')),
      onDuplicates: (_) async => HaikuoDuplicateDecision.keepBoth,
    );
    expect(
      (await store.list()).map((p) => p.name).toSet(),
      {'同名', '同名_2', '同名_3'},
    );
  });

  test('同名不同内容：选取消则整批都不导入', () async {
    await store.importText(jsonEncode(ruleVersion('同名', 'v1')));
    final result = await store.importText(
      jsonEncode([ruleVersion('同名', 'v2'), _rule('新来的')]),
      onDuplicates: (_) async => HaikuoDuplicateDecision.cancel,
    );
    expect(result.cancelled, isTrue);
    expect(result.total, 0);
    expect(result.summary, '已取消导入');
    final programs = await store.list();
    expect(programs, hasLength(1));
    expect(programs.single.rawJson, contains('v1'));
  });

  test('同名不同内容：不传回调时默认保留两者', () async {
    await store.importText(jsonEncode(ruleVersion('同名', 'v1')));
    await store.importText(jsonEncode(ruleVersion('同名', 'v2')));
    expect(
      (await store.list()).map((p) => p.name).toSet(),
      {'同名', '同名_2'},
    );
  });

  test('同名同内容重复导入不问重复，直接更新', () async {
    final payload = jsonEncode(ruleVersion('同名', 'v1'));
    await store.importText(payload);
    var asked = 0;
    final second = await store.importText(
      payload,
      onDuplicates: (_) async {
        asked++;
        return HaikuoDuplicateDecision.replace;
      },
    );
    expect(asked, 0);
    expect(second.updated, hasLength(1));
    expect(await store.list(), hasLength(1));
  });
}
