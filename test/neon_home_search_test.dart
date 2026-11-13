import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> pumpHome(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: store),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    return store;
  }

  testWidgets('首页放大镜打开全局搜索，返回回首页', (tester) async {
    final store = await pumpHome(tester);
    expect(
      find.byKey(const ValueKey('neon-top-search')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('neon-top-search')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('全局搜索'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('neon-top-search')),
      findsOneWidget,
    );
    store.dispose();
  });

  testWidgets('频道页放大镜同样打开全局搜索', (tester) async {
    final store = await pumpHome(tester);
    await tester.tap(find.text('频道'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('neon-channel-search')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('neon-channel-search')));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('全局搜索'), findsOneWidget);
    store.dispose();
  });
}
