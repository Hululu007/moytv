import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/plugin_manifest.dart';

List<int> _zipBytes(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  group('parsePluginManifest', () {
    test('valid manifest', () {
      const raw = '''
{"name": "测试插件", "version": "2.0", "sites": [
  {"key": "a", "name": "A 站", "api": "csp_ASpider", "ext": "{\\"x\\":1}"},
  {"key": "b", "name": "B 站", "api": "csp_BSpider", "ext": ""}
]}''';
      final manifest = parsePluginManifest(raw)!;
      expect(manifest.name, '测试插件');
      expect(manifest.version, '2.0');
      expect(manifest.sites.length, 2);
      expect(manifest.sites.first.key, 'a');
      expect(manifest.sites.first.api, 'csp_ASpider');
      expect(manifest.sites.first.ext, '{"x":1}');
    });

    test('rows without key or api are skipped', () {
      const raw = '''
{"sites": [
  {"key": "", "name": "x", "api": "csp_X", "ext": ""},
  {"key": "k", "name": "x", "api": "", "ext": ""},
  {"key": "ok", "name": "OK", "api": "csp_Ok", "ext": ""}
]}''';
      final manifest = parsePluginManifest(raw)!;
      expect(manifest.sites.map((s) => s.key).toList(), ['ok']);
    });

    test('invalid manifests yield null', () {
      expect(parsePluginManifest('not json'), isNull);
      expect(parsePluginManifest('[]'), isNull);
      expect(parsePluginManifest('{}'), isNull);
      expect(parsePluginManifest('{"sites": []}'), isNull);
      expect(parsePluginManifest('{"sites": [{"key": "k"}]}'), isNull);
    });
  });

  group('extractJarManifestConfigs', () {
    test('manifest at jar root', () {
      final bytes = _zipBytes({
        'classes.dex': [1, 2, 3],
        'moyi-plugin.json': utf8.encode(
          '{"sites": [{"key": "m", "name": "M", "api": "csp_M", "ext": ""}]}',
        ),
      });
      final configs = extractJarManifestConfigs(bytes);
      expect(configs.map((c) => c.key).toList(), ['m']);
    });

    test('manifest in a subfolder matches by basename', () {
      final bytes = _zipBytes({
        'META-INF/moyi-plugin.json': utf8.encode(
          '{"sites": [{"key": "s", "name": "S", "api": "csp_S", "ext": ""}]}',
        ),
      });
      expect(
        extractJarManifestConfigs(bytes).map((c) => c.key).toList(),
        ['s'],
      );
    });

    test('no manifest or bad zip yields empty', () {
      expect(
        extractJarManifestConfigs(_zipBytes({'classes.dex': [1]})),
        isEmpty,
      );
      expect(extractJarManifestConfigs([1, 2, 3]), isEmpty);
      expect(
        extractJarManifestConfigs(
          _zipBytes({'moyi-plugin.json': utf8.encode('junk{{')}),
        ),
        isEmpty,
      );
    });
  });
}
