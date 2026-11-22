import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_site_config.dart';
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

  test('missav30 登记已摘空：2026-11-22 用户令删 MissAV 全部旧站', () {
    expect(missav30BuiltinSites, isEmpty);
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMissav'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMissavOff'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'missavt'), isFalse);
    expect(zakatvBuiltinSites.any((s) => s.key == 'ZakaMirror'), isFalse);
    // 2026-11-22：ZakaMirror 摘除后 zakatv 侧从 138 降到 137 条
    // （其中 1 条纯音频不计入可见站，故 siteCount = 136）。
    expect(zakatvBuiltinSites.length, 137);
  });

  test('missav30 插件条目已摘除', () {
    final plugins = PluginManager.builtinPlugins();
    expect(plugins.any((p) => p.id == 'jar:missav30'), isFalse);
    // zakatv 插件：137 条配置、1 条纯音频，136 个可见站。
    final zakatv = plugins.singleWhere(
      (p) => p.id == PluginManager.jarPluginId,
    );
    expect(zakatv.siteCount, 136);
    expect(zakatv.detail, contains('137'));
  });

  test('JSON 镜像：4 条 MissAV 配置已摘除，条数 141', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    expect(configs.length, 141);
    for (final className in [
      'com.github.catvod.spider.ZakaMissavAmns',
      'com.github.catvod.spider.ZakaMissavOffAmns',
      'com.github.catvod.spider.ZakaMissavtAmns',
      'com.github.catvod.spider.ZakaMirrorAmns',
    ]) {
      expect(
        matchJarSiteConfig(className, configs),
        isNull,
        reason: className,
      );
    }
  });

  test('zakatv.jar 未动守卫：md5 + 23 条目不变', () {
    expect(zakatvJarMd5, '029005c7ce017dc0a412f2d079a29dab');
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
