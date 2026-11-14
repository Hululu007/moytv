import 'dart:io';

import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/content_models.dart';
import 'package:moyi/content_py.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/models.dart';
import 'package:moyi/zakatv_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

/// LwLive 合并两站（多多影视 + ASMR MOON）注册守卫。
///
/// 两份 py 已在合并侦察中用蜘蛛本体验过播放（duoduo 21/21、asmrmoon
/// Range 206 + ID3），这里只守注册正确：文件在位、协议齐全、key 唯一。
/// 已知保留事项（NBY 分片宿主本机超时、CO4K 未单点播）属播放层，
/// 注册时不重验。
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

void _expectSpiderProtocol(String assetPath) {
  final file = File(assetPath);
  expect(file.existsSync(), isTrue, reason: '$assetPath 不存在');
  final text = file.readAsStringSync();
  expect(
    text.contains('class Spider(BaseSpider)'),
    isTrue,
    reason: '$assetPath 无 Spider 类',
  );
  for (final method in _protocolMethods) {
    expect(
      text.contains('def $method'),
      isTrue,
      reason: '$assetPath 缺方法 $method',
    );
  }
}

void main() {
  test('多多影视：注册值与蜘蛛文件齐全', () {
    final site = BuiltinPySites.duoduoSite;
    expect(site.id, 'duoduo');
    expect(site.name, '多多影视');
    expect(site.section, SourceSite.sectionVideo);
    expect(BuiltinPySites.duoduoAssetPath, 'assets/py_spiders/duoduo.py');
    _expectSpiderProtocol(BuiltinPySites.duoduoAssetPath);
  });

  test('多多影视：key 不与 jar 内置站撞', () {
    expect(
      zakatvBuiltinSites.any((s) => s.key == BuiltinPySites.duoduoSiteId),
      isFalse,
    );
  });

  test('ASMR MOON：听书区注册值与蜘蛛文件齐全', () {
    final sources = ContentRegistry.sourcesFor(ContentSection.audio);
    final matches = [for (final s in sources) if (s.id == 'asmrmoon') s];
    expect(matches, hasLength(1));
    final source = matches.single;
    expect(source.name, '🔞ASMR MOON');
    expect(source.section, ContentSection.audio);
    expect(source, isA<PyContentSource>());
    expect(
      (source as PyContentSource).assetPath,
      'assets/audio_spiders/asmrmoon.py',
    );
    _expectSpiderProtocol('assets/audio_spiders/asmrmoon.py');
  });

  test('ASMR MOON：id 不与核心站撞', () {
    expect(SourceSite.isKnown('asmrmoon'), isFalse);
    expect(
      zakatvBuiltinSites.any((s) => s.key == 'asmrmoon'),
      isFalse,
    );
  });
}
