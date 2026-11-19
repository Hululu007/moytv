import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/plugin_icons.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one jar asset md5 matches the const', () {
    final bytes = File('assets/jars/one.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), oneJarMd5);
  });

  test('one jar is the new spider rewrite: 4 classes, markers, no SIG', () {
    final bytes = File('assets/jars/one.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes.dex'));
    expect(names, isNot(contains('META-INF/SIG')));
    expect(names, contains('META-INF/MANIFEST.MF'));
    final dex = List<int>.from(
      archive.files.singleWhere((f) => f.name == 'classes.dex').content
          as List<int>,
    );
    final text = latin1.decode(dex);
    // 新蜘蛛 4 个类：Json、One$1、One$2、One；One 的父类是壳内 Spider。
    expect(text, contains('Lcom/github/catvod/spider/Json;'));
    expect(text, contains('Lcom/github/catvod/spider/One\$1;'));
    expect(text, contains('Lcom/github/catvod/spider/One\$2;'));
    expect(text, contains('Lcom/github/catvod/spider/One;'));
    expect(text, contains('Lcom/github/catvod/crawler/Spider;'));
    // 域名分发与新后端接口的标记都在。
    expect(text, contains('Appdomain'));
    expect(text, contains('luatiaonli'));
    expect(text, contains('grpc'));
    expect(text, contains('girlGetList'));
    expect(text, contains('showvideo'));
    // 旧实现的拉闸/Auth/SelfCheck/csp_One 一律不在。
    expect(text, isNot(contains('SelfCheck')));
    expect(text, isNot(contains('Lcom/github/catvod/spider/Auth;')));
    expect(text, isNot(contains('csp_One')));
    expect(text, isNot(contains('META-INF/SIG')));
  });

  test('one builtin site registry', () {
    expect(oneBuiltinSites.length, 1);
    final site = oneBuiltinSites.single;
    expect(site.key, 'One');
    expect(site.name, '🔞一点播');
    expect(site.className, 'com.github.catvod.spider.One');
    expect(site.ext, '');
    expect(JarSiteSpec.siteIdFor(oneJarId, site.key), 'jar:one:One');
    expect(oneJarId, 'one');
    expect(oneJarAsset, 'assets/jars/one.jar');
  });

  test('one jar has its own plugin entry after the zakatv entry', () {
    final plugins = PluginManager.builtinPlugins();
    expect(plugins.first.id, PluginManager.jarPluginId);
    final one = plugins.singleWhere(
      (p) => p.id == PluginManager.oneJarPluginId,
    );
    expect(one.kind, PluginIconKind.jar);
    expect(one.md5, oneJarMd5);
    expect(one.siteIds, ['jar:one:One']);
    expect(one.detail, contains('1'));
  });

  test('jar site configs json mirrors the One entry', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig('com.github.catvod.spider.One', configs);
    expect(matched, isNotNull);
    expect(matched!.key, 'One');
    expect(matched.name, '🔞一点播');
    expect(matched.api, 'csp_One');
    expect(matched.ext, '');
  });

  test('zakatv registry untouched by the One builtin', () {
    expect(zakatvBuiltinSites.length, 140);
    expect(zakatvJarMd5, '029005c7ce017dc0a412f2d079a29dab');
    expect(zakatvBuiltinSites.any((site) => site.key == 'One'), isFalse);
  });
}
