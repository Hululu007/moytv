import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('小说区显示导入入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ContentRegistry.setNovelImports([]);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ContentZoneScreen(section: ContentSection.novel)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('novel-import-py')), findsOneWidget);
  });
}
