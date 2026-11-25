import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';


Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  group('番号搜索键', () {
    test('标准番号与大小写/分隔符变体都认', () {
      expect(actressCodeQueryKey('SSIS-123'), 'SSIS123');
      expect(actressCodeQueryKey('ssis123'), 'SSIS123');
      expect(actressCodeQueryKey('SSIS 00123'), 'SSIS123');
      expect(actressCodeQueryKey('ABW-123'), 'ABW123');
      expect(actressCodeQueryKey('FC2-PPV-1234567'), 'FC2PPV1234567');
      expect(actressCodeQueryKey('1PONDO-102726'), '1PONDO102726');
    });

    test('纯名字、纯数字、纯字母、太短都不认', () {
      expect(actressCodeQueryKey('波多野結衣'), isNull);
      expect(actressCodeQueryKey('Yua Mikami'), isNull);
      expect(actressCodeQueryKey('123'), isNull);
      expect(actressCodeQueryKey('abc'), isNull);
      expect(actressCodeQueryKey('A1'), isNull);
      expect(actressCodeQueryKey(''), isNull);
      expect(actressCodeQueryKey('  '), isNull);
    });
  });

  group('姓名分组键', () {
    test('拉丁字母开头取大写首字母', () {
      expect(actressGroupKey('Yua Mikami'), 'Y');
      expect(actressGroupKey('alice'), 'A');
      expect(actressGroupKey('  Bob'), 'B');
    });

    test('假名开头按五十音行换算', () {
      expect(actressGroupKey('あいだ'), 'A');
      expect(actressGroupKey('カナ'), 'K');
      expect(actressGroupKey('さくら'), 'S');
      expect(actressGroupKey('たちばな'), 'T');
      expect(actressGroupKey('なな'), 'N');
      expect(actressGroupKey('はな'), 'H');
      expect(actressGroupKey('まみ'), 'M');
      expect(actressGroupKey('やよい'), 'Y');
      expect(actressGroupKey('らん'), 'R');
      expect(actressGroupKey('わかな'), 'W');
      expect(actressGroupKey('マッスル澤野'), 'M');
      expect(actressGroupKey('セツネヒデユキ'), 'S');
    });

    test('汉字开头看别名，都没有则归 # 组', () {
      expect(actressGroupKey('波多野結衣'), '#');
      expect(actressGroupKey('波多野結衣', ['Hata no Yui']), 'H');
      expect(actressGroupKey('小田切ジュン'), '#');
      expect(actressGroupKey(''), '#');
      expect(actressGroupKey('123abc'), '#');
    });
  });

  group('内存库番号搜索', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    Future<ActressPerson> seedPerson(String name) async =>
        (await db.upsertRosterPerson(
          RosterPerson(
            source: ActressRosterSourceId.chaoliu,
            sourceId: 'id-$name',
            name: name,
            sex: 'female',
          ),
        ))!;

    Future<List<ActressPerson>> search(String query) => db.listPersons(
      sex: ActressSexFilter.all,
      sort: ActressSort.nameAsc,
      query: query,
      offset: 0,
      limit: 60,
    );

    test('输番号只命中持有该作品的人', () async {
      final a = await seedPerson('女演员甲');
      await seedPerson('女演员乙');
      await db.upsertWorks(a.localId, [
        const RosterFilm(code: 'SSIS-123', title: 'SSIS-123 标题'),
      ]);
      final hits = await search('SSIS-123');
      expect(hits.map((p) => p.displayName), ['女演员甲']);
    });

    test('番号前缀模糊匹配，名字搜索不受影响', () async {
      final a = await seedPerson('女演员甲');
      await seedPerson('女演员乙');
      await db.upsertWorks(a.localId, [
        const RosterFilm(code: 'SSIS-123'),
      ]);
      expect(
        (await search('ssis-12')).map((p) => p.displayName),
        ['女演员甲'],
      );
      expect(
        (await search('女演员乙')).map((p) => p.displayName),
        ['女演员乙'],
      );
      expect(await search('ABW-999'), isEmpty);
      expect(await search('123'), isEmpty);
    });
  });

  group('列表页', () {
    late MemoryActressDatabase db;
    late FixtureRepository repository;
    late LocalStore store;

    setUp(() async {
      db = MemoryActressDatabase();
      repository = FixtureRepository();
      store = await _makeStore();
    });

    Future<void> seedPerson(String name, {String code = ''}) async {
      final person = (await db.upsertRosterPerson(
        RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'id-$name',
          name: name,
          sex: 'female',
        ),
      ))!;
      if (code.isNotEmpty) {
        await db.upsertWorks(person.localId, [RosterFilm(code: code)]);
      }
    }

    Future<void> pumpPage(WidgetTester tester) async {
      // 列表页 bootstrap 里 await MYTV 绑定（平台通道），FakeAsync
      // 下等不到返回会 pumpAndSettle 超时——按树里老办法包进
      // runAsync（真机上绑定是毫秒级，不改生产代码）。
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: repository,
              store: store,
              database: db,
            ),
          ),
        );
        await tester.pumpAndSettle();
      });
    }

    testWidgets('按名字排序时显示姓名分组头', (tester) async {
      // 视口加高：三组宫格叠起来超过默认 600 高，分组段是懒加载的，
      // 折叠线下的组头不滚到可见处就不会建出来。
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await seedPerson('Alice');
      await seedPerson('Bob');
      await seedPerson('あいだ');
      await seedPerson('波多野結衣');
      await pumpPage(tester);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byKey(const ValueKey('actress-group-A')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('actress-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按名字'));
      await tester.pumpAndSettle();
      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.byKey(const ValueKey('actress-group-A')), findsOneWidget);
      expect(find.byKey(const ValueKey('actress-group-B')), findsOneWidget);
      expect(find.byKey(const ValueKey('actress-group-#')), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('波多野結衣'), findsOneWidget);
    });

    testWidgets('搜索框输番号只留持有该作品的人', (tester) async {
      await seedPerson('女演员甲', code: 'SSIS-123');
      await seedPerson('女演员乙', code: 'ABW-456');
      await pumpPage(tester);
      await tester.enterText(
        find.byKey(const ValueKey('actress-search')),
        'SSIS-123',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('女演员甲'), findsOneWidget);
      expect(find.text('女演员乙'), findsNothing);
    });
  });
}
