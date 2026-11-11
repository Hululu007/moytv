import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_home_page.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late HaikuoStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haikuo-page-');
    store = HaikuoStore(rootOverride: temp);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: HaikuoHomePage(store: store)));
    // 页面首帧是加载圈，这里让真实的文件 IO 跑完再逐帧推进。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('空库时给出三种导入入口，不报错', (tester) async {
    await pumpPage(tester);
    expect(find.text('还没有导入海阔小程序'), findsOneWidget);
    expect(find.text('导入 JSON 文件'), findsWidgets);
    expect(find.text('口令导入'), findsWidgets);
    expect(find.text('导入内置示例'), findsOneWidget);
  });

  testWidgets('已导入的小程序显示名称与类型', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '测试海阔源',
            'type': 'video',
            'url': 'hiker://empty##https://example.com',
            'col_type': 'movie_3',
            'find_rule': 'js:\nsetResult([{title:"x"}]);',
          },
        ]),
        origin: '测试',
      ),
    );
    await pumpPage(tester);
    expect(find.text('测试海阔源'), findsOneWidget);
    expect(find.textContaining('规则'), findsWidgets);
  });

  testWidgets('长按弹出详情，包含来源与脚本长度', (tester) async {
    await tester.runAsync(
      () => store.importText(
        jsonEncode([
          {
            'title': '详情源',
            'url': 'hiker://empty##https://example.com',
            'find_rule': 'js:\nsetResult([]);',
          },
        ]),
        origin: '口令',
      ),
    );
    await pumpPage(tester);
    await tester.longPress(find.text('详情源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('类型：规则'), findsOneWidget);
    expect(find.text('来源：口令'), findsOneWidget);
    expect(find.textContaining('脚本长度'), findsOneWidget);
  });
}
