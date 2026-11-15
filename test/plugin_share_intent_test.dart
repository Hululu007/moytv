import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
import 'package:moyi/plugin_share_intent.dart';

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
}
