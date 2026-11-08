import 'package:moyi/jar_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fileBaseName', () {
    test('strips directory and jar extension', () {
      expect(
        JarImport.fileBaseName('/storage/emulated/0/Download/YouTube.jar'),
        'YouTube',
      );
      expect(
        JarImport.fileBaseName('YouTube____jar_50_p5j9.jar'),
        'YouTube____jar_50_p5j9',
      );
      expect(JarImport.fileBaseName('demo.zip'), 'demo');
      expect(JarImport.fileBaseName('plain'), 'plain');
    });

    test('round trip through toJson keeps baseName', () {
      const site = StandaloneJarSite(
        siteId: 'jar:imp1:YouTube',
        jarId: 'imp1',
        jarUrl: '/tmp/YouTube.jar',
        jarMd5: '',
        className: 'com.github.catvod.spider.YouTube',
        name: 'YouTube1',
        baseName: 'YouTube',
      );
      final restored = StandaloneJarSite.fromJson(site.toJson());
      expect(restored.effectiveBase, 'YouTube');
      expect(restored.name, 'YouTube1');
    });

    test('old records without baseName fall back to name', () {
      final restored = StandaloneJarSite.fromJson({
        'siteId': 'jar:imp1:YouTube',
        'jarId': 'imp1',
        'jarUrl': '',
        'jarMd5': '',
        'className': 'com.github.catvod.spider.YouTube',
        'name': 'YouTube',
      });
      expect(restored.effectiveBase, 'YouTube');
    });
  });

  group('numberedNames', () {
    test('single site keeps the plain file name', () {
      expect(JarImport.numberedNames('YouTube', 1), ['YouTube']);
    });

    test('duplicate sites get 1 and 2', () {
      expect(
        JarImport.numberedNames('YouTube', 2),
        ['YouTube1', 'YouTube2'],
      );
      expect(
        JarImport.numberedNames('YouTube', 3),
        ['YouTube1', 'YouTube2', 'YouTube3'],
      );
    });
  });

  group('uniqueSiteKey', () {
    test('free key is unchanged', () {
      expect(JarImport.uniqueSiteKey('YouTube', {}), 'YouTube');
      expect(
        JarImport.uniqueSiteKey('YouTube', {'Other'}),
        'YouTube',
      );
    });

    test('taken key moves to _2 then _3', () {
      expect(
        JarImport.uniqueSiteKey('YouTube', {'YouTube'}),
        'YouTube_2',
      );
      expect(
        JarImport.uniqueSiteKey('YouTube', {'YouTube', 'YouTube_2'}),
        'YouTube_3',
      );
    });
  });
}
