import 'dart:convert';

import 'package:moyi/jar_site_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _yt = JarSiteConfig(
  key: 'youtube',
  name: 'YouTube',
  api: 'csp_YouTube',
  ext: '{"proxy":""}',
);

void main() {
  test('learned configs round trip through json', () {
    final text = jsonEncode([_yt.toJson()]);
    final parsed = parseLearnedJarConfigs(text);
    expect(parsed, hasLength(1));
    expect(parsed.first.key, 'youtube');
    expect(parsed.first.ext, '{"proxy":""}');
    expect(
      matchJarSiteConfig('com.github.catvod.spider.YouTube', parsed),
      isNotNull,
    );
  });

  test('upsert appends new entries and replaces changed ones', () {
    final learned = upsertLearnedJarConfigs(const [], [_yt]);
    expect(learned, hasLength(1));
    final same = upsertLearnedJarConfigs(learned, [_yt]);
    expect(identical(same, learned), isTrue);
    const updated = JarSiteConfig(
      key: 'youtube',
      name: 'YouTube',
      api: 'csp_YouTube',
      ext: '{"proxy":"x"}',
    );
    final replaced = upsertLearnedJarConfigs(learned, [updated]);
    expect(replaced, hasLength(1));
    expect(replaced.first.ext, '{"proxy":"x"}');
    const other = JarSiteConfig(
      key: 'demo',
      name: 'Demo',
      api: 'csp_Demo',
      ext: '',
    );
    expect(upsertLearnedJarConfigs(replaced, [other]), hasLength(2));
  });

  test('invalid learned json parses as empty', () {
    expect(parseLearnedJarConfigs('not json'), isEmpty);
    expect(parseLearnedJarConfigs('{"sites": []}'), isEmpty);
  });
}
