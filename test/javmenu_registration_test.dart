import 'dart:io';

import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// JavMenu 注册守卫：py 已在 2026-11-13 用蜘蛛本体验过真站（39 个
/// 分类、parse=0 出真 m3u8、Range 206），这里只守注册正确：文件在
/// 位、协议齐全、key 唯一、无中文注释。已知缺口（数字开头番号如
/// /1PONDO-102726 匹配不上）属爬取逻辑，注册时不动、不扩大范围。
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

void main() {
  test('JavMenu：注册值与蜘蛛文件齐全', () {
    final site = BuiltinPySites.javmenuSite;
    expect(site.id, 'javmenu');
    expect(site.name, '🔞JAV目錄大全');
    expect(site.section, SourceSite.sectionVideo);
    expect(site.origin, SourceSite.originBuiltin);
    expect(site.importType, 'py');
    expect(BuiltinPySites.javmenuAssetPath, 'assets/py_spiders/javmenu.py');
    final file = File(BuiltinPySites.javmenuAssetPath);
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
    expect(text.contains('return "JAV目錄大全"'), isTrue);
  });

  test('JavMenu：py 文件 0 中文注释', () {
    final text = File(
      BuiltinPySites.javmenuAssetPath,
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

  test('JavMenu：key 不与 jar 内置站撞', () {
    expect(
      zakatvBuiltinSites.any((s) => s.key == BuiltinPySites.javmenuSiteId),
      isFalse,
    );
  });

  test('JavMenu：key 不与既有站源 id 撞', () {
    // Go 核槽位站是 v_javmenu，与 py 注册 key 'javmenu' 不同 id，不撞。
    expect(
      SourceSite.allValues.any((s) => s.id == BuiltinPySites.javmenuSiteId),
      isFalse,
    );
  });
}
