import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/plugin_share_intent.dart';
import 'package:moyi/zip_install.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

List<int> _zipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

ImportOutcome _ok(ImportCandidate candidate) => ImportOutcome(
  fileName: candidate.name,
  status: ImportOutcomeStatus.success,
  reason: 'ok',
  siteName: candidate.name,
);

ImportOutcome _failed(ImportCandidate candidate) => ImportOutcome(
  fileName: candidate.name,
  status: ImportOutcomeStatus.failed,
  reason: 'bad',
);

ImportOutcome _okName(String fileName) => ImportOutcome(
  fileName: fileName,
  status: ImportOutcomeStatus.success,
  reason: 'ok',
  siteName: fileName,
);

class _RecordingInstaller {
  final calls = <List<ImportCandidate>>[];
  ImportOutcome Function(ImportCandidate candidate) outcomeFor = _ok;

  Future<ImportReport> call(List<ImportCandidate> candidates) async {
    calls.add(candidates);
    return ImportReport([
      for (final candidate in candidates) outcomeFor(candidate),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decidePluginShareRoute', () {
    test('jar/py/zip 小写后缀路由到安装', () {
      expect(
        decidePluginShareRoute('content://x/a.jar'),
        PluginShareDecision.installJar,
      );
      expect(
        decidePluginShareRoute('content://x/a.py'),
        PluginShareDecision.installPy,
      );
      expect(
        decidePluginShareRoute('content://x/a.zip'),
        PluginShareDecision.installZip,
      );
    });

    test('大写后缀路由到安装', () {
      expect(
        decidePluginShareRoute('content://x/A.JAR'),
        PluginShareDecision.installJar,
      );
      expect(
        decidePluginShareRoute('content://x/A.Py'),
        PluginShareDecision.installPy,
      );
      expect(
        decidePluginShareRoute('content://x/A.ZIP'),
        PluginShareDecision.installZip,
      );
    });

    test('带查询参数与 fragment 的 content URI 路由到安装', () {
      expect(
        decidePluginShareRoute(
          'content://com.example.provider/docs/my-plugin.zip?token=abc#frag',
        ),
        PluginShareDecision.installZip,
      );
      expect(
        decidePluginShareRoute('file:///sdcard/Download/a.jar?x=1'),
        PluginShareDecision.installJar,
      );
    });

    test('显示名后缀优先于不透明 URI', () {
      expect(
        decidePluginShareRoute(
          'content://com.example.provider/document/12345',
          fileName: 'plugin.jar',
        ),
        PluginShareDecision.installJar,
      );
    });

    test('显示名无后缀时回落到 URI 后缀', () {
      expect(
        decidePluginShareRoute(
          'content://x/plugin.py',
          fileName: '12345',
        ),
        PluginShareDecision.installPy,
      );
    });

    test('txt/apk/json/js 拒绝', () {
      for (final uri in [
        'content://x/a.txt',
        'content://x/a.apk',
        'content://x/a.json',
        'content://x/a.js',
      ]) {
        expect(decidePluginShareRoute(uri), PluginShareDecision.reject);
      }
      expect(
        decidePluginShareRoute('content://x/123', fileName: 'a.txt'),
        PluginShareDecision.reject,
      );
    });

    test('无后缀与末尾是点拒绝', () {
      expect(
        decidePluginShareRoute('content://x/12345'),
        PluginShareDecision.reject,
      );
      expect(decidePluginShareRoute(''), PluginShareDecision.reject);
      expect(
        decidePluginShareRoute('content://x/a.'),
        PluginShareDecision.reject,
      );
    });
  });

  group('pluginShareInstallName', () {
    test('优先用显示名', () {
      expect(
        pluginShareInstallName('content://x/123', 'my plugin.jar'),
        'my plugin.jar',
      );
    });

    test('显示名无后缀时用 URI 最后一段并解开百分号编码', () {
      expect(
        pluginShareInstallName('content://x/my%20plugin.jar', '123'),
        'my plugin.jar',
      );
    });
  });

  group('PluginShareInstallRunner', () {
    test('py 走注入的安装函数并透传成功结果', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final report = await runner.install('a.py', [1, 2, 3]);
      expect(installer.calls, hasLength(1));
      expect(installer.calls.single.single.name, 'a.py');
      expect(installer.calls.single.single.bytes, [1, 2, 3]);
      expect(report.successCount, 1);
      expect(report.failedCount, 0);
      expect(report.duplicateCount, 0);
    });

    test('安装函数返回失败时透传失败分支', () async {
      final installer = _RecordingInstaller()..outcomeFor = _failed;
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final report = await runner.install('a.py', [1]);
      expect(report.failedCount, 1);
      expect(
        report.outcomes.single.status,
        ImportOutcomeStatus.failed,
      );
    });

    test('已安装的同款 jar 跳过且不调安装函数', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => '已装Jar',
      );
      final report = await runner.install('a.jar', [1, 2]);
      expect(installer.calls, isEmpty);
      expect(report.duplicateCount, 1);
      expect(report.outcomes.single.siteName, '已装Jar');
      expect(report.outcomes.single.reason, contains('已安装'));
    });

    test('未安装的 jar 走安装函数', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final report = await runner.install('a.jar', [1, 2]);
      expect(installer.calls, hasLength(1));
      expect(report.successCount, 1);
    });

    test('非插件后缀拒绝且不调安装函数', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final report = await runner.install('a.txt', [1]);
      expect(installer.calls, isEmpty);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, '不是插件文件');
    });

    test('zip 多文件逐个安装逐个汇报', () async {
      final installer = _RecordingInstaller()
        ..outcomeFor = (candidate) =>
            candidate.name == 'b_site.py' ? _failed(candidate) : _ok(candidate);
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final bytes = _zipBytes({
        'a_site.py': [1],
        'b_site.py': [2],
      });
      final report = await runner.install('pack.zip', bytes);
      expect(installer.calls, hasLength(1));
      expect(
        installer.calls.single.map((c) => c.name),
        ['a_site.py', 'b_site.py'],
      );
      expect(report.successCount, 1);
      expect(report.failedCount, 1);
      expect(report.outcomes[0].fileName, 'a_site.py');
      expect(report.outcomes[1].fileName, 'b_site.py');
    });

    test('zip 单 jar 走既有 zip 包路径：传原始 zip 字节与 zip 文件名', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final bytes = _zipBytes({
        'only.jar': [0x50, 0x4B, 1],
      });
      final report = await runner.install('pack.zip', bytes);
      expect(installer.calls, hasLength(1));
      expect(installer.calls.single.single.name, 'pack.zip');
      expect(installer.calls.single.single.bytes, bytes);
      expect(report.successCount, 1);
    });

    test('zip 里没有插件文件时失败且不调安装函数', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final bytes = _zipBytes({
        'readme.txt': [1],
      });
      final report = await runner.install('pack.zip', bytes);
      expect(installer.calls, isEmpty);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, contains('没有找到'));
    });

    test('不是 zip 的字节解包失败', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final report = await runner.install('pack.zip', [1, 2, 3]);
      expect(installer.calls, isEmpty);
      expect(report.failedCount, 1);
      expect(report.outcomes.single.reason, contains('解包失败'));
    });

    test('zip 里已安装的 jar 跳过、其余照常安装', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => '已装Jar',
      );
      final bytes = _zipBytes({
        'a.jar': [0x50, 0x4B, 1],
        'b.py': [2],
      });
      final report = await runner.install('pack.zip', bytes);
      expect(
        installer.calls.single.map((c) => c.name),
        ['b.py'],
      );
      expect(report.duplicateCount, 1);
      expect(report.successCount, 1);
      expect(report.outcomes[0].fileName, 'a.jar');
      expect(
        report.outcomes[0].status,
        ImportOutcomeStatus.duplicate,
      );
    });

    test('zip 包内同款 jar 第二个跳过', () async {
      final installer = _RecordingInstaller();
      final runner = PluginShareInstallRunner(
        importCandidates: installer.call,
        jarDuplicateCheck: (_) => null,
      );
      final sameJar = [0x50, 0x4B, 1, 2];
      final bytes = _zipBytes({'a.jar': sameJar, 'b.jar': sameJar});
      final report = await runner.install('pack.zip', bytes);
      expect(
        installer.calls.single.map((c) => c.name),
        ['a.jar'],
      );
      expect(report.duplicateCount, 1);
      expect(report.outcomes[1].reason, contains('包内另一同款'));
    });
  });

  group('PluginShareChannel', () {
    test('通道名固定为 moyi/plugin_share', () {
      expect(pluginShareChannelName, 'moyi/plugin_share');
    });

    test('takePending 解析队列并过滤空 URI；readBytes 传 URI 取字节', () async {
      const channel = MethodChannel(pluginShareChannelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'takePending') {
          return [
            {'uri': 'content://x/plugin.jar', 'name': 'plugin.jar'},
            {'uri': '', 'name': 'empty.jar'},
          ];
        }
        if (call.method == 'readBytes') {
          return Uint8List.fromList([1, 2, 3]);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final shareChannel = PluginShareChannel();
      final pending = await shareChannel.takePending();
      expect(pending, hasLength(1));
      expect(pending.first.uri, 'content://x/plugin.jar');
      expect(pending.first.name, 'plugin.jar');
      final bytes = await shareChannel.readBytes('content://x/plugin.jar');
      expect(bytes, [1, 2, 3]);
      expect(
        calls.map((call) => call.method),
        ['takePending', 'readBytes'],
      );
      expect(calls[1].arguments, {'uri': 'content://x/plugin.jar'});
    });

    test('PluginShareFile.fromJson 缺字段时给空串', () {
      final file = PluginShareFile.fromJson({});
      expect(file.uri, isEmpty);
      expect(file.name, isEmpty);
    });
  });

  group('sniffPluginShareContent', () {
    test('PK 头判 archive', () {
      expect(
        sniffPluginShareContent([0x50, 0x4B, 0x03, 0x04, 1, 2]),
        PluginShareSniff.archive,
      );
      final zip = _zipBytes({
        'a.py': [1],
      });
      expect(sniffPluginShareContent(zip), PluginShareSniff.archive);
    });

    test('含 class Spider 的文本判 py', () {
      final bytes = utf8.encode(
        'import json\n\nclass Spider:\n    pass\n',
      );
      expect(sniffPluginShareContent(bytes), PluginShareSniff.installPy);
    });

    test('BOM 开头且含 class Spider 的文本判 py', () {
      final bytes = <int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('class Spider:\n    pass\n'),
      ];
      expect(sniffPluginShareContent(bytes), PluginShareSniff.installPy);
    });

    test('import 开头且通篇含 Spider 判 py', () {
      final bytes = utf8.encode(
        'import requests\n\n# Spider 工具函数\nx = 1\n',
      );
      expect(sniffPluginShareContent(bytes), PluginShareSniff.installPy);
    });

    test('import 开头但与 Spider 无关不判 py', () {
      final bytes = utf8.encode('import os\nprint(os.name)\n');
      expect(sniffPluginShareContent(bytes), PluginShareSniff.unknown);
    });

    test('JSON 对象与数组判 json（带空白/BOM）', () {
      expect(
        sniffPluginShareContent(utf8.encode('  {"a":1}')),
        PluginShareSniff.installJson,
      );
      expect(
        sniffPluginShareContent(utf8.encode('\n\t[1,2]')),
        PluginShareSniff.installJson,
      );
      final bomJson = <int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('{"a":1}'),
      ];
      expect(sniffPluginShareContent(bomJson), PluginShareSniff.installJson);
    });

    test('普通文本与二进制乱码判 unknown', () {
      expect(
        sniffPluginShareContent(utf8.encode('hello world\n')),
        PluginShareSniff.unknown,
      );
      expect(
        sniffPluginShareContent([0, 1, 2, 3, 255, 254, 128]),
        PluginShareSniff.unknown,
      );
      expect(sniffPluginShareContent([]), PluginShareSniff.unknown);
    });
  });

  group('pluginShareSniffedName', () {
    test('无后缀名直接拼后缀', () {
      expect(pluginShareSniffedName('12345', 'py'), '12345.py');
    });

    test('旧后缀被替换掉', () {
      expect(pluginShareSniffedName('import.bin', 'py'), 'import.py');
      expect(pluginShareSniffedName('a.txt', 'jar'), 'a.jar');
    });

    test('空名用 import 兜底', () {
      expect(pluginShareSniffedName('', 'zip'), 'import.zip');
      expect(pluginShareSniffedName('   ', 'py'), 'import.py');
    });
  });

  group('PluginShareIntent 内容嗅探与排空重试', () {
    Future<_RecordingInstaller> startWithPendingPy(
      WidgetTester tester, {
      required GlobalKey<NavigatorState> navigatorKey,
      required LocalStore store,
    }) async {
      final pyBytes = utf8.encode('import json\n\nclass Spider:\n    pass\n');
      const channel = MethodChannel(pluginShareChannelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var pendingTaken = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'takePending') {
          if (pendingTaken) return <Map<String, dynamic>>[];
          pendingTaken = true;
          return [
            {'uri': 'content://x/12345', 'name': '12345'},
          ];
        }
        if (call.method == 'readBytes') {
          return Uint8List.fromList(pyBytes);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final installer = _RecordingInstaller();
      PluginShareIntent.start(
        store: store,
        repository: FixtureRepository(),
        navigatorKey: navigatorKey,
        runner: PluginShareInstallRunner(
          importCandidates: installer.call,
          jarDuplicateCheck: (_) => null,
        ),
        zipInstaller: ZipPickInstaller(
          importCandidates: (candidates) async => ImportReport([
            for (final candidate in candidates) _ok(candidate),
          ]),
          installLiveList: (item) async => _okName(item.name),
          installMiniApp: (item) async => _okName(item.name),
          jarDuplicateCheck: (_) => null,
        ),
      );
      return installer;
    }

    Future<LocalStore> newStore() async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      addTearDown(PluginShareIntent.resetForTest);
      return store;
    }

    testWidgets('无后缀名的 py 文件经内容嗅探按 .py 安装', (tester) async {
      final store = await newStore();
      final navigatorKey = GlobalKey<NavigatorState>();
      final installer = await startWithPendingPy(
        tester,
        navigatorKey: navigatorKey,
        store: store,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.pumpAndSettle();
      expect(installer.calls, hasLength(1));
      expect(installer.calls.single.single.name, '12345.py');
      // 排空成功提示 SnackBar 的计时器，避免残留计时器让用例收尾失败。
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('界面未就绪时排空早退，界面就绪后靠重试自动装上', (tester) async {
      final store = await newStore();
      final navigatorKey = GlobalKey<NavigatorState>();
      final installer = await startWithPendingPy(
        tester,
        navigatorKey: navigatorKey,
        store: store,
      );
      // 先挂一个没接 navigatorKey 的界面：首帧排空拿不到 context，
      // 应当早退并安排重试，而不是把文件丢在队列里没人管。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('no key'))),
      );
      await tester.pump();
      expect(installer.calls, isEmpty);
      // 换上接了 navigatorKey 的界面（模拟冷启动界面随后就绪）；
      // 重试还没到点时不该装，重试触发后自动排空装上。
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(installer.calls, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump();
      expect(installer.calls, hasLength(1));
      expect(installer.calls.single.single.name, '12345.py');
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
