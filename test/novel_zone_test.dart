import 'package:moyi/content_models.dart';
import 'package:moyi/content_registry.dart';
import 'package:moyi/content_zone_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('小说区默认有源，不再空白', (tester) async {
    SharedPreferences.setMockInitialValues({});
    ContentRegistry.setNovelImports([]);
    addTearDown(() {
      ContentRegistry.setNovelImports([]);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ContentZoneScreen(section: ContentSection.novel)),
      ),
    );
    // 不用 pumpAndSettle：分类加载要走 py 桥（测试环境无原生平台，
    // categories() 挂起不返回），转圈指示器会一直转，settle 永远等不到。
    // 本测试只验“区里有源、不空白”，分类加载本身留待真机验。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find
          .byKey(const ValueKey('content-source-switch'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(find.text('小说暂无可用源'), findsNothing);
    expect(find.byKey(const ValueKey('content-source-switch')), findsOneWidget);
    expect(find.text('🔞疯情书库'), findsOneWidget);
    expect(find.byKey(const ValueKey('novel-import-py')), findsOneWidget);
  });
}
