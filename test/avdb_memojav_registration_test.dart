import 'dart:io';

import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// AVDB 与 MemoJav 注册守卫：两份 py 已在 2026-11-14 用蜘蛛本体
/// 验过真站（见 ~/workspace/avdb_memojav_sources/REPORT.md：AVDB
/// 30 项过、MemoJav 35 项 + 两部全长真播过），这里只守注册正确：
/// 文件在位、协议齐全、key 唯一、无中文注释、跨站选线已接通。
/// AVDB 真播因签名 IP 绑定在本机出口验不了，属已知未验项，
/// 注册时不冒充已验，手机终验见回报清单。
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

void _checkSpiderFile(String assetPath, String spiderName) {
  final file = File(assetPath);
  expect(file.existsSync(), isTrue);
  final text = file.readAsStringSync();
  expect(text.contains('class Spider(BaseSpider)'), isTrue);
  for (final method in _protocolMethods) {
    expect(
      text.contains('def $method'),
      isTrue,
      reason: '$assetPath 缺方法 $method',
    );
  }
  expect(text.contains('return "$spiderName"'), isTrue);
}

void main() {
  test('AVDB：注册值与蜘蛛文件齐全', () {
    final site = BuiltinPySites.avdbSite;
    expect(site.id, 'avdb');
    expect(site.name, '🔞AVDB');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.origin, SourceSite.originBuiltin);
    expect(site.importType, 'py');
    expect(BuiltinPySites.avdbAssetPath, 'assets/py_spiders/avdb.py');
    _checkSpiderFile(BuiltinPySites.avdbAssetPath, 'AVDB');
  });

  test('MemoJav：注册值与蜘蛛文件齐全', () {
    final site = BuiltinPySites.memojavSite;
    expect(site.id, 'memojav');
    expect(site.name, '🔞MemoJav');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.origin, SourceSite.originBuiltin);
    expect(site.importType, 'py');
    expect(BuiltinPySites.memojavAssetPath, 'assets/py_spiders/memojav.py');
    _checkSpiderFile(BuiltinPySites.memojavAssetPath, 'MemoJav');
  });

  test('AVDB 与 MemoJav：py 文件 0 中文注释', () {
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    for (final assetPath in [
      BuiltinPySites.avdbAssetPath,
      BuiltinPySites.memojavAssetPath,
    ]) {
      final text = File(assetPath).readAsStringSync();
      for (final line in text.split('\n')) {
        final hash = line.indexOf('#');
        if (hash < 0) continue;
        expect(
          cjk.hasMatch(line.substring(hash)),
          isFalse,
          reason: '$assetPath 中文注释：$line',
        );
      }
    }
  });

  test('AVDB 与 MemoJav：key 不与 jar 内置站撞', () {
    for (final siteId in [
      BuiltinPySites.avdbSiteId,
      BuiltinPySites.memojavSiteId,
    ]) {
      expect(zakatvBuiltinSites.any((s) => s.key == siteId), isFalse);
    }
  });

  test('AVDB 与 MemoJav：key 不与既有站源 id 撞', () {
    for (final siteId in [
      BuiltinPySites.avdbSiteId,
      BuiltinPySites.memojavSiteId,
    ]) {
      expect(SourceSite.allValues.any((s) => s.id == siteId), isFalse);
    }
  });

  test('AVDB 与 MemoJav：跨站选线已接通，不再显示未接入', () {
    expect(crossSitePrioritySiteIds, contains('avdb'));
    expect(crossSitePrioritySiteIds, contains('memojav'));
    expect(
      crossSiteUnconnectedProviders.any(
        (p) => p.id == 'avdb' || p.id == 'memojav',
      ),
      isFalse,
    );
  });
}
