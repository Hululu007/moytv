import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/builtin_py_sites.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/crosssite_probe.dart';
import 'package:moyi/crosssite_probe_section.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('extractAvId', () {
    test('standard code with hyphen', () {
      expect(extractAvId(title: 'HMN-927 无码破解'), 'HMN-927');
    });
    test('lowercase normalized', () {
      expect(extractAvId(title: 'hmn-927-lada 中文字幕'), 'HMN-927');
    });
    test('no separator in title', () {
      expect(extractAvId(title: 'SSIS123'), 'SSIS-123');
    });
    test('fc2 ppv full form', () {
      expect(extractAvId(title: 'FC2-PPV-1234567'), 'FC2-PPV-1234567');
      expect(extractAvId(title: 'fc2 ppv 1234567'), 'FC2-PPV-1234567');
    });
    test('digit-leading codes', () {
      expect(extractAvId(title: '1PONDO-102726'), '1PONDO-102726');
      expect(extractAvId(title: '259LUXU-1234'), '259LUXU-1234');
      expect(extractAvId(title: '10MUSUME-123456'), '10MUSUME-123456');
    });
    test('falls back to id only with separator', () {
      expect(extractAvId(title: '未知标题', id: 'hmn-927'), 'HMN-927');
      expect(extractAvId(title: '未知标题', id: 'video/abc123.html'), isNull);
    });
    test('no code returns null', () {
      expect(extractAvId(title: '测试短剧'), isNull);
      expect(extractAvId(title: '第3集'), isNull);
      expect(extractAvId(title: 'EP12 花絮'), isNull);
      expect(extractAvId(title: '1080P高清修复版'), isNull);
      expect(extractAvId(title: '2026年新片'), isNull);
      expect(extractAvId(title: ''), isNull);
    });
    test('stop prefixes are not codes', () {
      expect(extractAvId(title: 'HD-12345'), isNull);
      expect(extractAvId(title: 'EP-12345'), isNull);
    });
  });

  group('hit matching and version labels', () {
    test('matches across separators', () {
      expect(
        crossSiteHitMatches(title: 'hmn 927', id: '', avId: 'HMN-927'),
        isTrue,
      );
      expect(
        crossSiteHitMatches(title: '其它片', id: 'HMN_927', avId: 'HMN-927'),
        isTrue,
      );
      expect(
        crossSiteHitMatches(title: 'HMN-928', id: '', avId: 'HMN-927'),
        isFalse,
      );
    });
    test('version label keeps suffix', () {
      expect(
        crossSiteVersionLabel(
          title: 'hmn-927-lada 中文字幕',
          id: '',
          avId: 'HMN-927',
        ),
        'HMN-927-LADA',
      );
      expect(
        crossSiteVersionLabel(title: '[HMN-927] 正片', id: '', avId: 'HMN-927'),
        'HMN-927',
      );
      expect(
        crossSiteVersionLabel(title: '无代号标题', id: 'x', avId: 'HMN-927'),
        'HMN-927',
      );
    });
  });

  group('crossSiteLinesOf', () {
    test('groups episodes by flag, first episode per line', () {
      final detail = DramaDetail(
        const Drama(id: '1', source: 's', title: 't'),
        [
          Episode({'id': 'a', 'title': '线路1 · 正片', 'flag': '线路1'}, 1),
          Episode({'id': 'b', 'title': '线路1 · 第2集', 'flag': '线路1'}, 2),
          Episode({'id': 'c', 'title': '线路2 · 正片', 'flag': '线路2'}, 3),
        ],
      );
      final lines = crossSiteLinesOf(detail);
      expect(lines.map((line) => line.label), ['线路1', '线路2']);
      expect(lines.map((line) => line.episodeIndex), [0, 2]);
    });
    test('no flag info collapses to one line', () {
      final detail = DramaDetail(
        const Drama(id: '1', source: 's', title: 't'),
        [
          Episode({'id': 'a', 'title': '第1集'}, 1),
          Episode({'id': 'b', 'title': '第2集'}, 2),
        ],
      );
      final lines = crossSiteLinesOf(detail);
      expect(lines.length, 1);
      expect(lines.single.label, '正片');
      expect(lines.single.episodeIndex, 0);
    });
    test('empty detail has no lines', () {
      expect(
        crossSiteLinesOf(
          DramaDetail(const Drama(id: '1', source: 's', title: 't'), []),
        ),
        isEmpty,
      );
    });
  });

  group('planCrossSiteRows', () {
    test('all six providers planned, two without sources', () {
      final plans = planCrossSiteRows(
        siteAvailable: (_) => true,
        siteVisible: (_) => true,
      );
      expect(plans.map((plan) => plan.provider.id), [
        'avdb',
        'javmenu',
        'av01',
        'memojav',
        'missav',
        'jable',
      ]);
      expect(plans[0].siteId, isNull);
      expect(plans[1].siteId, BuiltinPySites.javmenuSiteId);
      expect(plans[2].siteId, 'jar:zakatv:zakav01');
      expect(plans[3].siteId, isNull);
      expect(plans[4].siteId, 'jar:zakatv:ZakaMissav');
      expect(plans[5].siteId, 'jar:zakatv:ZakaJable');
    });
    test('missav falls to next visible candidate', () {
      final plans = planCrossSiteRows(
        siteAvailable: (_) => true,
        siteVisible: (id) => id != 'jar:zakatv:ZakaMissav',
      );
      final missav = plans.firstWhere((plan) => plan.provider.id == 'missav');
      expect(missav.siteId, 'jar:zakatv:ZakaMissavOff');
    });
    test('hidden site omits the whole row', () {
      final plans = planCrossSiteRows(
        siteAvailable: (_) => true,
        siteVisible: (id) => id != 'jar:zakatv:zakav01',
      );
      expect(plans.any((plan) => plan.provider.id == 'av01'), isFalse);
      expect(plans.length, 5);
    });
    test('provider site ids match builtin registrations', () {
      for (final provider in crossSiteProviders) {
        for (final siteId in provider.siteIds) {
          if (provider.id == 'javmenu') {
            // py 内置站：运行时 id 即注册 key（importedSites 的键，
            // isPySource / isKnown 都认它），与注册常量交叉锁定，
            // 与 jar 侧 JarSiteSpec.siteIdFor 锁法同理。
            expect(siteId, BuiltinPySites.javmenuSiteId);
            expect(BuiltinPySites.javmenuSite.importType, 'py');
            expect(
              BuiltinPySites.javmenuAssetPath,
              'assets/py_spiders/javmenu.py',
            );
          } else {
            expect(siteId.startsWith('jar:zakatv:'), isTrue);
            final key = siteId.substring('jar:zakatv:'.length);
            expect(JarSiteSpec.siteIdFor('zakatv', key), siteId);
          }
        }
      }
    });
  });

  group('CrossSiteProbeService', () {
    late _ProbeFakeRepository repository;

    setUp(() {
      repository = _ProbeFakeRepository();
    });

    test('found with versions and lines', () async {
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927',
          ),
          const Drama(
            id: 'hmn-927-lada',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927-lada',
          ),
          const Drama(id: 'other', source: 'jar:zakatv:zakav01', title: '无关片'),
        ],
      };
      repository.detailResults = {
        'hmn-927': _detailWithFlags(['线路1', '线路2']),
        'hmn-927-lada': _detailWithFlags(['线路1']),
      };
      final service = CrossSiteProbeService(repository: repository);
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.status, CrossSiteProbeStatus.found);
      expect(result.versions.map((v) => v.label), ['HMN-927', 'HMN-927-LADA']);
      expect(result.versions[0].lines.map((l) => l.label), ['线路1', '线路2']);
      expect(result.versions[1].lines.map((l) => l.label), ['线路1']);
    });

    test('no matching hit means empty', () async {
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          const Drama(id: 'x', source: 'jar:zakatv:zakav01', title: '无关片'),
        ],
      };
      final service = CrossSiteProbeService(repository: repository);
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.status, CrossSiteProbeStatus.empty);
      expect(result.versions, isEmpty);
    });

    test('one failing detail does not sink the provider', () async {
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927',
          ),
          const Drama(
            id: 'hmn-927-lada',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927-lada',
          ),
        ],
      };
      repository.detailFailures = {'hmn-927'};
      repository.detailResults = {
        'hmn-927-lada': _detailWithFlags(['线路1']),
      };
      final service = CrossSiteProbeService(repository: repository);
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.status, CrossSiteProbeStatus.found);
      expect(result.versions.map((v) => v.label), ['HMN-927-LADA']);
    });

    test('search failure means failed, not thrown', () async {
      repository.searchFailures = {'jar:zakatv:zakav01'};
      final service = CrossSiteProbeService(repository: repository);
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.status, CrossSiteProbeStatus.failed);
    });

    test('per-site timeout means failed', () async {
      repository.hangSearch = true;
      final service = CrossSiteProbeService(
        repository: repository,
        perSiteTimeout: const Duration(milliseconds: 50),
      );
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.status, CrossSiteProbeStatus.failed);
    });

    test('total budget caps probeAll, fast provider still lands', () async {
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927',
          ),
        ],
      };
      repository.detailResults = {
        'hmn-927': _detailWithFlags(['线路1']),
      };
      repository.hangSites = {'jar:zakatv:ZakaJable'};
      final service = CrossSiteProbeService(
        repository: repository,
        perSiteTimeout: const Duration(seconds: 30),
        totalBudget: const Duration(milliseconds: 80),
      );
      final plans = [
        const CrossSiteRowPlan(
          provider: CrossSiteProvider(
            id: 'av01',
            name: 'AV01',
            siteIds: ['jar:zakatv:zakav01'],
            lazy: false,
          ),
          siteId: 'jar:zakatv:zakav01',
        ),
        const CrossSiteRowPlan(
          provider: CrossSiteProvider(
            id: 'jable',
            name: 'Jable',
            siteIds: ['jar:zakatv:ZakaJable'],
            lazy: true,
          ),
          siteId: 'jar:zakatv:ZakaJable',
        ),
      ];
      final results = await service.probeAll(plans, 'HMN-927');
      expect(results[0].status, CrossSiteProbeStatus.found);
      expect(results[1].status, CrossSiteProbeStatus.failed);
    });

    test('versions capped at maxVersions', () async {
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          for (var i = 0; i < 5; i++)
            Drama(
              id: 'hmn-927-v$i',
              source: 'jar:zakatv:zakav01',
              title: 'hmn-927-v$i',
            ),
        ],
      };
      for (var i = 0; i < 5; i++) {
        repository.detailResults['hmn-927-v$i'] = _detailWithFlags(['线路1']);
      }
      final service = CrossSiteProbeService(
        repository: repository,
        maxVersions: 3,
      );
      final result = await service.probeProvider(
        crossSiteProviders[2],
        'jar:zakatv:zakav01',
        'HMN-927',
      );
      expect(result.versions.length, 3);
    });
  });

  group('CrossSiteProbeSection widget', () {
    late _ProbeFakeRepository repository;
    late LocalStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repository = _ProbeFakeRepository();
      store = LocalStore(await SharedPreferences.getInstance());
      repository.searchResults = {
        'jar:zakatv:zakav01': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:zakav01',
            title: 'hmn-927',
          ),
        ],
        'jar:zakatv:ZakaJable': [
          const Drama(
            id: 'hmn-927',
            source: 'jar:zakatv:ZakaJable',
            title: 'hmn-927',
          ),
        ],
      };
      repository.detailResults = {
        'hmn-927': _detailWithFlags(['线路1', '线路2']),
      };
    });

    Future<void> pumpSection(
      WidgetTester tester, {
      void Function(DramaDetail, int)? onPlayLine,
      CrossSiteProbeService? service,
      LocalStore? storeOverride,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CrossSiteProbeSection(
                repository: repository,
                store: storeOverride ?? store,
                avId: 'HMN-927',
                onPlayLine: onPlayLine ?? (_, _) {},
                service:
                    service ?? CrossSiteProbeService(repository: repository),
                siteAvailable: (_) => true,
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets('shows six rows, lazy rows wait for tap', (tester) async {
      await pumpSection(tester);
      await settle(tester);
      expect(find.text('跨站选线路'), findsOneWidget);
      expect(find.text('HMN-927'), findsWidgets);
      expect(find.text('AVDB'), findsOneWidget);
      expect(find.text('JavMenu'), findsOneWidget);
      expect(find.text('MemoJav'), findsOneWidget);
      expect(find.text('未接入'), findsNWidgets(2));
      // 懒查两家尚未点按：显示“点击查询”，不发搜索。
      expect(find.text('点击查询'), findsNWidgets(2));
      expect(
        repository.searchCalls
            .where((call) => call.contains('ZakaJable'))
            .isEmpty,
        isTrue,
      );
      // AV01 已自动探到版本与线路。
      expect(find.text('线路1'), findsOneWidget);
      expect(find.text('线路2'), findsOneWidget);
    });

    testWidgets('tapping lazy row probes that provider only', (tester) async {
      await pumpSection(tester);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('crosssite-rowtap-jable')));
      await settle(tester);
      expect(find.text('点击查询'), findsOneWidget);
      expect(
        repository.searchCalls.any((call) => call.contains('ZakaJable')),
        isTrue,
      );
      expect(find.text('线路1'), findsNWidgets(2));
    });

    testWidgets('tapping a line plays through the callback', (tester) async {
      DramaDetail? played;
      var playedIndex = -1;
      await pumpSection(
        tester,
        onPlayLine: (detail, index) {
          played = detail;
          playedIndex = index;
        },
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('crosssite-line-av01-0-1')));
      expect(played, isNotNull);
      expect(playedIndex, 1);
      expect(played!.episodes[playedIndex].raw['flag'], '线路2');
    });

    testWidgets('failed probe shows retry and retries on tap', (tester) async {
      repository.searchFailures = {'jar:zakatv:zakav01'};
      await pumpSection(tester);
      await settle(tester);
      expect(find.text('× 查询失败，点按重试'), findsOneWidget);
      repository.searchFailures = {};
      await tester.tap(find.byKey(const ValueKey('crosssite-rowtap-av01')));
      await settle(tester);
      expect(find.text('× 查询失败，点按重试'), findsNothing);
      expect(find.text('线路1'), findsOneWidget);
    });

    testWidgets('empty probe shows cross mark', (tester) async {
      repository.searchResults = {'jar:zakatv:zakav01': []};
      await pumpSection(tester);
      await settle(tester);
      // 两家自动探活的（AV01 与 JavMenu）都探空，各标一个 ×。
      expect(find.text('× 无此片'), findsNWidgets(2));
    });

    testWidgets('javmenu row probes eagerly and shows lines', (tester) async {
      repository.searchResults['javmenu'] = [
        const Drama(id: 'hmn-927', source: 'javmenu', title: 'hmn-927'),
      ];
      await pumpSection(tester);
      await settle(tester);
      expect(
        repository.searchCalls.any((call) => call.startsWith('javmenu:')),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('crosssite-line-javmenu-0-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crosssite-line-javmenu-0-1')),
        findsOneWidget,
      );
    });

    testWidgets('hidden site row is omitted', (tester) async {
      // 藏站状态直接预置进偏好值（setSiteVisible 的写路径在假时钟
      // 下挂死，见 LocalSnapshot.commit 的平台通道等待）。
      SharedPreferences.setMockInitialValues({
        'hiddenSites': jsonEncode(['jar:zakatv:zakav01']),
      });
      final hiddenStore = LocalStore(await SharedPreferences.getInstance());
      await pumpSection(tester, storeOverride: hiddenStore);
      await settle(tester);
      expect(find.text('AV01'), findsNothing);
      expect(find.text('Jable'), findsOneWidget);
    });
  });

  group('DetailScreen wiring', () {
    const frameChannel = MethodChannel('moyi/frame_extractor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(() {
      messenger.setMockMethodCallHandler(frameChannel, (_) async => null);
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(frameChannel, null);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    testWidgets('coded drama shows cross-site section', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _NoCoverRouteRepository();
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            drama: const Drama(
              id: 'x:1',
              source: 'hongguo',
              title: 'HMN-927 测试片',
            ),
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('crosssite-section')), findsOneWidget);
      expect(find.text('跨站选线路'), findsOneWidget);
    });

    testWidgets('uncoded drama shows no cross-site section', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _NoCoverRouteRepository();
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            drama: FixtureRepository.free,
            repository: repository,
            store: store,
            playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
          ),
        ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('crosssite-section')), findsNothing);
      expect(find.text('跨站选线路'), findsNothing);
    });
  });
}

DramaDetail _detailWithFlags(List<String> flags) {
  final drama = const Drama(id: 'hmn-927', source: 's', title: 'hmn-927');
  return DramaDetail(drama, [
    for (var i = 0; i < flags.length; i++)
      Episode({
        'id': 'p$i',
        'title': '${flags[i]} · 正片',
        'flag': flags[i],
      }, i + 1),
  ]);
}

/// 详情页测试用仓库：封面直接返回空，避免封面加载失败后的
/// 延迟重试在 widget 销毁后 setState（与 detail_embedded_player_test
/// 的 EmbeddedRouteRepository 同一手法）。
class _NoCoverRouteRepository extends RouteRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

class _ProbeFakeRepository extends FixtureRepository {
  Map<String, List<Drama>> searchResults = {};
  Map<String, DramaDetail> detailResults = {};
  Set<String> searchFailures = {};
  Set<String> detailFailures = {};
  Set<String> hangSites = {};
  bool hangSearch = false;
  final searchCalls = <String>[];

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    for (final source in sources) {
      searchCalls.add('$source:$query');
      if (hangSearch || hangSites.contains(source)) {
        await Completer<void>().future;
      }
      if (searchFailures.contains(source)) {
        throw AppFailure('合成搜索失败');
      }
    }
    final items = <Drama>[];
    for (final source in sources) {
      items.addAll(searchResults[source] ?? const []);
    }
    return CatalogPage(items);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (detailFailures.contains(drama.id)) {
      throw AppFailure('合成详情失败');
    }
    final fixed = detailResults[drama.id];
    if (fixed != null) return fixed;
    return super.detail(drama);
  }
}
