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

  test('one jar keeps classes.dex + SIG matching the SelfCheck transform', () {
    final bytes = File('assets/jars/one.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes.dex'));
    expect(names, contains('META-INF/SIG'));
    final dex = List<int>.from(
      archive.files.singleWhere((f) => f.name == 'classes.dex').content
          as List<int>,
    );
    final sig = utf8
        .decode(
          archive.files.singleWhere((f) => f.name == 'META-INF/SIG').content
              as List<int>,
        )
        .trim();
    expect(sig.length, 32);
    // SelfCheck 变换：全部 32 个 '0' 占位串换成 32 个 'X'，dex 头
    // [8,32) 清零，再 MD5。占位串须恰好出现 1 次（EXPECT 字段自身）。
    var runs = 0;
    final transformed = List<int>.from(dex);
    for (var i = 0; i + 32 <= transformed.length; i++) {
      var match = true;
      for (var j = 0; j < 32; j++) {
        if (transformed[i + j] != 0x30) {
          match = false;
          break;
        }
      }
      if (match) {
        runs++;
        for (var j = 0; j < 32; j++) {
          transformed[i + j] = 0x58;
        }
        i += 31;
      }
    }
    expect(runs, 1);
    for (var i = 8; i < 32; i++) {
      transformed[i] = 0;
    }
    expect(md5.convert(transformed).toString(), sig);
    final text = latin1.decode(dex);
    expect(text, contains('Lcom/github/catvod/spider/One;'));
    expect(text, contains('Lcom/github/catvod/spider/csp_One;'));
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
    expect(zakatvJarMd5, '44235cee5268015e5ccca0a57aa42107');
    expect(zakatvBuiltinSites.any((site) => site.key == 'One'), isFalse);
  });
}
