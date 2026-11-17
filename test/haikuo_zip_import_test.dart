import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';
import 'package:moyi/miniapp/haikuo/haikuo_zip_import.dart';

Map<String, dynamic> _rule(String title) => {
  'title': title,
  'type': 'video',
  'url': 'hiker://empty##https://example.com/$title',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([{title: "$title"}]);',
};

List<int> _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _jsonBytes(Object value) =>
    utf8.encode(jsonEncode(value));

/// 带 SQLite 魔数的假数据库文件内容（真正读表走注入的假 reader）。
List<int> _fakeDbBytes() => [
  ...utf8.encode('SQLite format 3\x00'),
  1, 2, 3, 4,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-zip-import-');
    store = HaikuoStore(rootOverride: temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> writeZip(String name, List<int> bytes) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  bool hasLeftoverWorkDir() {
    return temp
        .listSync()
        .any(
          (entity) =>
              entity is Directory &&
              entity.path.split('/').last.startsWith('zip_import_'),
        );
  }

  test('JSON 规则 zip：单对象 + 数组 + 套一层文件夹都能导入', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'one.json': _jsonBytes(_rule('甲')),
        'wrap/two.json': _jsonBytes([_rule('乙'), _rule('丙')]),
        'wrap/readme.txt': utf8.encode('这是一段说明，不是规则'),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 3);
    expect(result.skipped, 0);
    expect(result.failed, 0);
    expect(
      (await store.list()).map((p) => p.name).toSet(),
      {'甲', '乙', '丙'},
    );
    expect(hasLeftoverWorkDir(), isFalse);
  });

  test('数据库导入：行转规则，列名映射正确', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({'hiker_54.db': _fakeDbBytes()}),
    );
    final importer = HaikuoZipImporter(
      store,
      dbReader: (file) async => [
        {
          'title': '库规则',
          'url': 'hiker://empty',
          'find_rule': 'js:\nsetResult([]);',
          'searchfind': 'a&&Text',
          'firstheader': 'class',
          'group_lpcolumn': '①推荐',
          'version': 7,
        },
        {'title': '', 'find_rule': 'js:\nsetResult([]);'},
      ],
    );
    final result = await importer.importZipFile(zip);
    expect(result.added, 1);
    expect(result.failed, 0);
    final program = (await store.list()).single;
    expect(program.name, '库规则');
    expect(program.group, '①推荐');
    expect(program.version, '7');
    final raw = jsonDecode(program.rawJson) as Map<String, dynamic>;
    expect(raw['searchFind'], 'a&&Text');
    expect(raw['firstHeader'], 'class');
  });

  test('嵌套 rules.zip：模块文件落到对应规则的私有文件区', () async {
    final inner = _zip({
      'files/甲规则/require.json': utf8.encode('{"a":1}'),
      'files/甲规则/data.txt': utf8.encode('模块数据'),
    });
    final dataInner = _zip({'data/hxc.js': utf8.encode('/* shared */')});
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'rules.zip': inner,
        'data.zip': dataInner,
        '甲规则.json': _jsonBytes(_rule('甲规则')),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 1);
    expect(result.moduleFiles, 3);
    final root = await store.root;
    final requireBytes = await HaikuoRuleFiles.readRuleFile(
      root,
      '甲规则',
      'require.json',
    );
    expect(utf8.decode(requireBytes!), '{"a":1}');
    // 共享模块：任意规则标题都能取到。
    final sharedBytes = await HaikuoRuleFiles.readRuleFile(
      root,
      '甲规则',
      'hxc.js',
    );
    expect(utf8.decode(sharedBytes!), '/* shared */');
    // 落盘位置：rule_files/<标题编码>/文件名。
    expect(
      File(
        '${temp.path}/rule_files/${Uri.encodeComponent('甲规则')}/data.txt',
      ).existsSync(),
      isTrue,
    );
  });

  test('去重：同标题已存在则跳过，内置规则绝不被覆盖', () async {
    await store.importText(jsonEncode(_rule('甲')), origin: '内置规则');
    final original = (await store.list()).single;
    final changed = _rule('甲')
      ..['find_rule'] = 'js:\nsetResult([{title: "被改过"}]);';
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'a.json': _jsonBytes(changed),
        'b.json': _jsonBytes(_rule('乙')),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 1);
    expect(result.skipped, 1);
    final programs = await store.list();
    expect(programs, hasLength(2));
    final kept = programs.firstWhere((p) => p.name == '甲');
    expect(kept.id, original.id);
    expect(kept.origin, '内置规则');
    expect(kept.script, original.script);
  });

  test('损坏的 zip 报明错、零入库', () async {
    final zip = await writeZip('bad.zip', utf8.encode('这根本不是 zip'));
    await expectLater(
      HaikuoZipImporter(store).importZipFile(zip),
      throwsA(
        isA<HaikuoFormatException>().having(
          (e) => e.message,
          'message',
          contains('不是 zip'),
        ),
      ),
    );
    expect(await store.list(), isEmpty);
    expect(hasLeftoverWorkDir(), isFalse);
  });

  test('坏数据库是唯一内容时报明错、零入库', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({'bad.db': utf8.encode('not a sqlite file at all')}),
    );
    await expectLater(
      HaikuoZipImporter(store).importZipFile(zip),
      throwsA(
        isA<HaikuoFormatException>().having(
          (e) => e.message,
          'message',
          contains('不是 SQLite'),
        ),
      ),
    );
    expect(await store.list(), isEmpty);
  });

  test('数据库读表失败时记失败、其余 JSON 照常导入', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'hiker_54.db': _fakeDbBytes(),
        'ok.json': _jsonBytes(_rule('甲')),
      }),
    );
    final importer = HaikuoZipImporter(
      store,
      dbReader: (file) async => throw const HaikuoFormatException(
        '数据库里没有找到规则表 articlelistrule',
      ),
    );
    final result = await importer.importZipFile(zip);
    expect(result.added, 1);
    expect(result.failed, 1);
    expect(result.firstError, contains('articlelistrule'));
  });

  test('损坏的规则 JSON 记失败、其余照常导入', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'bad.json': utf8.encode('{"title": "坏的", '),
        'ok.json': _jsonBytes(_rule('甲')),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 1);
    expect(result.failed, 1);
    expect(result.firstError, contains('bad.json'));
  });

  test('模块无对应规则时跳过并记注', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'ok.json': _jsonBytes(_rule('甲')),
        'files/不存在的规则/mod.js': utf8.encode('x'),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 1);
    expect(result.moduleFiles, 0);
    expect(result.notes.any((note) => note.contains('无对应规则')), isTrue);
  });

  test('进度回调会触发各阶段', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({'ok.json': _jsonBytes(_rule('甲'))}),
    );
    final phases = <String>[];
    await HaikuoZipImporter(store).importZipFile(
      zip,
      onProgress: (progress) => phases.add(progress.phase),
    );
    expect(phases.any((phase) => phase.contains('解压')), isTrue);
    expect(phases.any((phase) => phase.contains('解析')), isTrue);
    expect(phases.any((phase) => phase.contains('入库')), isTrue);
  });

  test('备份内同名重复只留第一份', () async {
    final zip = await writeZip(
      'backup.zip',
      _zip({
        'a.json': _jsonBytes(_rule('甲')),
        'b.json': _jsonBytes(_rule('甲')),
      }),
    );
    final result = await HaikuoZipImporter(store).importZipFile(zip);
    expect(result.added, 1);
    expect(result.skipped, 1);
    expect(await store.list(), hasLength(1));
  });

  testWidgets('小程序页更多菜单里有 zip 备份导入入口', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: HaikuoHomePage(store: store)));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    await tester.tap(find.byTooltip('更多导入方式'));
    await tester.pumpAndSettle();
    // 菜单项与空态按钮同名：只断言菜单里的那一项。
    expect(
      find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.text('zip 备份导入'),
      ),
      findsOneWidget,
    );
  });
}
