import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/zakatv_builtin.dart';

/// 读 dex 类定义表，返回全部已定义类的描述符（如
/// `Lcom/github/catvod/spider/Xhs;`）。只解析头、string_ids、
/// type_ids、class_defs 四段，不碰 code 段。
List<String> xhsDexDefinedClasses(List<int> dexBytes) {
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
    // uleb128 长度前缀（类描述符均为 ASCII，跳过即可）。
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

List<int> dexBytesOf(Archive archive, String name) => List<int>.from(
  archive.files.singleWhere((f) => f.name == name).content as List<int>,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zakatv jar asset md5 matches the const', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('classes18.dex defines exactly the new Xhs classes', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes18.dex'));
    expect(names.length, 23);
    final classes = xhsDexDefinedClasses(dexBytesOf(archive, 'classes18.dex'));
    expect(
      classes,
      unorderedEquals([
        'Lcom/github/catvod/spider/Xhs;',
        'Lcom/github/catvod/spider/Xhs\$1;',
        'Lcom/github/catvod/spider/Xhs\$2;',
        'Lcom/github/catvod/spider/Xhs\$Jp;',
      ]),
    );
    // 旧版 Xhs 的 $3/$4/$5 内部类绝不能残留：同名类在两个 dex 里
    // 重定义时加载器先赢，旧实现会把新版盖住。
    expect(classes, isNot(contains('Lcom/github/catvod/spider/Xhs\$3;')));
    expect(classes, isNot(contains('Lcom/github/catvod/spider/Xhs\$4;')));
    expect(classes, isNot(contains('Lcom/github/catvod/spider/Xhs\$5;')));
  });

  test('Xhs is defined in exactly one dex in the jar', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final defining = <String>[];
    for (final file in archive.files) {
      if (!RegExp(r'^classes\d*\.dex$').hasMatch(file.name)) continue;
      final classes = xhsDexDefinedClasses(
        List<int>.from(file.content as List<int>),
      );
      if (classes.contains('Lcom/github/catvod/spider/Xhs;')) {
        defining.add(file.name);
      }
    }
    expect(defining, ['classes18.dex']);
  });

  test('new Xhs dex carries the four builtin site hosts', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final text = String.fromCharCodes(dexBytesOf(archive, 'classes18.dex'));
    for (final host in [
      'cj.lziapi.com',
      'api.wujinapi.me',
      'caiji.dyttzyapi.com',
      'api.apibdzy.com',
    ]) {
      expect(text, contains(host));
    }
    expect(text, contains('/api.php/provide/vod/'));
  });

  test('Xhs registered in the Dart registry', () {
    expect(zakatvBuiltinSites.length, 140);
    final site = zakatvBuiltinSites.singleWhere((site) => site.key == 'Xhs');
    expect(site.name, 'Xhs');
    expect(site.className, 'com.github.catvod.spider.Xhs');
    expect(site.ext, '');
  });

  test('Xhs mirrored in jar_site_configs.json', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    expect(configs.length, 145);
    final matched = matchJarSiteConfig('com.github.catvod.spider.Xhs', configs);
    expect(matched, isNotNull);
    expect(matched!.key, 'Xhs');
    expect(matched.name, 'Xhs');
    expect(matched.api, 'csp_Xhs');
    expect(matched.ext, '');
  });

  test('api/class/siteId mapping for Xhs', () {
    expect(
      JarSiteSpec.classNameForApi('csp_Xhs'),
      'com.github.catvod.spider.Xhs',
    );
    expect(JarSiteSpec.siteIdFor('zakatv', 'Xhs'), 'jar:zakatv:Xhs');
  });
}
