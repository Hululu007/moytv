import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// HSTV jar 内置注册守卫：类 d8 成 classes17.dex 追加进 zakatv.jar，
/// Dart 内置表与 JSON 配置双注册，ext 用 {} 默认（host 自动轮换）。
void main() {
  test('hstv registered in the builtin list', () {
    final site = zakatvBuiltinSites.singleWhere((s) => s.key == 'hstv');
    expect(site.name, '🔞HSTV');
    expect(site.className, 'com.github.catvod.spider.Hstv');
    expect(site.ext, '{}');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.audioOnly, isFalse);
  });

  test('hstv registered in the jar site configs json', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig(
      'com.github.catvod.spider.Hstv',
      configs,
    );
    expect(matched, isNotNull);
    expect(matched!.key, 'hstv');
    expect(matched.name, '🔞HSTV');
    expect(matched.api, 'csp_Hstv');
    expect(matched.ext, '{}');
    final decoded = jsonDecode(matched.ext) as Map;
    expect(decoded, isEmpty);
  });

  test('merged jar md5 matches the asset on disk', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('merged jar holds classes17.dex defining Hstv without Spider', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes17.dex'));
    final dex = archive.files.singleWhere((f) => f.name == 'classes17.dex');
    final defined = _dexDefinedClasses(dex.content as List<int>);
    expect(defined, contains('Lcom/github/catvod/spider/Hstv;'));
    expect(defined, contains('Lcom/github/catvod/spider/Hstv\$Cache;'));
    expect(defined, contains('Lcom/github/catvod/spider/Json;'));
    expect(defined, contains('Lcom/github/catvod/spider/Base64;'));
    // hstv.jar 自身不捆 Spider 基类，新 dex 不得重复定义它。
    expect(defined, isNot(contains('Lcom/github/catvod/crawler/Spider;')));
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
