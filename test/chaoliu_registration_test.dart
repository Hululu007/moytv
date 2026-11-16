import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/models.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// 潮流AV 注册守卫：py 由潮流 App（live.zaka.chaoliu 2.20）静态逆向
/// 写成，已在 2026-11-16 用蜘蛛本体抽查验过真站（173 个分类、分类
/// 页 24 条有封面、详情出播放地址、playerContent 回真 m3u8 且拉到
/// 200 变体列表；见 ~/workspace/chaoliu_re/REVERSE.md）。这里只守
/// 注册正确：文件在位且与来源字节一致、协议齐全、key 唯一、无中文
/// 注释、分类数 173、插件清单与跨站选线已接通。线路 3 的 CDN 在本机
/// 出口 403、女优详情选集、图集 pics:// 链路、番号秒播表均属手机
/// 待验项，注册时不冒充已验。
const _protocolMethods = <String>[
  'getName',
  'getDependence',
  'init',
  'destroy',
  'homeContent',
  'homeVideoContent',
  'categoryContent',
  'detailContent',
  'searchContent',
  'playerContent',
  'localProxy',
  'isVideoFormat',
  'manualVideoCheck',
  'action',
];

/// 来源文件 md5（~/workspace/chaoliu_re/sources/chaoliu.py），树内
/// 文件必须与它字节一致，改一个字节这里就报。
const _sourceMd5 = 'bb9e3ffa140a0077b55df884a3a5d35e';

int _countListEntries(List<String> lines, String header) {
  var inList = false;
  var count = 0;
  for (final line in lines) {
    if (!inList) {
      if (line == header) inList = true;
      continue;
    }
    if (line == ']') break;
    if (line.startsWith('    ("')) count++;
  }
  return count;
}

void main() {
  test('潮流AV：注册值与蜘蛛文件齐全', () {
    final site = BuiltinPySites.chaoliuSite;
    expect(site.id, 'chaoliu');
    expect(site.name, '🔞潮流AV');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.origin, SourceSite.originBuiltin);
    expect(site.importType, 'py');
    expect(BuiltinPySites.chaoliuAssetPath, 'assets/py_spiders/chaoliu.py');
    final file = File(BuiltinPySites.chaoliuAssetPath);
    expect(file.existsSync(), isTrue);
    final text = file.readAsStringSync();
    expect(text.contains('class Spider(BaseSpider)'), isTrue);
    for (final method in _protocolMethods) {
      expect(
        text.contains('def $method'),
        isTrue,
        reason: '缺方法 $method',
      );
    }
    expect(text.contains('return "潮流AV"'), isTrue);
  });

  test('潮流AV：树内文件与来源字节一致', () {
    final bytes = File(BuiltinPySites.chaoliuAssetPath).readAsBytesSync();
    expect(md5.convert(bytes).toString(), _sourceMd5);
  });

  test('潮流AV：py 文件 0 中文注释', () {
    final text = File(
      BuiltinPySites.chaoliuAssetPath,
    ).readAsStringSync();
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    for (final line in text.split('\n')) {
      final hash = line.indexOf('#');
      if (hash < 0) continue;
      expect(
        cjk.hasMatch(line.substring(hash)),
        isFalse,
        reason: '中文注释：$line',
      );
    }
  });

  test('潮流AV：分类数 173', () {
    final lines = File(
      BuiltinPySites.chaoliuAssetPath,
    ).readAsStringSync().split('\n');
    final cats = _countListEntries(lines, 'CATS = [');
    final mjv = _countListEntries(lines, 'MJV = [');
    final tuku = _countListEntries(lines, 'TUKU = [');
    final ph = _countListEntries(lines, 'PH = [');
    expect(cats, 156);
    expect(mjv, 7);
    expect(tuku, 7);
    expect(ph, 2);
    // homeContent：CATS + MJV + 女优库 1 个 + TUKU + PH。
    expect(cats + mjv + 1 + tuku + ph, 173);
  });

  test('潮流AV：key 不与 jar 内置站撞', () {
    expect(
      zakatvBuiltinSites.any((s) => s.key == BuiltinPySites.chaoliuSiteId),
      isFalse,
    );
  });

  test('潮流AV：key 不与既有站源 id 撞', () {
    expect(
      SourceSite.allValues.any((s) => s.id == BuiltinPySites.chaoliuSiteId),
      isFalse,
    );
  });

  test('潮流AV：内置 py 插件清单里有它', () {
    final entry = BuiltinPySites.entryFor(BuiltinPySites.chaoliuSiteId);
    expect(entry, isNotNull);
    expect(entry!.assetPath, BuiltinPySites.chaoliuAssetPath);
    expect(entry.fileId, BuiltinPySites.chaoliuFileId);
    final plugins = PluginManager.builtinPlugins();
    expect(plugins.map((p) => p.id), contains('py:chaoliu'));
    final plugin = plugins.firstWhere((p) => p.id == 'py:chaoliu');
    expect(plugin.name, '🔞潮流AV');
  });

  test('潮流AV：跨站选线已接通', () {
    expect(crossSitePrioritySiteIds, contains('chaoliu'));
  });
}
