import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_build.dart';
import 'package:moyi/home_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/web_scrape_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '首页顶栏常显网页爬取入口：默认不展开搜索也能看见、点开',
    (tester) async {
      // hiddenSites 空列表 = 用户配置过全部可见，否则默认隐藏集会藏起 huangdou，
      // 默认源落回 hongguo，首页走红果沉浸流分支，没有目录顶栏。
      SharedPreferences.setMockInitialValues({
        'source': 'huangdou',
        'hiddenSites': '[]',
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(repository: FixtureRepository(), store: store),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // 搜索行默认折叠：全局搜索按钮（只在搜索行里）不存在。
      expect(find.byKey(const ValueKey('global-search')), findsNothing);
      // 地球入口在顶栏常显，且只有一个。
      final globe = find.byKey(const ValueKey('web-scrape'));
      expect(globe, findsOneWidget);
      await tester.tap(globe);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(WebScrapePage), findsOneWidget);
    },
    // 单源构建的首页是红果沉浸流（无顶栏）；全量构建才有目录顶栏。
    skip: !allSourcesEnabled,
  );
}
