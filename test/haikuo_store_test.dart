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
}
