import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/plugin_icons.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';

/// 读 dex 类定义表，返回全部已定义类的描述符（如
/// `Lcom/github/catvod/spider/ZakaMissavAmns;`）。只解析头、string_ids、
/// type_ids、class_defs 四段，不碰 code 段（与 eroshort / 飞卢听书
/// 测试同款）。
List<String> _dexDefinedClasses(List<int> dexBytes) {
  final bytes = Uint8List.fromList(dexBytes);
  final data = ByteData.sublistView(bytes);
  int u32(int offset) => data.getUint32(offset, Endian.little);
  final stringIdsSize = u32(56);
  final stringIdsOff = u32(60);
  final typeIdsOff = u32(68);
  final classDefsSize = u32(96);
  final classDefsOff = u32(100);
  String readString(int index) {
    final off = u32(stringIdsOff + index * 4);
    var pos = off;
    while (bytes[pos] & 0x80 != 0) {
      pos++;
    }
    pos++;
    final start = pos;
    while (bytes[pos] != 0) {
      pos++;
    }
    return String.fromCharCodes(bytes.sublist(start, pos));
  }

  final strings = [for (var i = 0; i < stringIdsSize; i++) readString(i)];
  final classes = <String>[];
  for (var i = 0; i < classDefsSize; i++) {
    final classIdx = u32(classDefsOff + i * 32);
    final stringIdx = u32(typeIdsOff + classIdx * 4);
    classes.add(strings[stringIdx]);
  }
  return classes;
}

List<int> _dexBytesOf(Archive archive, String name) => List<int>.from(
  archive.files.firstWhere((f) => f.name == name).content as List<int>,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missav30 jar 原样：md5 与常量一致', () {
    final bytes = File('assets/jars/missav30.jar').readAsBytesSync();
    expect(bytes.length, 104436);
    expect(md5.convert(bytes).toString(), missav30JarMd5);
    expect(missav30JarMd5, '15efee5d3f3f4b2433bd25bc16ccf139');
    expect(missav30JarAsset, 'assets/jars/missav30.jar');
    expect(missav30JarId, 'missav30');
  });

  test('missav30 jar 内只有 MANIFEST + classes.dex，无签名', () {
    final bytes = File('assets/jars/missav30.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names.length, 3);
    expect(names, contains('META-INF/MANIFEST.MF'));
    expect(names, contains('classes.dex'));
    expect(names, isNot(contains('META-INF/SIG')));
    final dex = _dexBytesOf(archive, 'classes.dex');
    expect(dex.length, 224264);
    final manifest = utf8.decode(
      archive.files.singleWhere((f) => f.name == 'META-INF/MANIFEST.MF').content
          as List<int>,
    );
    expect(manifest, contains('Created-By: Zaka'));
  });

  test('dex 类表：3 蜘蛛 + Fix 助手 + ZakaSec，无 Guard 类、无 DexNative 类', () {
    final bytes = File('assets/jars/missav30.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final classes = _dexDefinedClasses(_dexBytesOf(archive, 'classes.dex'));
    expect(classes.length, 62);
    // 3 个蜘蛛。
    expect(classes, contains('Lcom/github/catvod/spider/ZakaMissavAmns;'));
    expect(classes, contains('Lcom/github/catvod/spider/ZakaMissavOffAmns;'));
    expect(classes, contains('Lcom/github/catvod/spider/ZakaMissavtAmns;'));
    expect(
      classes,
      contains('Lcom/github/catvod/spider/ZakaMissavOffAmns\$PicProxy;'),
    );
    expect(
      classes,
      contains('Lcom/github/catvod/spider/ZakaMissavtAmns\$PicProxy;'),
    );
    // Fix 是助手、不是站点：类必须在 jar 里（以后换 jar 丢了它测试拦住），
    // 但绝不进登记表（见下面登记测试）。
    expect(classes, contains('Lcom/github/catvod/spider/ZakaMissavFix;'));
    expect(
      classes,
      contains('Lcom/github/catvod/spider/ZakaMissavFix\$ProxyHandler;'),
    );
    expect(classes, contains('Lcom/github/catvod/spider/ZakaSec;'));
    // Guard 误判只认类名（JarBridge.isGuardJar）：DexNative 全名 +
    // 以 Guard 结尾的类简单名，两者都没有，走普通 DexClassLoader。
    expect(classes, isNot(contains('Lcom/github/catvod/spider/DexNative;')));
    final guardClasses = classes.where((c) {
      final simple = c.split('/').last.replaceAll(';', '').split('\$').first;
      return simple.endsWith('Guard');
    }).toList();
    expect(guardClasses, isEmpty);
  });

  test('missav30 登记：3 条与旧登记一字不动，只换 jar 归属', () {
    expect(missav30BuiltinSites.length, 3);
    final byKey = {for (final s in missav30BuiltinSites) s.key: s};

    final missav = byKey['ZakaMissav']!;
    expect(missav.name, '🔞MissAV官方┃过盾');
    expect(missav.className, 'com.github.catvod.spider.ZakaMissavAmns');
    expect(
      missav.ext,
      '{"base":"https://tv506.ystv.top","miss":"https://missav.ws286.ystv.top"}',
    );

    final off = byKey['ZakaMissavOff']!;
    expect(off.name, '🔞MissAV官方┃原生');
    expect(off.className, 'com.github.catvod.spider.ZakaMissavOffAmns');
    expect(
      off.ext,
      '{"host":"https://missav.live","relay":"https://tv506.ystv.top","flare":"http://192.168.31.2:8191/v1"}',
    );

    final missavt = byKey['missavt']!;
    expect(missavt.name, '🔞MissAVt┃原生');
    expect(missavt.className, 'com.github.catvod.spider.ZakaMissavtAmns');
    expect(missavt.ext, '');

    for (final site in missav30BuiltinSites) {
      expect(
        JarSiteSpec.siteIdFor(missav30JarId, site.key),
        'jar:missav30:${site.key}',
      );
      expect(site.audioOnly, isFalse);
    }
    // Fix 不当站点：登记表里没有它。
    expect(missav30BuiltinSites.any((s) => s.key.contains('Fix')), isFalse);
    expect(
      missav30BuiltinSites.any((s) => s.className.contains('ZakaMissavFix')),
      isFalse,
    );
    // 旧表里 3 条已搬走，ZakaMirror 还在 zakatv 上。
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMissav'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMissavOff'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'missavt'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMirror'), isTrue);
    expect(zakatvBuiltinSites.length, 140);
  });

  test('missav30 有独立插件条目，在 one 条目之后', () {
    final plugins = PluginManager.builtinPlugins();
    final missav30 = plugins.singleWhere(
      (p) => p.id == PluginManager.missav30JarPluginId,
    );
    expect(missav30.id, 'jar:missav30');
    expect(missav30.name, 'MissAV v30');
    expect(missav30.kind, PluginIconKind.jar);
    expect(missav30.md5, missav30JarMd5);
    expect(missav30.siteIds, [
      'jar:missav30:ZakaMissav',
      'jar:missav30:ZakaMissavOff',
      'jar:missav30:missavt',
    ]);
    expect(missav30.siteCount, 3);
    expect(missav30.detail, contains('3'));
    expect(
      plugins.indexOf(missav30),
      greaterThan(
        plugins.indexWhere((p) => p.id == PluginManager.oneJarPluginId),
      ),
    );
    // zakatv 插件自动少 3 条：140 条配置、1 条纯音频，139 个可见站。
    final zakatv = plugins.singleWhere(
      (p) => p.id == PluginManager.jarPluginId,
    );
    expect(zakatv.siteCount, 139);
    expect(zakatv.detail, contains('140'));
  });

  test('JSON 镜像：3 条 api 映到新 jar 的 3 个蜘蛛类，条数 145 不变', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    expect(configs.length, 145);
    final cases = {
      'com.github.catvod.spider.ZakaMissavAmns': (
        key: 'ZakaMissav',
        name: '🔞MissAV官方┃过盾',
        api: 'csp_ZakaMissavAmns',
        ext:
            '{"base":"https://tv506.ystv.top","miss":"https://missav.ws286.ystv.top"}',
      ),
      'com.github.catvod.spider.ZakaMissavOffAmns': (
        key: 'ZakaMissavOff',
        name: '🔞MissAV官方┃原生',
        api: 'csp_ZakaMissavOffAmns',
        ext:
            '{"host":"https://missav.live","relay":"https://tv506.ystv.top","flare":"http://192.168.31.2:8191/v1"}',
      ),
      'com.github.catvod.spider.ZakaMissavtAmns': (
        key: 'missavt',
        name: '🔞MissAVt┃原生',
        api: 'csp_ZakaMissavtAmns',
        ext: '',
      ),
    };
    for (final entry in cases.entries) {
      final matched = matchJarSiteConfig(entry.key, configs);
      expect(matched, isNotNull, reason: entry.key);
      expect(matched!.key, entry.value.key);
      expect(matched.name, entry.value.name);
      expect(matched.api, entry.value.api);
      expect(matched.ext, entry.value.ext);
    }
  });

  test('zakatv.jar 未动守卫：md5 + 23 条目不变', () {
    expect(zakatvJarMd5, '44235cee5268015e5ccca0a57aa42107');
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((f) => f.name).toList();
    expect(names.length, 23);
  });

  test('旧站点 id 全树零残留：生产 + 测试里不再有 jar:zakatv 的 3 个 MissAV id', () {
    // 模式用拼接写，避免本文件自身的字面量被扫到。
    const forbidden = [
      'jar:zakatv:'
          'ZakaMissav',
      'jar:zakatv:'
          'ZakaMissavOff',
      'jar:zakatv:'
          'missavt',
    ];
    final offenders = <String>[];
    for (final dir in ['lib', 'test']) {
      for (final entity in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        for (final pattern in forbidden) {
          if (text.contains(pattern)) {
            offenders.add('${entity.path} 含 $pattern');
          }
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
