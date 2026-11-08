import 'package:moyi/jar_site_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _ytJson = '''
{
  "spider": "./youtube.jar",
  "sites": [
    {
      "key": "youtube",
      "name": "YouTube",
      "type": 3,
      "api": "csp_YouTube",
      "searchable": 1,
      "quickSearch": 1,
      "filterable": 1,
      "ext": {"proxy": ""}
    }
  ]
}
''';

void main() {
  group('parseJarSiteConfigs', () {
    test('reads key, name, api and map ext from a sites config', () {
      final configs = parseJarSiteConfigs(_ytJson);
      expect(configs, hasLength(1));
      expect(configs.first.key, 'youtube');
      expect(configs.first.name, 'YouTube');
      expect(configs.first.api, 'csp_YouTube');
      expect(configs.first.ext, '{"proxy":""}');
    });

    test('single site object without a sites list parses', () {
      final configs = parseJarSiteConfigs(
        '{"key": "demo", "name": "Demo", "api": "csp_Demo", "ext": "token=1"}',
      );
      expect(configs, hasLength(1));
      expect(configs.first.ext, 'token=1');
    });

    test('missing ext parses as empty string', () {
      final configs = parseJarSiteConfigs(
        '{"sites": [{"key": "demo", "name": "Demo", "api": "csp_Demo"}]}',
      );
      expect(configs.first.ext, '');
    });

    test('a filter file without sites or api is not a site config', () {
      expect(parseJarSiteConfigs('{"class": [{"type_id": "x"}]}'), isEmpty);
      expect(parseJarSiteConfigs('{"recommend": "LIST:a,b"}'), isEmpty);
      expect(looksLikeJarSiteConfig('{"class": []}'), isFalse);
      expect(looksLikeJarSiteConfig(_ytJson), isTrue);
    });

    test('invalid json throws for the caller to skip', () {
      expect(() => parseJarSiteConfigs('{bad'), throwsA(isA<FormatException>()));
    });
  });

  group('matchJarSiteConfig', () {
    test('csp_ api maps to the dex class name', () {
      final configs = parseJarSiteConfigs(_ytJson);
      final matched = matchJarSiteConfig(
        'com.github.catvod.spider.YouTube',
        configs,
      );
      expect(matched, isNotNull);
      expect(matched!.key, 'youtube');
      expect(matched.name, 'YouTube');
    });

    test('a class with no matching api returns null', () {
      final configs = parseJarSiteConfigs(_ytJson);
      expect(
        matchJarSiteConfig('com.github.catvod.spider.Other', configs),
        isNull,
      );
    });

    test('a full class name api matches directly', () {
      const configs = [
        JarSiteConfig(
          key: 'demo',
          name: 'Demo',
          api: 'com.github.catvod.spider.Demo',
          ext: '',
        ),
      ];
      expect(
        matchJarSiteConfig('com.github.catvod.spider.Demo', configs),
        isNotNull,
      );
    });

    test('key falls back when api is empty', () {
      const configs = [
        JarSiteConfig(key: 'youtube', name: 'YT', api: '', ext: ''),
      ];
      final matched = matchJarSiteConfig(
        'com.github.catvod.spider.YouTube',
        configs,
      );
      expect(matched, isNotNull);
      expect(matched!.name, 'YT');
    });

    test('api match wins over a key match for another entry', () {
      const configs = [
        JarSiteConfig(key: 'YouTube', name: 'KeyHit', api: '', ext: ''),
        JarSiteConfig(
          key: 'other',
          name: 'ApiHit',
          api: 'csp_YouTube',
          ext: '{"proxy":""}',
        ),
      ];
      final matched = matchJarSiteConfig(
        'com.github.catvod.spider.YouTube',
        configs,
      );
      expect(matched!.name, 'ApiHit');
    });
  });
}
