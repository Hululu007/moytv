import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_runner_page.dart';

void main() {
  testWidgets('搜索栏显示预填关键词，点搜索提交', (tester) async {
    var submitted = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaikuoSearchBar(
            initialKeyword: '仙逆',
            onSubmitted: (word) => submitted = word,
            onClosed: () {},
          ),
        ),
      ),
    );
    expect(find.text('仙逆'), findsOneWidget);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    expect(submitted, '仙逆');
  });

  testWidgets('输入后回车提交，提交时去掉两端空格', (tester) async {
    var submitted = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaikuoSearchBar(
            onSubmitted: (word) => submitted = word,
            onClosed: () {},
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '  凡人  ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submitted, '凡人');
  });

  testWidgets('空关键词不提交', (tester) async {
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaikuoSearchBar(
            onSubmitted: (_) => called = true,
            onClosed: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('搜索'));
    await tester.pump();
    expect(called, isFalse);
  });

  testWidgets('清除按钮清空输入，关闭按钮回调', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HaikuoSearchBar(
            initialKeyword: '仙逆',
            onSubmitted: (_) {},
            onClosed: () => closed = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('清除'));
    await tester.pump();
    expect(find.text('仙逆'), findsNothing);
    await tester.tap(find.byTooltip('关闭搜索栏'));
    await tester.pump();
    expect(closed, isTrue);
  });
}
