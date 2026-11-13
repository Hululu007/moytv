import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/web_scrape_page.dart';

void main() {
  testWidgets('网页爬取页：初始渲染与空网址报错', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WebScrapePage()));
    expect(find.text('网页爬取'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('web-scrape-url-input')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('web-scrape-run')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('web-scrape-run')));
    await tester.pumpAndSettle();
    expect(find.text('请输入网址。'), findsOneWidget);
  });
}
