import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
  }


  testWidgets('iOS, Android and Windows share the glass app shell', (
    tester,
  ) async {
    phone(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MoyiApp(repository: FixtureRepository(), store: store),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toggle-search')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;

    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      debugDefaultTargetPlatformOverride = platform;
      if (platform == TargetPlatform.windows) {
        tester.view.physicalSize = const Size(1200, 850);
      }
      await tester.pumpWidget(
        MoyiApp(repository: FixtureRepository(), store: store),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(NavigationRail),
        platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('外观主题'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugDefaultTargetPlatformOverride = null;
    store.dispose();
  });
}
