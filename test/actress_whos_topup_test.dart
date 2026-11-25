// 无库顶上测试（2026-11-25）：目录分页器、女优索引枚举、顶上视图
// （作品流/按女优看/搜索/点播回调）、列表页无库→顶上、导入后切回。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_list_page.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_sql_import_controller.dart';
import 'package:moyi/actress/actress_whos_topup.dart';
import 'package:moyi/actress/whos_json_index.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _catalogText = 'SSIS-001||第一部标题||https://img.test/1.jpg||https://v.test/1.m3u8\n'
    'ABC-002||第二部||https://img.test/2.jpg||https://v.test/2.m3u8\n'
    'BADLINE\n'
    'SSIS-003||第三部 SSIS 续||https://img.test/3.jpg||https://v.test/3.m3u8\n';

const _mapLines = [
  'SSIS-001||女优甲;男优丙',
  'ABC-002||女优乙',
  'SSIS-003||女优甲',
];

WhosJsonIndex _index() => WhosJsonIndex.fromLines(
  catalogLines: _catalogText.split('\n'),
  mapLines: _mapLines,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 16; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }
  });
}

void main() {
  group('WhosCatalogPager', () {
    test('分页解析：坏行跳过、字段齐全', () {
      final pager = WhosCatalogPager.fromText(_catalogText);
      expect(pager.total, 4);
      final page = pager.page(0, 10);
      expect(page.map((w) => w.code), ['SSIS-001', 'ABC-002', 'SSIS-003']);
      expect(page.first.title, '第一部标题');
      expect(page.first.m3u8, 'https://v.test/1.m3u8');
      expect(pager.page(3, 10).single.code, 'SSIS-003');
    });

    test('搜索：番号与标题都命中、不分大小写', () {
      final pager = WhosCatalogPager.fromText(_catalogText);
      expect(pager.search('ssis').map((w) => w.code),
          ['SSIS-001', 'SSIS-003']);
      expect(pager.search('第二部').single.code, 'ABC-002');
      expect(pager.search('不存在'), isEmpty);
    });
  });

  group('WhosJsonIndex.actorsByWorks', () {
    test('按作品数降序、素人不算、番号归拢', () {
      final index = _index();
      final actors = index.actorsByWorks();
      expect(actors.first.name, '女优甲');
      expect(actors.first.works, 2);
      expect(actors.map((a) => a.name), contains('女优乙'));
      expect(index.codesForActor('女优甲'), ['SSIS-001', 'SSIS-003']);
      expect(index.videoForCode('abc-002')?.m3u8, 'https://v.test/2.m3u8');
    });
  });

  group('ActressWhosTopupView', () {
    testWidgets('作品流出卡、点卡回调带直链；切女优页点人出她的作品', (
      tester,
    ) async {
      final played = <WhosVideo>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressWhosTopupView(
              onPlay: (video) async => played.add(video),
              onImport: () {},
              onManage: () {},
              pagerFuture: Future.value(
                WhosCatalogPager.fromText(_catalogText),
              ),
              indexFuture: Future.value(_index()),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('还没导入数据库，先用内置数据顶上（导入后自动换成数据库）'),
          findsOneWidget);
      expect(find.text('SSIS-001'), findsWidgets);
      await tester.tap(find.text('第一部标题'));
      await _settle(tester);
      expect(played.single.code, 'SSIS-001');
      expect(played.single.m3u8, 'https://v.test/1.m3u8');

      await tester.tap(find.text('按女优看'));
      await _settle(tester);
      expect(find.text('女优甲'), findsOneWidget);
      expect(find.text('约 2 部'), findsOneWidget);
      await tester.tap(find.text('女优甲'));
      await _settle(tester);
      expect(find.text('第三部 SSIS 续'), findsOneWidget);
      await tester.tap(find.text('第三部 SSIS 续'));
      await _settle(tester);
      expect(played.last.code, 'SSIS-003');
    });

    testWidgets('搜索提交后只剩命中行', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActressWhosTopupView(
              onPlay: (_) async {},
              onImport: () {},
              onManage: () {},
              pagerFuture: Future.value(
                WhosCatalogPager.fromText(_catalogText),
              ),
              indexFuture: Future.value(_index()),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '第二部');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      expect(find.text('ABC-002'), findsWidgets);
      expect(find.text('SSIS-001'), findsNothing);
    });
  });

  group('列表页顶上与切回', () {
    testWidgets('无库出顶上；导入代次涨后切回数据库人物', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final db = _FlipDb();
      await db.upsertRosterPerson(
        const RosterPerson(
          source: ActressRosterSourceId.chaoliu,
          sourceId: 'flip-1',
          name: '库里女优',
          sex: 'female',
        ),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: ActressListPage(
              repository: FixtureRepository(),
              store: store,
              database: db,
              topupPagerFuture: Future.value(
                WhosCatalogPager.fromText(_catalogText),
              ),
              topupIndexFuture: Future.value(_index()),
            ),
          ),
        );
      });
      await _settle(tester);
      // 无库：顶上作品流在，库里的人物不在。
      expect(find.text('SSIS-001'), findsWidgets);
      expect(find.text('库里女优'), findsNothing);
      // 模拟导入成功：库就绪 + 控制器代次涨 → 页面自动刷新切回。
      db.hasLibrary = true;
      ActressDbTaskController.instance.notifyDbMutated();
      await _settle(tester);
      expect(find.text('库里女优'), findsOneWidget);
      expect(find.text('SSIS-001'), findsNothing);
    });
  });
}

/// 可翻转的内存库：hasLibrary=false 时 reload 报“还没有导入数据库”
/// （与真库没建时的口径一致），true 时正常重读。
class _FlipDb extends MemoryActressDatabase {
  var hasLibrary = false;

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async {
    if (!hasLibrary) {
      return (
        reloaded: false,
        error: '还没有导入数据库：请在设置里导入 .sql 数据库',
      );
    }
    return (reloaded: true, error: null);
  }
}
