import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/jarbridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const siteIds = ['jar:testcfg:SiteA', 'jar:testcfg:SiteB', 'jar:testcfg:SiteC'];

  late NativeRepository repository;
  late Map<String, Duration> delays;
  late Set<String> failing;
  late int searchCalls;

  Map<String, dynamic> listJson(String siteId) => {
    'list': [
      {
        'vod_id': '$siteId|1',
        'vod_name': '剧-$siteId',
        'vod_pic': 'https://example.com/a.jpg',
      },
    ],
    'pagecount': 1,
    'total': 1,
  };

  setUp(() {
    delays = {};
    failing = {};
    searchCalls = 0;
    repository = NativeRepository(
      searchPerSiteTimeout: const Duration(milliseconds: 300),
    );
    JarBridge.setTestJarPath('testcfg', '/tmp/test.jar');
    for (final siteId in siteIds) {
      final key = siteId.split(':').last;
      JarBridge.register(
        JarSiteSpec(
          siteId: siteId,
          configId: 'testcfg',
          name: '站$key',
          className: 'com.github.catvod.spider.$key',
          jarUrl: '',
          jarMd5: '',
          ext: '{}',
        ),
      );
      SourceSite.importedSites[siteId] = SourceSite(
        siteId,
        '站$key',
        '',
        section: SourceSite.sectionVideo,
        origin: SourceSite.originImport,
        importType: 'jar',
      );
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'call') return null;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (args['method'] != 'searchContent') {
        return {'text': jsonEncode({})};
      }
      searchCalls++;
      final siteId = args['siteId'] as String? ?? '';
      if (failing.contains(siteId)) throw PlatformException(code: 'boom');
      final delay = delays[siteId] ?? Duration.zero;
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      return {'text': jsonEncode(listJson(siteId))};
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    for (final siteId in siteIds) {
      JarBridge.unregister(siteId);
      SourceSite.importedSites.remove(siteId);
    }
    JarBridge.clearTestJarPaths();
    JarBridge.resetTestHomeCache();
  });

  test('三站各 200ms 并发搜，总耗时远小于串行 600ms，且顺序与站序一致', () async {
    delays = {
      for (final siteId in siteIds) siteId: const Duration(milliseconds: 200),
    };
    final watch = Stopwatch()..start();
    final page = await repository.searchAcross(siteIds, '剧');
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(searchCalls, 3);
    expect(
      page.items.map((d) => d.source),
      siteIds,
    );
    expect(page.warning, isEmpty);
  });

  test('单站超时只丢该站，不拖垮整轮，且 warning 点名', () async {
    delays = {'jar:testcfg:SiteB': const Duration(seconds: 5)};
    final watch = Stopwatch()..start();
    final page = await repository.searchAcross(siteIds, '剧');
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(
      page.items.map((d) => d.source),
      ['jar:testcfg:SiteA', 'jar:testcfg:SiteC'],
    );
    expect(page.warning, contains('站SiteB'));
  });

  test('单站抛错只丢该站，其余照常', () async {
    failing = {'jar:testcfg:SiteA'};
    final page = await repository.searchAcross(siteIds, '剧');
    expect(
      page.items.map((d) => d.source),
      ['jar:testcfg:SiteB', 'jar:testcfg:SiteC'],
    );
    expect(page.warning, contains('站SiteA'));
  });

  test('全站失败回空页带 warning，不抛错', () async {
    failing = siteIds.toSet();
    final page = await repository.searchAcross(siteIds, '剧');
    expect(page.items, isEmpty);
    expect(page.warning, isNotEmpty);
  });

  test('失败提示文案：单家点名，多家点首名加总数', () {
    expect(searchAcrossFailureWarning([]), '');
    expect(
      searchAcrossFailureWarning(['jar:testcfg:SiteA']),
      '站SiteA 未返回结果',
    );
    expect(
      searchAcrossFailureWarning(['jar:testcfg:SiteB', 'jar:testcfg:SiteA']),
      '站SiteA 等 2 个站源未返回结果',
    );
  });
}
