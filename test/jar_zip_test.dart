import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:moyi/jar_zip.dart';
import 'package:flutter_test/flutter_test.dart';

const _ytJson = '''
{"spider": "./youtube.jar", "sites": [{"key": "youtube", "name": "YouTube",
"api": "csp_YouTube", "ext": {"proxy": ""}}]}
''';

List<int> _zipOf(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(
      ArchiveFile(entry.key, entry.value.length, entry.value),
    );
  }
  return ZipEncoder().encode(archive);
}

void main() {
  group('decodeJarZipPackage', () {
    test('splits jar, site config and extra json files', () {
      final bytes = _zipOf({
        'youtube.jar': [0x50, 0x4B, 0x03, 0x04, 1, 2, 3],
        'yt.json': utf8.encode(_ytJson),
        'youtube3.json': utf8.encode('{"class": []}'),
      });
      final package = decodeJarZipPackage(bytes);
      expect(package.jarName, 'youtube.jar');
      expect(package.jarBytes, [0x50, 0x4B, 0x03, 0x04, 1, 2, 3]);
      expect(package.configs, hasLength(1));
      expect(package.configs.first.key, 'youtube');
      expect(package.configs.first.ext, '{"proxy":""}');
      expect(package.extraJsonNames, ['youtube3.json']);
      expect(package.extraJsonFiles.keys, ['youtube3.json']);
      expect(package.skippedJarNames, isEmpty);
    });

    test('nested paths keep working and jar-only zips parse', () {
      final bytes = _zipOf({
        'pkg/app.jar': [9, 9],
        'cfg/yt.json': utf8.encode(_ytJson),
      });
      final package = decodeJarZipPackage(bytes);
      expect(package.jarName, 'pkg/app.jar');
      expect(package.configs, hasLength(1));
      expect(package.extraJsonNames, isEmpty);

      final jarOnly = decodeJarZipPackage(_zipOf({'a.jar': [1]}));
      expect(jarOnly.configs, isEmpty);
      expect(jarOnly.extraJsonNames, isEmpty);
    });

    test('only the first jar is used and the rest are reported', () {
      final bytes = _zipOf({'b.jar': [2], 'a.jar': [1]});
      final package = decodeJarZipPackage(bytes);
      expect(package.jarName, 'a.jar');
      expect(package.jarBytes, [1]);
      expect(package.skippedJarNames, ['b.jar']);
    });

    test('a zip without a jar and garbage bytes both fail', () {
      expect(
        () => decodeJarZipPackage(_zipOf({'yt.json': utf8.encode(_ytJson)})),
        throwsA(isA<JarZipFailure>()),
      );
      expect(
        () => decodeJarZipPackage([1, 2, 3, 4]),
        throwsA(isA<JarZipFailure>()),
      );
    });

    test('zip magic check accepts local headers and empty archives', () {
      expect(isZipBytes([0x50, 0x4B, 0x03, 0x04]), isTrue);
      expect(isZipBytes([0x50, 0x4B, 0x05, 0x06]), isTrue);
      expect(isZipBytes([0x50, 0x4B, 0x01, 0x02]), isFalse);
      expect(isZipBytes([1, 2]), isFalse);
    });
  });
}
