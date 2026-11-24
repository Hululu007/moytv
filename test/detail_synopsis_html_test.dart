import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

// 用户 2026-11-23 截图：FNS-164 详情页简介原样露出 <p> 标签。
// 站点简介（女优库 vod_content）常带 HTML，详情页必须先去标签再显示。
const _htmlDescription =
    '<p>fns-164-uncensored-leak</p><p>FNS-164 兄と弟と巨乳の幼なじみ 三角関係をまるく収めるために3人でハメまくった4日間ルームシェアSEX つばさ舞</p>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpDetail(WidgetTester tester, Drama drama) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: DetailScreen(
          drama: drama,
          repository: FixtureRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: ScriptedPlayer()),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> dragToVisible(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 15 && target.evaluate().isEmpty; i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('简介里的 HTML 标签不显示，只显示干净文本', (tester) async {
    const drama = Drama(
      id: 'hongguo:fns-164',
      source: 'hongguo',
      title: 'FNS-164 兄と弟と巨乳の幼なじみ',
      description: _htmlDescription,
      episodes: 1,
    );
    await pumpDetail(tester, drama);
    await dragToVisible(tester, find.text('简介'));
    expect(find.text('简介'), findsOneWidget);
    // 标签本身绝不能出现在屏幕上。
    expect(find.textContaining('<p>'), findsNothing);
    expect(find.textContaining('</p>'), findsNothing);
    // 干净文本在：第一段是 slug 行，第二段是标题行（用简介独有的句子断言，
    // 标题本身也含 FNS-164，findsOneWidget 会误撞标题）。
    expect(find.textContaining('fns-164-uncensored-leak'), findsOneWidget);
    expect(find.textContaining('三角関係をまるく収めるために'), findsOneWidget);
  });

  testWidgets('纯文本简介不受影响', (tester) async {
    const drama = Drama(
      id: 'hongguo:plain',
      source: 'hongguo',
      title: '纯文本片',
      description: '这是一段没有标签的简介。',
      episodes: 1,
    );
    await pumpDetail(tester, drama);
    await dragToVisible(tester, find.text('简介'));
    expect(find.textContaining('这是一段没有标签的简介。'), findsOneWidget);
  });
}
