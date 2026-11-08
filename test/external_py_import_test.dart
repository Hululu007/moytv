import 'dart:convert';

import 'package:moyi/external_py_import.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _fullSpider = '''
class Spider:
    def getName(self): return "sample"
    def getDependence(self): return []
    def init(self, extend=""): return None
    def destroy(self): return None
    def homeContent(self, filter=None): return {}
    def homeVideoContent(self): return {}
    def categoryContent(self, tid=None, pg=1, filter=None, extend=None): return {}
    def detailContent(self, ids=None): return {}
    def searchContent(self, key=None, quick=False, pg="1"): return {}
    def playerContent(self, flag=None, id=None, vipFlags=None): return {}
    def localProxy(self, param=None): return []
    def isVideoFormat(self, url=None): return False
    def manualVideoCheck(self): return False
    def action(self, action=None): return None
''';

const _playOnlySpider = '''
class Spider:
    def getName(self): return "sample"
    def playerContent(self, flag=None, id=None, vipFlags=None): return {}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('describePyImportCandidate', () {
    test('full spider passes', () {
      final preview = describePyImportCandidate(
        'sample.py',
        utf8.encode(_fullSpider),
      );
      expect(preview.ok, isTrue);
      expect(preview.displayName, 'sample');
      expect(preview.playOnly, isFalse);
      expect(preview.reason, isEmpty);
    });

    test('missing spider class fails with reason', () {
      final preview = describePyImportCandidate(
        'plain.py',
        utf8.encode('x = 1\n'),
      );
      expect(preview.ok, isFalse);
      expect(preview.reason, contains('Spider'));
    });

    test('missing core methods without playerContent fails', () {
      const source = '''
class Spider:
    def getName(self): return "sample"
''';
      final preview = describePyImportCandidate(
        'partial.py',
        utf8.encode(source),
      );
      expect(preview.ok, isFalse);
      expect(preview.reason, contains('homeContent'));
    });

    test('playerContent alone passes as playOnly', () {
      final preview = describePyImportCandidate(
        'play.py',
        utf8.encode(_playOnlySpider),
      );
      expect(preview.ok, isTrue);
      expect(preview.playOnly, isTrue);
    });

    test('empty bytes fail', () {
      final preview = describePyImportCandidate('empty.py', const []);
      expect(preview.ok, isFalse);
    });

    test('invalid utf8 falls back to gbk decoding without crashing', () {
      final preview = describePyImportCandidate('gbk.py', const [
        0xD6,
        0xD0,
        0xCE,
        0xC4,
      ]);
      expect(preview.ok, isFalse);
      expect(preview.reason, contains('Spider'));
    });

    test('bom prefix is stripped', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(_fullSpider)];
      final preview = describePyImportCandidate('bom.py', bytes);
      expect(preview.ok, isTrue);
    });
  });

  group('ExternalPyFile.fromJson', () {
    test('parses fields', () {
      final file = ExternalPyFile.fromJson({
        'path': '/tmp/a.py',
        'name': 'a.py',
        'size': 42,
      });
      expect(file.path, '/tmp/a.py');
      expect(file.name, 'a.py');
      expect(file.size, 42);
    });

    test('missing fields default', () {
      final file = ExternalPyFile.fromJson({});
      expect(file.path, isEmpty);
      expect(file.name, isEmpty);
      expect(file.size, 0);
    });
  });

  group('ExternalPyImportChannel.takePending', () {
    const channel = MethodChannel('moyi/pyimport');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('returns parsed pending files', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'takePending') {
              return [
                {'path': '/tmp/x.py', 'name': 'x.py', 'size': 10},
                {'path': '', 'name': 'bad.py', 'size': 0},
              ];
            }
            return null;
          });
      final files = await ExternalPyImportChannel.takePending();
      expect(files.length, 1);
      expect(files.first.name, 'x.py');
    });

    test('null reply yields empty list', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final files = await ExternalPyImportChannel.takePending();
      expect(files, isEmpty);
    });
  });
}
