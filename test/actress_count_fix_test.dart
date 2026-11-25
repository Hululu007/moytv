// 女优库计数修复（2026-11-20）：列表卡片数与详情页数必须读同一份
// 入库 works 计数（works 表行数），不许用站方宣称数；同步进行中
// 列表卡片数要跟着涨；右上角切换站点随站源注册动态更新。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_json_fallback.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_mytv_bind.dart';
import 'package:moyi/imported_site_record.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<LocalStore> _makeStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Future<ActressPerson> _seedPerson(
  MemoryActressDatabase db,
  String name, {
  int worksHint = 0,
  int works = 0,
}) async {
  final person = (await db.upsertRosterPerson(
    RosterPerson(
      source: ActressRosterSourceId.chaoliu,
      sourceId: 'id-$name',
      name: name,
      worksHint: worksHint,
    ),
  ))!;
  if (works > 0) {
    await db.upsertWorks(
      person.localId,
      [for (var i = 0; i < works; i++) RosterFilm(code: 'TST-${i + 1}')],
      site: ActressRosterSourceId.chaoliu.name,
    );
  }
  return (await db.personById(person.localId))!;
}

void main() {
  group('计数：列表与详情读同一份入库数', () {
    late MemoryActressDatabase db;

    setUp(() {
      db = MemoryActressDatabase();
    });

    test('列表与详情对同一个人返回同一数', () async {
      final person = await _seedPerson(db, '计数演员', works: 5);
      final listed = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
      );
      final detailed = await db.personById(person.localId);
      final counted = await db.countWorks(person.localId);
      expect(listed, hasLength(1));
      expect(listed.first.displayWorks, 5);
      expect(detailed!.displayWorks, 5);
      expect(counted, 5);
    });

    test('宣称数大于入库数时列表显示入库数', () async {
      // 名册宣称 6956 部（安倍亚沙美旧例），实际只入库 3 部。
      final person = await _seedPerson(db, '宣称演员', worksHint: 6956, works: 3);
      expect(person.rosterWorks, 6956);
      final listed = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
      );
      expect(listed.first.displayWorks, 3);
      expect((await db.personById(person.localId))!.displayWorks, 3);
    });

    test('新增作品后列表数与 works 表一致（含跨站新增行）', () async {
      final person = await _seedPerson(db, '叠加演员', works: 2);
      await db.attachCover(
        personId: person.localId,
        codeKey: 'NEW1',
        titleKey: 'new1',
        codeDisplay: 'NEW-001',
        title: '新作品',
        coverSource: 'whos',
        coverDramaId: 'd1',
        coverUrl: 'https://x/1.jpg',
        site: 'whos',
      );
      final listed = await db.listPersons(
        sex: ActressSexFilter.all,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 60,
      );
      expect(listed.first.displayWorks, 3);
      expect(await db.countWorks(person.localId), 3);
      expect((await db.personById(person.localId))!.displayWorks, 3);
    });
  });

  group('切换站点：随站源注册动态更新', () {
    const record = ImportedSiteRecord(
      id: 'py:newstation',
      name: '新站',
      type: ImportedSiteRecord.typePy,
      fileName: 'newstation.py',
      contentHash: 'abc',
    );

    test('新站导入后选项里有它，隐藏/摘掉后没有', () async {
      final store = await _makeStore();
      List<String> optionIds() => actressSiteFilterOptions(
        store,
      ).map((option) => option.siteId).toList();
      expect(optionIds(), isNot(contains('py:newstation')));
      await store.syncImportedSites([record]);
      expect(optionIds(), contains('py:newstation'));
      expect(
        actressSiteFilterOptions(
          store,
        ).firstWhere((option) => option.siteId == 'py:newstation').label,
        '新站',
      );
      await store.setSiteVisible('py:newstation', false);
      expect(optionIds(), isNot(contains('py:newstation')));
      await store.setSiteVisible('py:newstation', true);
      expect(optionIds(), contains('py:newstation'));
      await store.syncImportedSites([]);
      expect(optionIds(), isNot(contains('py:newstation')));
    });
  });

  group('界面：同步进行中卡片数跟着涨', () {
    late MemoryActressDatabase db;
    late FixtureRepository repository;
    late LocalStore store;
    // 兜底预加载（树里既定做法）：真机兜底的异步文件 IO 在 widget
    // 测试 FakeAsync 下挂起；setUp 在真实异步区，先读完再注入，
    // 页面里 loaded 已是真，选站不等人。
    late ActressJsonFallback fallback;

    setUp(() async {
      db = MemoryActressDatabase();
      repository = FixtureRepository();
      store = await _makeStore();
      fallback = ActressJsonFallback();
      await fallback.load();
      // MYTV 绑定预解析（与兜底预加载同理）：_bootstrap 开头 await
      // ensureBound()，它里面有异步文件 IO（探针写/删），在 widget
      // 测试 FakeAsync 下挂起；setUp 在真实异步区，先解析完缓存
      // 起来，页内再调直接回缓存值。解析只落系统临时目录，不动
      // 真库（测试都注入内存库）。
      await ActressMytvBind.instance.ensureBound();
    });

    testWidgets('新站导入后菜单里有它，选中站被摘掉后回全部', (tester) async {
      await _seedPerson(db, '菜单演员', works: 1);
      await tester.pumpWidget(
        MaterialApp(
          home: ActressListPage(
            repository: repository,
            store: store,
            database: db,
            fallback: fallback,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> openMenu() async {
        await tester.tap(
          find.byKey(const ValueKey('actress-site-filter')),
        );
        await tester.pumpAndSettle();
      }

      await openMenu();
      expect(find.text('新站'), findsNothing);
      // 选“全部”关掉菜单（与当前选中相同，不触发重读）。
      await tester.tap(find.text('全部').last);
      await tester.pumpAndSettle();
      // 运行时导入新站：菜单下次打开即有它。快照提交走异步文件 IO，
      // 在 widget 测试 FakeAsync 下挂起，用 runAsync 放到真实异
      // 步区跑（树里既定做法）。
      await tester.runAsync(
        () => store.syncImportedSites([
          const ImportedSiteRecord(
            id: 'py:newstation',
            name: '新站',
            type: ImportedSiteRecord.typePy,
            fileName: 'newstation.py',
            contentHash: 'abc',
          ),
        ]),
      );
      await tester.pump();
      await openMenu();
      expect(find.text('新站'), findsOneWidget);
      // 选中新站：顶栏选中态变成新站。
      await tester.tap(find.text('新站'));
      await tester.pumpAndSettle();
      expect(find.text('新站'), findsOneWidget);
      // 摘掉该站：选中态失效，自动回“全部”。
      await tester.runAsync(() => store.syncImportedSites([]));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('新站'), findsNothing);
      await openMenu();
      expect(find.text('全部'), findsWidgets);
    });
  });
}
