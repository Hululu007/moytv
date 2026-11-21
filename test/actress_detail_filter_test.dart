// 女优详情页分类标签筛选（2026-11-20 用户令）：
// ① 入库时记分类（json 的 type_name / 现爬的分类名），名册源作品
//    无分类记空，不编假分类；
// ② 详情页作品网格上方另起一行分类标签（“全部”+ 该女优作品里实际
//    有的分类，带部数），点中只筛当前这个女优的作品；
// ③ 头顶“作品 N 部”总数不受筛选影响；无分类作品只在“全部”里；
// ④ 头顶“无码”“推荐”人物标签原样不动，与筛选行互不干扰。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _makeFilterStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  group('分类入库', () {
    late MemoryActressDatabase db;
    late ActressPerson person;

    setUp(() async {
      db = MemoryActressDatabase();
      person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'F1',
          name: '测试女优',
          sex: 'female',
          tags: ['无码', '推荐'],
        ),
      ))!;
    });

    test('upsertWorks 记分类，workCategories 只出非空分类、按部数排', () async {
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-001', title: '中文字幕作品一', category: '中文字幕'),
        RosterFilm(code: 'SSIS-002', title: '中文字幕作品二', category: '中文字幕'),
        RosterFilm(code: 'ABP-001', title: '国产自拍作品', category: '国产自拍'),
        RosterFilm(code: 'IPX-001', title: '无分类作品'),
      ], site: 'chaoliu');
      expect(await db.countWorks(person.localId), 4);
      final categories = await db.workCategories(person.localId);
      expect(
        categories.map((c) => (c.name, c.count)).toList(),
        [('中文字幕', 2), ('国产自拍', 1)],
      );
      expect(
        (await db.worksForPerson(
          person.localId,
          offset: 0,
          limit: 10,
          category: '中文字幕',
        )).map((w) => w.codeDisplay),
        ['SSIS-001', 'SSIS-002'],
      );
      expect(
        await db.countWorks(person.localId, category: '国产自拍'),
        1,
      );
      // 不带分类参数 = 全部：无分类作品也在内。
      expect(
        (await db.worksForPerson(person.localId, offset: 0, limit: 10))
            .length,
        4,
      );
    });

    test('冲突行分类回填：先同步写空分类，镜像再写带分类', () async {
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-001', title: '回填作品'),
      ], site: 'chaoliu');
      var works = await db.worksForPerson(person.localId, offset: 0, limit: 10);
      expect(works.single.category, '');
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-001', title: '回填作品', category: '中文字幕'),
      ], site: 'chaoliu');
      works = await db.worksForPerson(person.localId, offset: 0, limit: 10);
      expect(works.length, 1);
      expect(works.single.category, '中文字幕');
      // 已有分类的行不再被覆盖。
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-001', title: '回填作品', category: '国产自拍'),
      ], site: 'chaoliu');
      works = await db.worksForPerson(person.localId, offset: 0, limit: 10);
      expect(works.single.category, '中文字幕');
    });

    test('无番号行也回填分类', () async {
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: '', title: '无番号作品'),
      ], site: 'chaoliu');
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: '', title: '无番号作品', category: '素人'),
      ], site: 'chaoliu');
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.length, 1);
      expect(works.single.category, '素人');
    });

    test('镜像把 json 的 type_name 记成分类', () async {
      ActressJsonEntry entry({
        required String code,
        required String typeName,
      }) => ActressJsonEntry(
        site: 'mjv',
        vodId: 'mjv:$code',
        vodName: '镜像作品$code',
        vodPic: '',
        vodActor: '测试女优',
        vodDirector: '',
        vodRemarks: '高清',
        vodPubdate: '2026-10-27',
        vodArea: '',
        vodYear: '',
        vodContent: '',
        vodPlayFrom: 'mjv011',
        vodPlayUrl: '',
        typeName: typeName,
        vodCode: code,
        vodActressPic: '',
      );
      await mirrorActressJsonEntriesToDb(db, [
        entry(code: 'SSIS-001', typeName: '中文字幕'),
        entry(code: 'ABP-001', typeName: '国产自拍'),
      ]);
      final works = await db.worksForPerson(
        person.localId,
        offset: 0,
        limit: 10,
      );
      expect(works.length, 2);
      expect(
        {for (final w in works) w.codeDisplay: w.category},
        {'SSIS-001': '中文字幕', 'ABP-001': '国产自拍'},
      );
      expect(
        (await db.workCategories(person.localId))
            .map((c) => c.name)
            .toList(),
        ['中文字幕', '国产自拍'],
      );
    });
  });

  group('详情页筛选行', () {
    late MemoryActressDatabase db;
    late FixtureRepository repository;
    late LocalStore store;
    late ActressPerson person;

    setUp(() async {
      db = MemoryActressDatabase();
      repository = FixtureRepository();
      store = await _makeFilterStore();
      person = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'F1',
          name: '测试女优',
          sex: 'female',
          tags: ['无码', '推荐'],
        ),
      ))!;
      await db.upsertWorks(person.localId, const [
        RosterFilm(code: 'SSIS-001', title: '中文字幕作品一', category: '中文字幕'),
        RosterFilm(code: 'SSIS-002', title: '中文字幕作品二', category: '中文字幕'),
        RosterFilm(code: 'ABP-001', title: '国产自拍作品', category: '国产自拍'),
        RosterFilm(code: 'IPX-001', title: '无分类作品'),
      ], site: 'chaoliu');
    });

    Future<void> pumpDetail(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: person.localId,
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('筛选行出现：全部 + 实际分类带部数，头顶标签不动', (tester) async {
      await pumpDetail(tester);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('中文字幕（2）'), findsOneWidget);
      expect(find.text('国产自拍（1）'), findsOneWidget);
      // 头顶人物标签原样不动。
      expect(find.text('无码'), findsOneWidget);
      expect(find.text('推荐'), findsOneWidget);
      expect(find.text('作品 4 部 · 女'), findsOneWidget);
      expect(find.byType(DramaTile), findsNWidgets(4));
      expect(find.text('无分类作品'), findsOneWidget);
    });

    testWidgets('点分类只筛当前女优作品，头顶总数不动；点全部恢复', (
      tester,
    ) async {
      await pumpDetail(tester);
      await tester.tap(find.text('国产自拍（1）'));
      await tester.pumpAndSettle();
      expect(find.byType(DramaTile), findsOneWidget);
      expect(find.text('国产自拍作品'), findsOneWidget);
      expect(find.text('中文字幕作品一'), findsNothing);
      expect(find.text('无分类作品'), findsNothing);
      // 头顶总数还是入库总数，不跟着筛选变。
      expect(find.text('作品 4 部 · 女'), findsOneWidget);
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(find.byType(DramaTile), findsNWidgets(4));
      expect(find.text('无分类作品'), findsOneWidget);
    });

    testWidgets('没有分类的女优不画筛选行', (tester) async {
      final plain = (await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'F2',
          name: '无分类女优',
          sex: 'female',
        ),
      ))!;
      await db.upsertWorks(plain.localId, const [
        RosterFilm(code: 'SSIS-009', title: '只有一部无分类作品'),
      ], site: 'chaoliu');
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressDetailPage(
            localId: plain.localId,
            repository: repository,
            store: store,
            database: db,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全部'), findsNothing);
      expect(find.byType(DramaTile), findsOneWidget);
    });
  });
}
