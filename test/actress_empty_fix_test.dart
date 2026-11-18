import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_roster_sources.dart';
import 'package:moyi/actress/actress_sync.dart';

Future<ActressHttpResponse> _unusedFetch(
  String url, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
}) async => throw UnimplementedError('fake source must not fetch');

RosterPerson _chaoliuPerson(String id, String name) => RosterPerson(
  source: ActressRosterSourceId.chaoliu,
  sourceId: id,
  name: name,
  sex: 'female',
);

void main() {
  group('空作品清单记失败', () {
    test('回空列表记失败且不重试拉取、刷新重取后作品落库', () async {
      final db = MemoryActressDatabase();
      final films = <String, List<RosterFilm>>{'A': const []};
      final source = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [_chaoliuPerson('A', '演员甲')],
        ],
        filmsBySourceId: films,
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);

      final first = await sync.run();
      expect(first.works, 0);
      // 空结果只拉一次（判定在重试之外），且记失败留在待取里。
      expect(source.fetchedFilmsFor, ['A']);
      final pending = await db.personsPendingFilms(
        ActressRosterSourceId.chaoliu,
      );
      expect(pending.map((p) => p.displayName), ['演员甲']);
      final progress = await db.filmsProgress(ActressRosterSourceId.chaoliu);
      expect(progress.done, 0);
      expect(progress.total, 1);

      films['A'] = const [RosterFilm(code: 'SSIS-00123')];
      final second = await sync.run(refresh: true);
      expect(second.works, 1);
      expect(source.fetchedFilmsFor, ['A', 'A']);
      final pendingAfter = await db.personsPendingFilms(
        ActressRosterSourceId.chaoliu,
      );
      expect(pendingAfter, isEmpty);
    });
  });

  group('一次性修复 films_repair_v1', () {
    test('中毒状态第一次同步重取、第二次不再纳入', () async {
      final db = MemoryActressDatabase();
      final stored = await db.upsertRosterPerson(
        _chaoliuPerson('A', '演员甲'),
      );
      final personId = stored!.localId;
      // 中毒状态：已记 ok，但作品 0 行。
      await db.markFilmsState(
        personId,
        ActressRosterSourceId.chaoliu,
        ok: true,
      );
      final candidates = await db.personsNeedingFilmsRepair(
        ActressRosterSourceId.chaoliu,
      );
      expect(candidates.map((p) => p.localId), [personId]);

      final source = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [_chaoliuPerson('A', '演员甲')],
        ],
        filmsBySourceId: const {
          'A': [RosterFilm(code: 'SSIS-00123')],
        },
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);

      final first = await sync.run();
      expect(first.works, 1);
      expect(source.fetchedFilmsFor, ['A']);
      final repairCheckpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'films_repair_v1',
      );
      expect(repairCheckpoint, isNotNull);
      expect(repairCheckpoint!.finished, isTrue);

      // 第二次同步不再重取（修复只跑一次）。
      await sync.run();
      expect(source.fetchedFilmsFor, ['A']);
      expect(await db.countWorks(personId), 1);
    });

    test('修复检查点已完成时中毒状态不再重取', () async {
      final db = MemoryActressDatabase();
      final stored = await db.upsertRosterPerson(
        _chaoliuPerson('A', '演员甲'),
      );
      await db.markFilmsState(
        stored!.localId,
        ActressRosterSourceId.chaoliu,
        ok: true,
      );
      await db.saveCheckpoint(
        const ActressSyncCheckpoint(
          source: 'chaoliu',
          phase: 'films_repair_v1',
          finished: true,
        ),
      );
      final source = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [_chaoliuPerson('A', '演员甲')],
        ],
        filmsBySourceId: const {
          'A': [RosterFilm(code: 'SSIS-00123')],
        },
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);

      final result = await sync.run();
      expect(result.works, 0);
      expect(source.fetchedFilmsFor, isEmpty);
    });

    test('修复重取仍为空记失败、之后走正常失败重试', () async {
      final db = MemoryActressDatabase();
      final stored = await db.upsertRosterPerson(
        _chaoliuPerson('A', '演员甲'),
      );
      final personId = stored!.localId;
      await db.markFilmsState(
        personId,
        ActressRosterSourceId.chaoliu,
        ok: true,
      );
      final films = <String, List<RosterFilm>>{'A': const []};
      final source = FakeRosterSource(
        sourceId: ActressRosterSourceId.chaoliu,
        rosterPages: [
          [_chaoliuPerson('A', '演员甲')],
        ],
        filmsBySourceId: films,
      );
      final sync = ActressSyncService(
        db: db,
        sources: [source],
        fetch: _unusedFetch,
      );
      addTearDown(sync.dispose);

      // 第一次同步：修复重取仍为空，记失败；修复检查点照样记完成。
      final first = await sync.run();
      expect(first.works, 0);
      expect(source.fetchedFilmsFor, ['A']);
      final repairCheckpoint = await db.checkpoint(
        ActressRosterSourceId.chaoliu,
        'films_repair_v1',
      );
      expect(repairCheckpoint!.finished, isTrue);
      // 失败后回到正常待取清单（不再依赖修复通道）。
      final pending = await db.personsPendingFilms(
        ActressRosterSourceId.chaoliu,
      );
      expect(pending.map((p) => p.localId), [personId]);

      films['A'] = const [RosterFilm(code: 'SSIS-00123')];
      final second = await sync.run(refresh: true);
      expect(second.works, 1);
      expect(source.fetchedFilmsFor, ['A', 'A']);
    });

    test('有作品或未记 ok 的人不进修复候选', () async {
      final db = MemoryActressDatabase();
      final withWorks = await db.upsertRosterPerson(
        _chaoliuPerson('A', '演员甲'),
      );
      await db.upsertWorks(
        withWorks!.localId,
        const [RosterFilm(code: 'SSIS-00123')],
      );
      await db.markFilmsState(
        withWorks.localId,
        ActressRosterSourceId.chaoliu,
        ok: true,
      );
      final failed = await db.upsertRosterPerson(
        _chaoliuPerson('B', '演员乙'),
      );
      await db.markFilmsState(
        failed!.localId,
        ActressRosterSourceId.chaoliu,
        ok: false,
      );
      await db.upsertRosterPerson(_chaoliuPerson('C', '演员丙'));

      final candidates = await db.personsNeedingFilmsRepair(
        ActressRosterSourceId.chaoliu,
      );
      expect(candidates, isEmpty);
    });
  });

  group('parseChaoliuFilms 非数组抛错', () {
    test('解出对象/字符串/数字/null 时抛 StateError', () {
      for (final body in ['{"films":[]}', '"hello"', '123', 'null']) {
        expect(() => parseChaoliuFilms(body), throwsStateError);
      }
    });

    test('空数组照常返回空列表', () {
      expect(parseChaoliuFilms('[]'), isEmpty);
    });
  });
}
