// 流式跨源搜索：逐站回调按完成顺序、取消截断、单站隔离；
// 结果集合与批回 searchAcross 一致。复用 search_across_fanout_test
// 的 MethodChannel 假 jar 桥（同款注册与 mock handler）。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/models.dart';

import 'fixtures.dart';

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

  void registerSite(String siteId) {
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

  setUp(() {
    delays = {};
    failing = {};
    searchCalls = 0;
    repository = NativeRepository(
      searchPerSiteTimeout: const Duration(milliseconds: 300),
    );
    JarBridge.setTestJarPath('testcfg', '/tmp/test.jar');
    for (final siteId in siteIds) {
      registerSite(siteId);
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
    for (var i = 0; i < 5; i++) {
      final siteId = 'jar:testcfg:SiteX$i';
      JarBridge.unregister(siteId);
      SourceSite.importedSites.remove(siteId);
    }
    JarBridge.clearTestJarPaths();
    JarBridge.resetTestHomeCache();
  });

  test('逐站回调按完成顺序，快站先到；三站结果全到', () async {
    delays = {
      'jar:testcfg:SiteA': const Duration(milliseconds: 200),
      'jar:testcfg:SiteB': Duration.zero,
      'jar:testcfg:SiteC': const Duration(milliseconds: 100),
    };
    final order = <String>[];
    final seen = <String, List<Drama>>{};
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (source, items) {
        order.add(source);
        seen[source] = items;
      },
    );
    expect(order, [
      'jar:testcfg:SiteB',
      'jar:testcfg:SiteC',
      'jar:testcfg:SiteA',
    ]);
    expect(seen.keys.toSet(), siteIds.toSet());
    expect(
      seen['jar:testcfg:SiteA']!.map((d) => d.title),
      ['剧-jar:testcfg:SiteA'],
    );
    expect(searchCalls, 3);
  });

  test('流式结果集合与批回一致（同站同条目）', () async {
    final batch = await repository.searchAcross(siteIds, '剧');
    final streamed = <Drama>[];
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (_, items) => streamed.addAll(items),
    );
    expect(
      streamed.map((d) => d.id).toList()..sort(),
      batch.items.map((d) => d.id).toList()..sort(),
    );
  });

  test('单站超时只丢该站，其余照常回调', () async {
    delays = {'jar:testcfg:SiteB': const Duration(seconds: 5)};
    final order = <String>[];
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (source, _) => order.add(source),
    );
    expect(order, ['jar:testcfg:SiteA', 'jar:testcfg:SiteC']);
  });

  test('单站抛错只丢该站，其余照常回调', () async {
    failing = {'jar:testcfg:SiteA'};
    final order = <String>[];
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (source, _) => order.add(source),
    );
    expect(order, ['jar:testcfg:SiteB', 'jar:testcfg:SiteC']);
  });

  test('全站失败零回调，不抛错，正常完成', () async {
    failing = siteIds.toSet();
    var callbacks = 0;
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (_, _) => callbacks++,
    );
    expect(callbacks, 0);
  });

  test('取消后不再发起后续站，Future 正常完成', () async {
    // 8 个站、6 路：前 6 个立即启动；第一站回调后喊停，
    // 后 2 个永不启动；在途的 6 个跑完回调完即收尾。
    final manyIds = [
      ...siteIds,
      for (var i = 0; i < 5; i++) 'jar:testcfg:SiteX$i',
    ];
    for (var i = 0; i < 5; i++) {
      registerSite('jar:testcfg:SiteX$i');
    }
    delays = {
      for (final siteId in manyIds) siteId: const Duration(milliseconds: 200),
    };
    var stop = false;
    final order = <String>[];
    await repository
        .searchAcrossProgressive(
          manyIds,
          '剧',
          onSite: (source, _) {
            order.add(source);
            stop = true;
          },
          shouldStop: () => stop,
        )
        .timeout(const Duration(seconds: 5));
    expect(searchCalls, 6);
    expect(order, hasLength(6));
  });

  test('shouldStop 一开始就真：零调用、零回调、正常完成', () async {
    var callbacks = 0;
    await repository.searchAcrossProgressive(
      siteIds,
      '剧',
      onSite: (_, _) => callbacks++,
      shouldStop: () => true,
    );
    expect(searchCalls, 0);
    expect(callbacks, 0);
  });

  test('默认实现：批回拆包按站回调，顺序按首次出现', () async {
    final repo = FixtureRepository();
    final order = <String>[];
    final seen = <String, List<Drama>>{};
    await repo.searchAcrossProgressive(
      ['s1', 's2'],
      'q',
      onSite: (source, items) {
        order.add(source);
        seen[source] = items;
      },
    );
    expect(order, ['s1', 's2']);
    expect(seen['s1']!.map((d) => d.id), ['s1:auto-1']);
    expect(seen['s2']!.map((d) => d.id), ['s2:auto-1']);
  });

  test('默认实现：shouldStop 中途翻真，后续站不回调', () async {
    final repo = FixtureRepository();
    final order = <String>[];
    var calls = 0;
    await repo.searchAcrossProgressive(
      ['s1', 's2', 's3'],
      'q',
      onSite: (source, _) {
        order.add(source);
        calls++;
      },
      shouldStop: () => calls >= 1,
    );
    expect(order, ['s1']);
  });
}
