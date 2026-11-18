import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/models.dart';
import 'package:moyi/plugin_manager.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// 潮流AV 注册守卫：2026-11-18 按用户令重写为真实站直连，不再调
/// App 的 feed API（chaoliu-feed2-k7m2 已从源里摘净）。视频链走
/// mjv011.com 直连 HTML（分类/列表/详情/搜索/play.php 取流，纯
/// Python AES 解 pid，与 jar 版 ZakaMjv011Amns2 同链）；女优库与
/// 图库走潮流自有站 chaoliu-av-tk8m.web.zaka.live 的 jp220/data220
/// 烤制数据。分类与 mjv011.com 导航 1:1（首页 + 每日更新 + 15 个
/// 导航分类 + 女优库 + 7 个图库 = 25）。蜘蛛本体交付门已全过：
/// 25 个分类首页非空有真封面、翻页零重叠、详情出 3 档播放地址、
/// playerContent 回真 m3u8（1422 分片/7109 秒、AES-128 密钥 16
/// 字节可取）、搜索出真结果、番号秒播表与 MJV 回退链均验真播；
/// 见 ~/workspace/chaoliu_realsite_20261118/（gate2/gate3/gate5
/// 日志）。这里只守注册正确：文件在位且与来源字节一致、协议齐
/// 全、key 唯一、无中文注释、分类数 25、插件清单与跨站选线已接
/// 通。手机待验：qrtuv CDN 的秒播地址本机出口 403、手机上能否播
/// 须实测；jar 版委托链与图集 Large_cgurl 提取未经真机跑。
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
const _sourceMd5 = '8263b376a032f55359241eb413e06138';

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

  test('潮流AV：分类数 25', () {
    final lines = File(
      BuiltinPySites.chaoliuAssetPath,
    ).readAsStringSync().split('\n');
    final mjvCats = _countListEntries(lines, 'MJV_CATS = [');
    final tuku = _countListEntries(lines, 'TUKU = [');
    expect(mjvCats, 15);
    expect(tuku, 7);
    // homeContent：首页 + 每日更新 + MJV_CATS + 女优库 1 个 + TUKU。
    expect(2 + mjvCats + 1 + tuku, 25);
  });

  test('潮流AV：不含 App feed API 地址', () {
    final text = File(
      BuiltinPySites.chaoliuAssetPath,
    ).readAsStringSync();
    expect(text.contains('chaoliu-feed'), isFalse);
    expect(text.contains('mjv011.com'), isTrue);
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
