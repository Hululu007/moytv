// 女优库海报透明播放键（2026-11-25）：
// ① 影视库详情页大海报中央有且仅有一个播放键，“正片”行照常在；
// ② 女优详情页作品卡：2026-11-26 用户发 AvPlay 截图改版式后，
//    详情页作品墙换成本模块的 AvWorkCard（照截图无中央播放键），
//    原“每张卡一个播放键”的断言随版式作废，改断言新卡型与个数。
// 只断言键/卡的存在与个数，不点播、不截图（截图见
// test/actress_poster_play_preview_test.dart）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_av_style.dart';
import 'package:moyi/actress/actress_database.dart';
import 'package:moyi/actress/actress_detail_page.dart';
import 'package:moyi/actress/actress_film_library.dart';
import 'package:moyi/actress/actress_models.dart';
import 'package:moyi/actress/actress_neon.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  testWidgets('影视库详情页大海报中央有透明播放键，正片行照常在', (tester) async {
    // ListView 的子项按需构建：默认 800x600 视口里“播放线路”行在
    // 折叠线下、根本不会建出来；用高视口一次全建出来再断言。
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = MemoryActressDatabase();
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    const entry = FilmLibraryEntry(
      vodId: 'SSIS-001',
      title: '测试作品标题',
      coverUrl: '',
      playUrl: 'https://example.com/video.m3u8',
      actress: '测试女优',
      code: 'SSIS-001',
      category: '日本AV',
      site: 'whos',
      date: '2024-01-01',
      remarks: '高清',
      content: '简介测试文本。',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FilmDetailPage(
          entry: entry,
          database: db,
          repository: FixtureRepository(),
          store: store,
          service: FilmLibraryService(database: db),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ActressPosterPlayKey), findsOneWidget);
    expect(find.text('正片'), findsOneWidget);
    expect(find.text('播放线路'), findsOneWidget);
  });

  testWidgets('女优详情页作品墙是 AvPlay 式卡片、无中央播放键', (tester) async {
    final db = MemoryActressDatabase();
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final person = (await db.upsertRosterPerson(
      const RosterPerson(
        source: ActressRosterSourceId.missav,
        sourceId: '/dm16/cn/actresses/x',
        name: '测试女优',
        sex: 'female',
      ),
    ))!;
    await db.upsertWorks(person.localId, const [
      RosterFilm(code: 'SSIS-00123', date: '2024-01-01'),
      RosterFilm(code: 'HMN-927'),
      RosterFilm(code: '', title: '无番号作品标题'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ActressDetailPage(
          localId: person.localId,
          repository: FixtureRepository(),
          store: store,
          database: db,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AvWorkCard), findsNWidgets(3));
    expect(find.byType(ActressPosterPlayKey), findsNothing);
  });
}
