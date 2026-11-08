import 'dart:io';

import 'package:moyi/jar_site_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builtin jar configs json parses and covers YouTube', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    expect(configs.length, greaterThan(100));
    final yt = matchJarSiteConfig(
      'com.github.catvod.spider.YouTube',
      configs,
    );
    expect(yt, isNotNull);
    expect(yt!.key, 'youtube');
    expect(yt.name, 'YouTube');
    expect(yt.ext, '{"proxy":""}');
    final haijiao = matchJarSiteConfig(
      'com.github.catvod.spider.ZakaHaijiaoAmns',
      configs,
    );
    expect(haijiao, isNotNull);
    expect(haijiao!.key, 'ZakaHaijiao');
    expect(
      matchJarSiteConfig('com.github.catvod.spider.NotInJson', configs),
      isNull,
    );
  });

  test('deleted YouTube site no longer matches a config', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig(
      'com.github.catvod.spider.YtNewAmns',
      configs,
    );
    expect(matched, isNull);
  });

  test('builtin jar configs asset constant points at the json file', () {
    expect(builtinJarConfigsAsset, 'assets/jar_site_configs.json');
    expect(File(builtinJarConfigsAsset).existsSync(), isTrue);
  });
}
