import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:moyi/jar_site_config.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// TG 频道 jar 内置（100 频道）注册守卫。
///
/// 排除口径：被排除的 2 个频道绝不写进树。本测试不写出那 2 个用户名，
/// 改用两重占位比对守卫——① ext 频道数精确等于 100；② 频道名/用户名
/// 与注册面文件全文均不得命中未成年指向词表（被排除频道的名字正在
/// 词表命中范围内）。词表与 m3u 打包安全扫描同一张。
const _flaggedTerms = <String>[
  '萝莉',
  '蘿莉',
  '幼女',
  '幼齿',
  '幼齒',
  '未成年',
  '小学生',
  '初中生',
  '儿童',
  '女童',
  '男童',
  '小女孩',
  '小男孩',
  '未满18',
  '未满十八',
  '10岁',
  '11岁',
  '12岁',
  '13岁',
  '14岁',
  '15岁',
  '16岁',
  '17岁',
];

bool _hasFlaggedTerm(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('loli')) return true;
  for (final term in _flaggedTerms) {
    if (text.contains(term)) return true;
  }
  return false;
}

/// 最小 dex 类定义解析：只读 header + string_ids/type_ids/class_defs，
/// 返回本 dex 定义的类描述符集合（与 dexdump 的 defined-classes 等价）。
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
    final next = <int>[0];
    uleb(dataOff, next);
    var end = next[0];
    while (dex[end] != 0) {
      end++;
    }
    defined.add(utf8.decode(dex.sublist(next[0], end)));
  }
  return defined;
}

Map<String, dynamic> _decodeExt(String ext) {
  final decoded = jsonDecode(ext);
  expect(decoded, isA<Map<String, dynamic>>());
  return decoded as Map<String, dynamic>;
}

void main() {
  test('ZakaTg 注册存在：新类 + 100 频道 ext', () {
    final site = zakatvBuiltinSites.singleWhere(
      (s) => s.key == 'ZakaTg',
    );
    expect(site.name, '📡TG频道┃100个');
    expect(site.className, 'com.github.catvod.spider.ZakaTgAllAmns');
    expect(site.audioOnly, isFalse);
    final ext = _decodeExt(site.ext);
    expect(ext['mirror'], 'https://tg.i-c-a.su');
    expect(ext['size'], 20);
    expect(ext['groupByTitle'], isTrue);
    final channels = ext['channels'];
    expect(channels, isA<List>());
    expect(channels, hasLength(100));
    final users = <String>{};
    for (final channel in channels as List) {
      expect(channel, isA<Map>());
      final map = Map<String, dynamic>.from(channel as Map);
      final name = map['name']?.toString() ?? '';
      final user = map['user']?.toString() ?? '';
      expect(name.isNotEmpty, isTrue);
      expect(user.isNotEmpty, isTrue);
      expect(users.add(user), isTrue, reason: '频道用户名重复：$user');
      expect(_hasFlaggedTerm(name), isFalse, reason: '频道名命中词表：$name');
      expect(_hasFlaggedTerm(user), isFalse, reason: '用户名命中词表');
    }
  });

  test('ZakaTg ext 不带 channelsUrl（并集语义会加回频道）', () {
    final site = zakatvBuiltinSites.singleWhere((s) => s.key == 'ZakaTg');
    final ext = _decodeExt(site.ext);
    expect(ext.containsKey('channelsUrl'), isFalse);
    expect(ext['autoDiscover'] ?? false, isFalse);
  });

  test('JSON 配置与 Dart 注册一致：同类同 100 清单', () {
    final text = File('assets/jar_site_configs.json').readAsStringSync();
    final configs = parseJarSiteConfigs(text);
    final matched = matchJarSiteConfig(
      'com.github.catvod.spider.ZakaTgAllAmns',
      configs,
    );
    expect(matched, isNotNull);
    expect(matched!.key, 'ZakaTg');
    expect(matched.api, 'csp_ZakaTgAllAmns');
    final jsonExt = _decodeExt(matched.ext);
    final dartSite = zakatvBuiltinSites.singleWhere((s) => s.key == 'ZakaTg');
    final dartExt = _decodeExt(dartSite.ext);
    final jsonUsers = [
      for (final c in jsonExt['channels'] as List)
        (c as Map)['user'].toString(),
    ];
    final dartUsers = [
      for (final c in dartExt['channels'] as List)
        (c as Map)['user'].toString(),
    ];
    expect(jsonUsers, hasLength(100));
    expect(jsonUsers.toSet(), dartUsers.toSet());
    expect(jsonExt.containsKey('channelsUrl'), isFalse);
  });

  test('注册面文件全文无未成年指向词（防排除频道回潮）', () {
    const surfaces = <String>[
      'lib/zakatv_builtin.dart',
      'assets/jar_site_configs.json',
      'native/core/seku/sites_jar_tg.go',
    ];
    for (final path in surfaces) {
      final text = File(path).readAsStringSync();
      expect(
        _hasFlaggedTerm(text),
        isFalse,
        reason: '$path 命中未成年指向词表',
      );
    }
  });

  test('ZakaTgMovie ext 已剔除非视频频道（101→91）', () {
    final site = zakatvBuiltinSites.singleWhere(
      (s) => s.key == 'ZakaTgMovie',
    );
    final ext = _decodeExt(site.ext);
    final channels = ext['channels'] as List;
    expect(channels, hasLength(110));
    // 2026-11-14 第十一件 A：软件/VPN/代理/交流群/小说/查询/纯写真
    // 频道已从清单剔除，绝不回潮；名字含未成年指向音译词的也已剔除。
    const removedUsers = <String>{
      'AV688Group',
      'yydsys',
      'longaozzz1',
      'xiezhen1',
      'pianduoduo9',
      'YSxiaoshuo01',
      'XQFXS',
      'FLLAVWM',
      'gydlpd',
    };
    for (final channel in channels) {
      final map = Map<String, dynamic>.from(channel as Map);
      final name = map['name']?.toString() ?? '';
      final user = map['user']?.toString() ?? '';
      expect(removedUsers.contains(user), isFalse, reason: '已删频道回潮：$user');
      expect(name.contains('洛丽塔'), isFalse, reason: '频道名含未成年指向词：$name');
    }
  });

  test('合并后 jar 指纹与盘上文件一致', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    expect(md5.convert(bytes).toString(), zakatvJarMd5);
  });

  test('合并后 jar 内含新 dex 且定义 ZakaTgAllAmns', () {
    final bytes = File('assets/jars/zakatv.jar').readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in archive.files) f.name];
    expect(names, contains('classes.dex'));
    expect(names, contains('classes16.dex'));
    final dex = archive.files.singleWhere((f) => f.name == 'classes16.dex');
    final defined = _dexDefinedClasses(dex.content as List<int>);
    expect(
      defined,
      contains('Lcom/github/catvod/spider/ZakaTgAllAmns;'),
    );
    expect(defined, contains('Lcom/github/catvod/spider/ZakaTgAmns;'));
    // 新 dex 不得重复定义 Spider 基类（已在 classes.dex 内定义）。
    expect(
      defined,
      isNot(contains('Lcom/github/catvod/crawler/Spider;')),
    );
  });
}
