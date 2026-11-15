import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/plugin_manager.dart';

List<int> _zipBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  group('expandPluginZip', () {
    test('mixed jar and py entries, junk skipped', () {
      final bytes = _zipBytes({
        'a.jar': [1],
        'sub/b.py': [2],
        'readme.txt': [3],
        'config.json': [4],
        '__MACOSX__/a.jar': [5],
        '.hidden.py': [6],
        'dir/': [],
      });
      final entries = expandPluginZip(bytes);
      expect(entries.map((e) => e.name).toList(), ['a.jar', 'b.py']);
      expect(entries.first.isJar, isTrue);
      expect(entries.last.isPy, isTrue);
    });

    test('same basename in different folders keeps full paths', () {
      final bytes = _zipBytes({
        'one/x.py': [1],
        'two/x.py': [2],
      });
      final entries = expandPluginZip(bytes);
      expect(entries.map((e) => e.name).toList(), ['one/x.py', 'two/x.py']);
    });

    test('no plugin files yields empty', () {
      expect(expandPluginZip(_zipBytes({'a.txt': [1]})), isEmpty);
    });

    test('non-zip bytes throw', () {
      expect(() => expandPluginZip([1, 2, 3]), throwsA(anything));
    });
  });
}
