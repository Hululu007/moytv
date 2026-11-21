import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_search.dart';
import 'package:moyi/actress/actress_stacking.dart';
import 'package:moyi/actress/actress_sync.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 女优库全站叠加：按番号把各站作品叠加进库，断点续跑。
///
/// - 复用详情页同一套补全（ActressEnrichment），不另写去重逻辑；
/// - 断点是独立检查点（source/phase 均为 'stacking'），与三家名册
///   源的检查点分键，与 enrichedAt 各记各的；
/// - 列表数 displayWorks 只算入库的 worksCount（2026-11-20 口径
///   “要入库才算”，不再取 rosterWorks 的较大者），写库刷新
///   works_count 后自动跟涨，不另起计数路径。

const _stackSiteA = SourceSite(
  'test-stack-a',
  '🔞测试站A',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);
const _stackSiteB = SourceSite(
  'test-stack-b',
  '测试站B',
  '测试站',
  section: SourceSite.sectionVideo,
  origin: SourceSite.originImport,
);

void _registerStackSites() {
  for (final site in [_stackSiteA, _stackSiteB]) {
    SourceSite.importedSites[site.id] = site;
  }
}

void _unregisterStackSites() {
  for (final site in [_stackSiteA, _stackSiteB]) {
    SourceSite.importedSites.remove(site.id);
  }
}

class _StackScriptedRepository extends FixtureRepository {
  Map<String, List<Drama>> searchByQuery = {};
  final searchQueries = <String>[];
  Completer<void>? gate;
  String gateQuery = '';
  var gateEntered = false;

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async {
    searchQueries.add(query);
    if (gate != null && query == gateQuery) {
      gateEntered = true;
      await gate!.future;
    }
    return CatalogPage(searchByQuery[query] ?? const []);
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
}

Drama _hit({required String code, required String site}) => Drama(
  id: '$site:$code',
  source: site,
  sourceId: site,
  title: '$code 测试作品',
  cover: 'https://cover.example/$code.jpg',
);

Future<ActressPerson> _seedPerson(
  MemoryActressDatabase db,
  String name, {
  int worksHint = 0,
}) async {
  final person = await db.upsertRosterPerson(
    RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'seed-$name',
      name: name,
      sex: 'female',
      worksHint: worksHint,
    ),
  );
  return person!;
}

/// 给某人直接种一行带封面的作品（补全跳过语义测试用）。
Future<void> _seedCoveredWork(
  MemoryActressDatabase db,
  int personId,
  String code,
) async {
  await db.attachCover(
    personId: personId,
    codeKey: normalizeAvCode(code),
    titleKey: actressTitleKey('$code 测试作品'),
    codeDisplay: code,
    title: '$code 测试作品',
    coverSource: 'test-stack-a',
    coverDramaId: 'test-stack-a:$code',
    coverUrl: 'https://cover.example/$code.jpg',
  );
}

void main() {
  group('全站叠加服务', () {
    late MemoryActressDatabase db;
    late _StackScriptedRepository repository;
    late LocalStore store;
    late ActressEnrichment enrichment;

    setUp(() async {
      _registerStackSites();
      addTearDown(_unregisterStackSites);
      db = MemoryActressDatabase();
      repository = _StackScriptedRepository();
      SharedPreferences.setMockInitialValues({});
      store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      enrichment = ActressEnrichment(
        repository: repository,
        store: store,
        db: db,
      );
    });

    ActressStackingService newService({int personBudget = 10}) {
      final service = ActressStackingService(
        db: db,
        enrichment: enrichment,
        personBudget: personBudget,
      );
      addTearDown(service.dispose);
      return service;
    }

    test('断点续跑：每轮按预算推进，下一轮从断点续，不重跑', () async {
      final ids = <int>[];
      for (var i = 1; i <= 5; i++) {
        final person = await _seedPerson(db, '演员$i');
        ids.add(person.localId);
        await db.upsertWorks(person.localId, [
          RosterFilm(code: 'CODE-$i', title: '作品$i'),
        ]);
      }
      final service = newService(personBudget: 2);

      final first = await service.run();
      expect(first.processed, 2);
      expect(first.finished, isFalse);
      var cp = await db.stackingCheckpoint();
      expect(cp?.cursor, '${ids[1]}');
      expect(cp?.total, 2);
      expect(cp?.finished, isFalse);
      expect(
        repository.searchQueries.where((q) => q.contains('演员3')),
        isEmpty,
      );

      final second = await service.run();
      expect(second.processed, 2);
      cp = await db.stackingCheckpoint();
      expect(cp?.cursor, '${ids[3]}');
      expect(cp?.total, 4);

      final third = await service.run();
      expect(third.processed, 1);
      expect(third.finished, isTrue);
      cp = await db.stackingCheckpoint();
      expect(cp?.finished, isTrue);

      // 跑完后再跑：零处理，不重拉。
      final queriesBefore = repository.searchQueries.length;
      final fourth = await service.run();
      expect(fourth.processed, 0);
      expect(fourth.finished, isTrue);
      expect(repository.searchQueries.length, queriesBefore);

      // 每人恰好被查过一次名字（断点续跑没有重复查）。
      for (var i = 1; i <= 5; i++) {
        expect(
          repository.searchQueries.where((q) => q == '演员$i').length,
          1,
        );
      }
    });

    test('番号去重按站：同一番号同站只留一行、两站各留一条', () async {
      final person = await _seedPerson(db, '演员甲');
      await db.upsertWorks(person.localId, [
        const RosterFilm(code: 'SSIS-100', title: '旧作'),
      ]);
      repository.searchByQuery['演员甲'] = [
        _hit(code: 'SSIS-00123', site: 'test-stack-a'),
        _hit(code: 'SSIS123', site: 'test-stack-b'),
        _hit(code: 'SSIS-124', site: 'test-stack-a'),
      ];

      final result = await newService().run();
      expect(result.processed, 1);
      // SSIS-00123 与 SSIS123 归一化同一部，但来自两站，各留一条；
      // SSIS-124 再一条，共新增 3 行。
      expect(result.worksAdded, 3);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 50,
      );
      expect(works.length, 4);
      expect(
        works.map((work) => work.codeKey).toList()..sort(),
        ['SSIS100', 'SSIS123', 'SSIS123', 'SSIS124'],
      );
      expect(
        works
            .where((work) => work.codeKey == 'SSIS123')
            .map((work) => work.site)
            .toSet(),
        {'test-stack-a', 'test-stack-b'},
      );
    });

    test('写库刷新 works_count，列表数自动跟涨', () async {
      final person = await _seedPerson(db, '演员乙', worksHint: 1);
      await db.upsertWorks(person.localId, [
        const RosterFilm(code: 'SSIS-100', title: '旧作'),
      ]);
      var stored = await db.personById(person.localId);
      expect(stored?.worksCount, 1);
      expect(stored?.displayWorks, 1);
      repository.searchByQuery['演员乙'] = [
        _hit(code: 'SSIS-200', site: 'test-stack-a'),
        _hit(code: 'SSIS-201', site: 'test-stack-b'),
      ];

      final result = await newService().run();
      expect(result.worksAdded, 2);
      stored = await db.personById(person.localId);
      expect(stored?.worksCount, 3);
      expect(stored?.rosterWorks, 1);
      expect(stored?.displayWorks, 3);
    });

    test('叠加不看 enrichedAt：已记但有无封面作品时照样补', () async {
      final person = await _seedPerson(db, '演员丙');
      await db.upsertWorks(person.localId, [
        const RosterFilm(code: 'SSIS-300', title: '无封面作'),
      ]);
      await db.markEnriched(person.localId);
      repository.searchByQuery['演员丙'] = [
        _hit(code: 'SSIS-300', site: 'test-stack-a'),
      ];

      await newService().run();
      expect(repository.searchQueries, contains('演员丙'));
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.single.hasCover, isTrue);
      final cp = await db.stackingCheckpoint();
      expect(cp?.finished, isTrue);
    });

    test('已补过且全有封面时补全快速跳过，叠加断点照样推进', () async {
      final person = await _seedPerson(db, '演员丁');
      await _seedCoveredWork(db, person.localId, 'SSIS-400');
      await db.markEnriched(person.localId);

      await newService().run();
      // 补全内部跳过：一次搜索都没发。
      expect(repository.searchQueries, isEmpty);
      // 叠加断点照样越过此人，全轮完成。
      final cp = await db.stackingCheckpoint();
      expect(cp?.finished, isTrue);
      expect(cp?.cursor, '${person.localId}');
    });

    test('空作品人照样越过断点，全轮能完成', () async {
      final empty = await _seedPerson(db, '演员空');
      final full = await _seedPerson(db, '演员满');
      await db.upsertWorks(full.localId, [
        const RosterFilm(code: 'BBB-1', title: '作满'),
      ]);

      final result = await newService().run();
      expect(result.processed, 2);
      expect(result.finished, isTrue);
      // 2026-11-20 新规：零作品的人也按名搜（搜不到保持为空），
      // 不再跳过；断点照样越过此人，全轮完成。
      expect(
        repository.searchQueries.where((q) => q == '演员空'),
        contains('演员空'),
      );
      expect(empty.localId, isNot(0));
    });

    test('取消后存断点，下次从断点续', () async {
      final first = await _seedPerson(db, '演员一');
      await db.upsertWorks(first.localId, [
        const RosterFilm(code: 'AAA-1', title: '作一'),
      ]);
      final secondPerson = await _seedPerson(db, '演员二');
      await db.upsertWorks(secondPerson.localId, [
        const RosterFilm(code: 'AAA-2', title: '作二'),
      ]);
      repository.gateQuery = '演员二';
      repository.gate = Completer<void>();
      final service = newService();

      final runFuture = service.run();
      for (var i = 0; i < 200 && !repository.gateEntered; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(repository.gateEntered, isTrue);
      service.cancel();
      repository.gate!.complete();
      final result = await runFuture;
      expect(result.cancelled, isTrue);
      expect(result.processed, 1);
      var cp = await db.stackingCheckpoint();
      expect(cp?.cursor, '${first.localId}');
      expect(cp?.finished, isFalse);

      repository.gate = null;
      final resumed = await service.run();
      expect(resumed.processed, 1);
      expect(resumed.finished, isTrue);
      cp = await db.stackingCheckpoint();
      expect(cp?.cursor, '${secondPerson.localId}');
    });

    test('跑着时重复 run 返回同一份结果', () async {
      final person = await _seedPerson(db, '演员戊');
      await db.upsertWorks(person.localId, [
        const RosterFilm(code: 'CCC-1', title: '作戊'),
      ]);
      repository.gateQuery = '演员戊';
      repository.gate = Completer<void>();
      final service = newService();

      final first = service.run();
      final second = service.run();
      for (var i = 0; i < 200 && !repository.gateEntered; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(repository.gateEntered, isTrue);
      repository.gate!.complete();
      final result = await first;
      expect(result.processed, 1);
      expect((await second).processed, 1);
      // 只跑了一轮：名字只被查过一次，没有重复开跑。
      expect(
        repository.searchQueries.where((q) => q == '演员戊').length,
        1,
      );
    });
  });

  group('列表页叠加入口', () {
    testWidgets('点开始叠加，跑完显示完成', (tester) async {
      _registerStackSites();
      addTearDown(_unregisterStackSites);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final db = MemoryActressDatabase();
      // 压住自动同步：三家名册检查点全部记完成。
      for (final source in ActressRosterSourceId.values) {
        for (final phase in ['roster', 'films']) {
          await db.saveCheckpoint(
            ActressSyncCheckpoint(
              source: source.name,
              phase: phase,
              finished: true,
            ),
          );
        }
      }
      for (final name in ['演员甲', '演员乙']) {
        final person = await _seedPerson(db, name);
        await _seedCoveredWork(db, person.localId, 'SSIS-500');
        await db.markEnriched(person.localId);
      }
      final repository = _StackScriptedRepository();
      final sync = ActressSyncService(
        db: db,
        sources: const [],
        fetch:
            (
              String url, {
              Map<String, String> headers = const {},
              Duration timeout = const Duration(seconds: 20),
            }) async => throw UnimplementedError(),
      );
      final stacking = ActressStackingService(
        db: db,
        enrichment: ActressEnrichment(
          repository: repository,
          store: store,
          db: db,
        ),
        personBudget: 10,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            syncService: sync,
            stackingService: stacking,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('开始叠加'), findsOneWidget);
      expect(find.textContaining('全站叠加已完成'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('start-actress-stacking')));
      await tester.pumpAndSettle();
      expect(find.textContaining('全站叠加已完成'), findsOneWidget);
      expect(find.text('开始叠加'), findsNothing);
    });
  });
}
