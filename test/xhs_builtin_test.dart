import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// 小红薯 jar 版内置注册守卫：Xhs 6 个类 d8 成 classes18.dex 追加进
/// zakatv.jar，Dart 内置表与 JSON 配置双注册，ext 用 {} 默认。
/// 用户 2026-11-16 定 jar 版与 py 版两个都要：py 版注册不受影响。
/// Json 类不进新 dex：Xhs 只调 Json.parse(String)，classes17.dex 里
/// 已有的同名定义方法签名逐项一致，复用已有定义。
void main() {
  test('xhs registered in the builtin list', () {
    final site = zakatvBuiltinSites.singleWhere((s) => s.key == 'Xhs');
    expect(site.name, '🔞小红薯APP(JAR)');
    expect(site.className, 'com.github.catvod.spider.Xhs');
    expect(site.ext, '{}');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.audioOnly, isFalse);
  });

  test('xhs registered in the jar site configs json', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig(
      'com.github.catvod.spider.Xhs',
      configs,
    );
    expect(matched, isNotNull);
    expect(matched!.key, 'Xhs');
    expect(matched.name, '🔞小红薯APP(JAR)');
    expect(matched.api, 'csp_Xhs');
    expect(matched.ext, '{}');
    final decoded = jsonDecode(matched.ext) as Map;
    expect(decoded, isEmpty);
  });

  test('py version still registered alongside the jar version', () {
    final py = BuiltinPySites.entries.singleWhere(
      (e) => e.siteId == BuiltinPySites.xhsappSiteId,
    );
    expect(py.assetPath, BuiltinPySites.xhsappAssetPath);
    expect(py.site.name, '🔞小红薯APP');
  });

  test('merged jar md5 matches the asset on disk', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('merged jar holds classes18.dex defining Xhs without Spider/Json', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes18.dex'));
    final dex = archive.files.singleWhere((f) => f.name == 'classes18.dex');
    final defined = _dexDefinedClasses(dex.content as List<int>);
    expect(defined, contains('Lcom/github/catvod/spider/Xhs;'));
    expect(defined, contains('Lcom/github/catvod/spider/Xhs\$1;'));
    expect(defined, contains('Lcom/github/catvod/spider/Xhs\$2;'));
    expect(defined, contains('Lcom/github/catvod/spider/Xhs\$3;'));
    expect(defined, contains('Lcom/github/catvod/spider/Xhs\$4;'));
    expect(defined, contains('Lcom/github/catvod/spider/Xhs\$5;'));
    expect(defined.length, 6);
    // 壳子自带 Spider 基类，新 dex 不得重复定义它；Json 复用
    // classes17.dex 里的已有定义，新 dex 里也不得再有一份。
    expect(defined, isNot(contains('Lcom/github/catvod/crawler/Spider;')));
    expect(defined, isNot(contains('Lcom/github/catvod/spider/Json;')));
    final old = archive.files.singleWhere((f) => f.name == 'classes17.dex');
    final oldDefined = _dexDefinedClasses(old.content as List<int>);
    expect(oldDefined, contains('Lcom/github/catvod/spider/Json;'));
  });
}

Set<String> _dexDefinedClasses(List<int> dex) {
  int u32(int off) =>
      dex[off] |
      (dex[off + 1] << 8) |
      (dex[off + 2] << 16) |
      (dex[off + 3] << 24);
  int uleb(int off, List<int> next) {
    var result = 0;
    var shift = 0;
    var cursor = off;
    while (true) {
      final byte = dex[cursor++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    next[0] = cursor;
    return result;
  }

  // header: string_ids_size@56, string_ids_off@60, type_ids_size@64,
  // type_ids_off@68, class_defs_size@96, class_defs_off@100。
  final stringIdsOff = u32(60);
  final typeIdsOff = u32(68);
  final classDefsSize = u32(96);
  final classDefsOff = u32(100);
  final defined = <String>{};
  for (var i = 0; i < classDefsSize; i++) {
    final classIdx = u32(classDefsOff + i * 32);
    final stringIdx = u32(typeIdsOff + classIdx * 4);
    final dataOff = u32(stringIdsOff + stringIdx * 4);
    final next = [0];
    uleb(dataOff, next);
    final start = next[0];
    var end = start;
    while (dex[end] != 0) {
      end++;
    }
    defined.add(utf8.decode(dex.sublist(start, end)));
  }
  return defined;
}
