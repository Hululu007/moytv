import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/plugin_share_intent.dart';
import 'package:moyi/zip_contents.dart';
import 'package:moyi/zip_install.dart';
import 'package:moyi/zip_pick_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

List<int> _zipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

List<int> _text(String value) => utf8.encode(value);

const _validPy = '''
class Spider:
    def getName(self):
        return "x"
    def init(self, extend=""):
        pass
    def homeContent(self, filter):
        return {}
    def homeVideoContent(self):
        return {}
    def categoryContent(self, tid, pg, filter, extend):
        return {}
    def detailContent(self, ids):
        return {}
    def searchContent(self, key, quick, pg=1):
        return {}
    def playerContent(self, flag, id, vipFlags):
        return {}
''';

const _m3u = '''
#EXTM3U
#EXTINF:-1 tvg-logo="x" group-title="央视",CCTV1
http://example.com/a.m3u8
#EXTINF:-1 group-title="央视",CCTV2
http://example.com/b.m3u8
''';

const _manifestJson =
    '{"appId":"com.example.demo","name":"演示小程序","entry":"index.html"}';

ZipPickItem _item(
  String key,
  ZipItemKind kind,
  ZipInstallKind installKind, {
  String name = '',
  List<int> bytes = const [1],
}) => ZipPickItem(
  key: key,
  name: name.isEmpty ? key : name,
  archivePath: key,
  kind: kind,
  detail: 'test',
  installKind: installKind,
  installName: key,
  bytes: bytes,
);

ImportOutcome _okOutcome(String fileName) => ImportOutcome(
  fileName: fileName,
  status: ImportOutcomeStatus.success,
  reason: 'ok',
);

void main() {
  group('inspectZipBytes 分类', () {
    test('三种形态与无法识别', () {
      final bytes = _zipBytes({
        'site.py': _text(_validPy),
        'bad.py': _text('print("hi")'),
        'lib.jar': [0x50, 0x4B, 0x03, 0x04, 1],
        'bad.jar': [1, 2, 3],
        'list.m3u': _text(_m3u),
        'list.txt': _text('CCTV1,http://example.com/a.m3u8\n'),
        'note.txt': _text('hello world\n'),
        'rule.js': _text('function homeContent() {}\nvar rule = {};'),
        'junk.js': _text('var x = 1;'),
        'xbpq.json': _text('{"站名":"x","主页url":"http://a"}'),
        'tvbox.json': _text('{"sites":[]}'),
        'custom.json': _text('[{"name":"a"}]'),
        'broken.json': _text('{oops'),
        'photo.png': [9, 9],
        '__MACOSX__/skip.py': _text(_validPy),
        '.hidden.py': _text(_validPy),
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      final kinds = {
        for (final item in inspection.items) item.name: item.kind,
      };
      expect(kinds['site.py'], ZipItemKind.videoSource);
      expect(kinds['lib.jar'], ZipItemKind.videoSource);
      expect(kinds['list.m3u'], ZipItemKind.liveList);
      expect(kinds['list.txt'], ZipItemKind.liveList);
      expect(kinds['rule.js'], ZipItemKind.component);
      expect(kinds['xbpq.json'], ZipItemKind.component);
      expect(kinds['tvbox.json'], ZipItemKind.component);
      expect(kinds['custom.json'], ZipItemKind.component);
      expect(kinds['bad.py'], ZipItemKind.unknown);
      expect(kinds['bad.jar'], ZipItemKind.unknown);
      expect(kinds['note.txt'], ZipItemKind.unknown);
      expect(kinds['junk.js'], ZipItemKind.unknown);
      expect(kinds['broken.json'], ZipItemKind.unknown);
      expect(kinds['photo.png'], ZipItemKind.unknown);
      expect(kinds.containsKey('skip.py'), isFalse);
      expect(kinds.containsKey('.hidden.py'), isFalse);
      for (final item in inspection.items) {
        if (item.kind == ZipItemKind.unknown) {
          expect(item.installable, isFalse);
          expect(item.unrecognizedReason, isNotEmpty);
        } else {
          expect(item.installable, isTrue);
        }
      }
      final m3u = inspection.items.firstWhere(
        (item) => item.name == 'list.m3u',
      );
      expect(m3u.detail, contains('2 个频道'));
      expect(m3u.installKind, ZipInstallKind.liveList);
      expect(
        inspection.itemsOf(ZipItemKind.videoSource),
        hasLength(2),
      );
      expect(inspection.itemsOf(ZipItemKind.liveList), hasLength(2));
      expect(inspection.itemsOf(ZipItemKind.component), hasLength(4));
    });

    test('同名文件用完整路径区分', () {
      final bytes = _zipBytes({
        'one/x.py': _text(_validPy),
        'two/x.py': _text(_validPy),
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(
        inspection.items.map((item) => item.name).toList(),
        ['one/x.py', 'two/x.py'],
      );
    });

    test('单 jar + 配置 JSON 折成整包一条', () {
      final bytes = _zipBytes({
        'only.jar': [0x50, 0x4B, 0x03, 0x04],
        'config.json': _text(
          '{"sites":[{"key":"k","name":"n","api":"com.x.Spider","ext":""}]}',
        ),
        'readme.txt': _text('readme'),
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(inspection.items, hasLength(1));
      final item = inspection.items.single;
      expect(item.kind, ZipItemKind.videoSource);
      expect(item.installName, 'pack.zip');
      expect(item.bytes, bytes);
      expect(item.detail, contains('整体安装'));
    });

    test('单 jar 独自成包', () {
      final bytes = _zipBytes({
        'only.jar': [0x50, 0x4B, 0x03, 0x04],
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(inspection.items, hasLength(1));
      expect(inspection.items.single.installName, 'pack.zip');
    });

    test('jar 加直播列表时拆开列', () {
      final bytes = _zipBytes({
        'only.jar': [0x50, 0x4B, 0x03, 0x04],
        'list.m3u': _text(_m3u),
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(inspection.items, hasLength(2));
      expect(
        inspection.items.map((item) => item.kind).toSet(),
        {ZipItemKind.videoSource, ZipItemKind.liveList},
      );
      expect(
        inspection.items
            .firstWhere((item) => item.kind == ZipItemKind.videoSource)
            .installName,
        'only.jar',
      );
    });

    test('内嵌小程序 zip 与内嵌 jar 包 zip', () {
      final miniappZip = _zipBytes({
        'manifest.json': _text(_manifestJson),
        'index.html': _text('<html></html>'),
      });
      final jarZip = _zipBytes({
        'inner.jar': [0x50, 0x4B, 0x03, 0x04],
      });
      final junkZip = _zipBytes({'readme.txt': _text('hi')});
      final bytes = _zipBytes({
        'app.zip': miniappZip,
        'bundle.zip': jarZip,
        'junk.zip': junkZip,
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      final kinds = {
        for (final item in inspection.items) item.name: item.kind,
      };
      expect(kinds['app.zip'], ZipItemKind.component);
      expect(kinds['bundle.zip'], ZipItemKind.videoSource);
      expect(kinds['junk.zip'], ZipItemKind.unknown);
      expect(
        inspection.items
            .firstWhere((item) => item.name == 'app.zip')
            .installKind,
        ZipInstallKind.miniappZip,
      );
    });

    test('小程序文件夹折成一条、py 不卷入', () {
      final bytes = _zipBytes({
        'demo/manifest.json': _text(_manifestJson),
        'demo/index.html': _text('<html></html>'),
        'demo/style.css': _text('body {}'),
        'site.py': _text(_validPy),
      });
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(inspection.items, hasLength(2));
      final group = inspection.items.firstWhere(
        (item) => item.kind == ZipItemKind.component,
      );
      expect(group.name, '演示小程序');
      expect(group.detail, contains('3 个文件'));
      expect(group.installKind, ZipInstallKind.miniappZip);
      // 重打包的 zip 里 manifest 在根上，小程序安装器能直接认。
      final archive = ZipDecoder().decodeBytes(group.bytes);
      expect(
        archive.files.map((file) => file.name).toSet(),
        {'manifest.json', 'index.html', 'style.css'},
      );
      expect(
        inspection.items
            .firstWhere((item) => item.kind == ZipItemKind.videoSource)
            .name,
        'site.py',
      );
    });

    test('单份 manifest.json 走清单安装', () {
      final bytes = _zipBytes({'manifest.json': _text(_manifestJson)});
      final inspection = inspectZipBytes(bytes, zipName: 'pack.zip');
      expect(inspection.items, hasLength(1));
      expect(inspection.items.single.kind, ZipItemKind.component);
      expect(
        inspection.items.single.installKind,
        ZipInstallKind.miniappManifest,
      );
    });

    test('非 zip 抛错、空 zip 无条目', () {
      expect(
        () => inspectZipBytes([1, 2, 3], zipName: 'pack.zip'),
        throwsA(isA<FormatException>()),
      );
      final empty = inspectZipBytes(
        _zipBytes(const {}),
        zipName: 'pack.zip',
      );
      expect(empty.items, isEmpty);
      expect(empty.hasInstallable, isFalse);
    });
  });

  group('ZipPickSelection 勾选逻辑', () {
    late List<ZipPickItem> items;

    setUp(() {
      items = [
        _item('a.py', ZipItemKind.videoSource, ZipInstallKind.importEngine),
        _item(
          'list.m3u',
          ZipItemKind.liveList,
          ZipInstallKind.liveList,
        ),
        _item(
          'rule.js',
          ZipItemKind.component,
          ZipInstallKind.importEngine,
        ),
        _item('bad.png', ZipItemKind.unknown, ZipInstallKind.importEngine),
      ];
    });

    test('默认全选可安装项、无法识别的选不中', () {
      final selection = ZipPickSelection.allInstallable(items);
      expect(selection.selectedItems(items), hasLength(3));
      expect(selection.isSelected(items.last), isFalse);
      selection.setSelected(items.last, true);
      expect(selection.isSelected(items.last), isFalse);
    });

    test('取消勾选后只装勾选的', () {
      final selection = ZipPickSelection.allInstallable(items);
      selection.toggle(items[1]);
      expect(
        selection.selectedItems(items).map((item) => item.key),
        ['a.py', 'rule.js'],
      );
      expect(selection.selectedCount(items), 2);
    });

    test('整类全选与全不选', () {
      final selection = ZipPickSelection.allInstallable(items);
      selection.selectKind(items, ZipItemKind.liveList, false);
      expect(selection.isSelected(items[1]), isFalse);
      expect(selection.isSelected(items[0]), isTrue);
      selection.selectKind(items, ZipItemKind.liveList, true);
      expect(selection.isSelected(items[1]), isTrue);
      expect(selection.allSelected(items), isTrue);
    });
  });

  group('ZipPickInstaller 只装勾选的', () {
    test('三条通道各只收到勾选的条目、顺序保留', () async {
      final imported = <ImportCandidate>[];
      final live = <ZipPickItem>[];
      final apps = <ZipPickItem>[];
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async {
          imported.addAll(candidates);
          return ImportReport([
            for (final candidate in candidates) _okOutcome(candidate.name),
          ]);
        },
        installLiveList: (item) async {
          live.add(item);
          return _okOutcome(item.name);
        },
        installMiniApp: (item) async {
          apps.add(item);
          return _okOutcome(item.name);
        },
        jarDuplicateCheck: (_) => null,
      );
      final items = [
        _item('a.py', ZipItemKind.videoSource, ZipInstallKind.importEngine),
        _item('list.m3u', ZipItemKind.liveList, ZipInstallKind.liveList),
        _item('app.zip', ZipItemKind.component, ZipInstallKind.miniappZip),
        _item('skip.py', ZipItemKind.videoSource, ZipInstallKind.importEngine),
      ];
      final selection = ZipPickSelection.allInstallable(items)
        ..toggle(items[3]);
      final report = await installer.install(
        selection.selectedItems(items),
      );
      expect(imported.map((c) => c.name), ['a.py']);
      expect(live.map((item) => item.key), ['list.m3u']);
      expect(apps.map((item) => item.key), ['app.zip']);
      expect(report.successCount, 3);
      expect(
        report.outcomes.map((outcome) => outcome.fileName),
        ['a.py', 'list.m3u', 'app.zip'],
      );
    });

    test('已安装的同款 jar 跳过、包内同款第二个跳过', () async {
      final imported = <ImportCandidate>[];
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async {
          imported.addAll(candidates);
          return ImportReport([
            for (final candidate in candidates) _okOutcome(candidate.name),
          ]);
        },
        installLiveList: (item) async => _okOutcome(item.name),
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (bytes) =>
            bytes.length == 4 ? '已装Jar' : null,
      );
      final sameJar = [0x50, 0x4B, 1, 2, 3];
      final items = [
        _item(
          'installed.jar',
          ZipItemKind.videoSource,
          ZipInstallKind.importEngine,
          bytes: [1, 2, 3, 4],
        ),
        _item(
          'a.jar',
          ZipItemKind.videoSource,
          ZipInstallKind.importEngine,
          bytes: sameJar,
        ),
        _item(
          'b.jar',
          ZipItemKind.videoSource,
          ZipInstallKind.importEngine,
          bytes: sameJar,
        ),
      ];
      final report = await installer.install(items);
      expect(imported.map((c) => c.name), ['a.jar']);
      expect(report.duplicateCount, 2);
      expect(report.successCount, 1);
      expect(
        report.outcomes[0].status,
        ImportOutcomeStatus.duplicate,
      );
      expect(report.outcomes[2].reason, contains('包内另一同款'));
    });

    test('直播安装失败只记该条、其余照常', () async {
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async => ImportReport([
          for (final candidate in candidates) _okOutcome(candidate.name),
        ]),
        installLiveList: (item) async => ImportOutcome(
          fileName: item.name,
          status: ImportOutcomeStatus.failed,
          reason: '解析失败',
        ),
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (_) => null,
      );
      final items = [
        _item('a.py', ZipItemKind.videoSource, ZipInstallKind.importEngine),
        _item('list.m3u', ZipItemKind.liveList, ZipInstallKind.liveList),
      ];
      final report = await installer.install(items);
      expect(report.successCount, 1);
      expect(report.failedCount, 1);
      expect(report.outcomes[1].reason, '解析失败');
    });

    test('混入无法识别的条目直接记失败、不调通道', () async {
      var calls = 0;
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async {
          calls++;
          return ImportReport([
            for (final candidate in candidates) _okOutcome(candidate.name),
          ]);
        },
        installLiveList: (item) async => _okOutcome(item.name),
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (_) => null,
      );
      final report = await installer.install([
        _item('bad.png', ZipItemKind.unknown, ZipInstallKind.importEngine),
      ]);
      expect(calls, 0);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, contains('无法识别'));
    });
  });

  group('ZipPickScreen 选择器界面', () {
    testWidgets('取消勾选的条目不安装、无法识别的行置灰禁用', (tester) async {
      final installed = <ZipPickItem>[];
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async {
          installed.addAll(
            candidates.map(
              (c) => _item(
                c.name,
                ZipItemKind.videoSource,
                ZipInstallKind.importEngine,
              ),
            ),
          );
          return ImportReport([
            for (final candidate in candidates) _okOutcome(candidate.name),
          ]);
        },
        installLiveList: (item) async {
          installed.add(item);
          return _okOutcome(item.name);
        },
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (_) => null,
      );
      final items = [
        _item('a.py', ZipItemKind.videoSource, ZipInstallKind.importEngine),
        _item('list.m3u', ZipItemKind.liveList, ZipInstallKind.liveList),
        _item('bad.png', ZipItemKind.unknown, ZipInstallKind.importEngine),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: ZipPickScreen(
            zipName: 'pack.zip',
            items: items,
            installer: installer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('影视源（1）'), findsOneWidget);
      expect(find.text('直播列表（1）'), findsOneWidget);
      expect(find.text('无法识别（1）'), findsOneWidget);
      // 无法识别的行：复选框禁用，点行不选中。
      final unknownTile = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('zip-pick-item-bad.png')),
      );
      expect(unknownTile.onChanged, isNull);
      expect(find.text('已选 2 项'), findsOneWidget);
      // 取消勾选直播列表，再安装。
      await tester.tap(find.byKey(const ValueKey('zip-pick-item-list.m3u')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('zip-pick-install')));
      await tester.pumpAndSettle();
      expect(installed.map((item) => item.key), ['a.py']);
      expect(find.text('安装结果'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
    });

    testWidgets('整类全不选后安装按钮禁用', (tester) async {
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async =>
            ImportReport([for (final c in candidates) _okOutcome(c.name)]),
        installLiveList: (item) async => _okOutcome(item.name),
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (_) => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ZipPickScreen(
            zipName: 'pack.zip',
            items: [
              _item(
                'a.py',
                ZipItemKind.videoSource,
                ZipInstallKind.importEngine,
              ),
            ],
            installer: installer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('zip-pick-toggle-ZipItemKind.videoSource'),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('zip-pick-install')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('入口接线', () {
    testWidgets('openZipPicker 打开选择器、解包失败只弹提示', (tester) async {
      final installer = ZipPickInstaller(
        importCandidates: (candidates) async => const ImportReport([]),
        installLiveList: (item) async => _okOutcome(item.name),
        installMiniApp: (item) async => _okOutcome(item.name),
        jarDuplicateCheck: (_) => null,
      );
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const Scaffold(body: Text('home'));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final zipBytes = _zipBytes({'site.py': _text(_validPy)});
      unawaited(
        openZipPicker(
          context: captured,
          zipName: 'pack.zip',
          zipBytes: zipBytes,
          installer: installer,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ZipPickScreen), findsOneWidget);
      expect(find.text('site.py'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(ZipPickScreen), findsNothing);

      unawaited(
        openZipPicker(
          context: captured,
          zipName: 'pack.zip',
          zipBytes: [1, 2, 3],
          installer: installer,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ZipPickScreen), findsNothing);
      expect(find.textContaining('解包失败'), findsOneWidget);
    });

    testWidgets('文件管理器 zip 经分享 intent 打开选择器、不走自动全装', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      addTearDown(PluginShareIntent.resetForTest);
      final navigatorKey = GlobalKey<NavigatorState>();
      final zipBytes = _zipBytes({
        'site.py': _text(_validPy),
        'list.m3u': _text(_m3u),
      });
      const channel = MethodChannel(pluginShareChannelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pendingTaken = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePending') {
          if (pendingTaken) return <Map<String, dynamic>>[];
          pendingTaken = true;
          return [
            {'uri': 'content://x/pack.zip', 'name': 'pack.zip'},
          ];
        }
        if (call.method == 'readBytes') {
          return Uint8List.fromList(zipBytes);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var runnerCalls = 0;
      final installedNames = <String>[];
      PluginShareIntent.start(
        store: store,
        repository: FixtureRepository(),
        navigatorKey: navigatorKey,
        runner: PluginShareInstallRunner(
          importCandidates: (candidates) async {
            runnerCalls++;
            return ImportReport([
              for (final candidate in candidates) _okOutcome(candidate.name),
            ]);
          },
          jarDuplicateCheck: (_) => null,
        ),
        zipInstaller: ZipPickInstaller(
          importCandidates: (candidates) async {
            installedNames.addAll(candidates.map((c) => c.name));
            return ImportReport([
              for (final candidate in candidates) _okOutcome(candidate.name),
            ]);
          },
          installLiveList: (item) async {
            installedNames.add(item.name);
            return _okOutcome(item.name);
          },
          installMiniApp: (item) async => _okOutcome(item.name),
          jarDuplicateCheck: (_) => null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.pumpAndSettle();
      // 选择器打开，自动全装的 runner 没被调用。
      expect(find.byType(ZipPickScreen), findsOneWidget);
      expect(runnerCalls, 0);
      expect(find.text('site.py'), findsOneWidget);
      expect(find.text('list.m3u'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('zip-pick-install')));
      await tester.pumpAndSettle();
      expect(installedNames, containsAll(['site.py', 'list.m3u']));
      expect(find.text('安装结果'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(ZipPickScreen), findsNothing);
    });
  });
}
