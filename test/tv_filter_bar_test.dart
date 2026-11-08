import 'package:moyi/models.dart';
import 'package:moyi/tv_filter_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const groups = [
    CatalogFilterGroup('theme', '主题', [
      CatalogFilterOption('cate_19', '系统'),
      CatalogFilterOption('cate_20', '悬疑'),
    ]),
    CatalogFilterGroup('sort', '排序', [CatalogFilterOption('hot_score', '热门')]),
  ];

  Future<void> pumpBar(
    WidgetTester tester, {
    void Function(String, String)? onSelected,
    VoidCallback? onExitUp,
    VoidCallback? onExitDown,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvFilterBar(
            groups: groups,
            selected: const {'theme': 'cate_19'},
            onSelected: onSelected ?? (_, _) {},
            onExitUp: onExitUp,
            onExitDown: onExitDown,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  FocusNode nodeOf(WidgetTester tester, String label) {
    final finder = find.ancestor(
      of: find.text(label),
      matching: find.byType(FocusableActionDetector),
    );
    return tester.widget<FocusableActionDetector>(finder.first).focusNode!;
  }

  testWidgets('tv filter bar renders groups and reports selection', (
    tester,
  ) async {
    var selected = ('', '');
    await pumpBar(
      tester,
      onSelected: (group, option) => selected = (group, option),
    );
    expect(find.text('主题'), findsOneWidget);
    expect(find.text('排序'), findsOneWidget);
    expect(find.text('全部'), findsNWidgets(2));
    expect(find.text('系统'), findsOneWidget);
    expect(find.text('悬疑'), findsOneWidget);
    expect(find.text('热门'), findsOneWidget);
    await tester.tap(find.text('悬疑'));
    expect(selected, ('theme', 'cate_20'));
  });

  testWidgets('tv filter bar moves focus right within a row', (tester) async {
    await pumpBar(tester);
    nodeOf(tester, '系统').requestFocus();
    await tester.pumpAndSettle();
    expect(nodeOf(tester, '系统').hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(nodeOf(tester, '悬疑').hasFocus, isTrue);
  });

  testWidgets('tv filter bar forwards edge exits', (tester) async {
    var up = false;
    var down = false;
    await pumpBar(
      tester,
      onExitUp: () => up = true,
      onExitDown: () => down = true,
    );
    nodeOf(tester, '系统').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(up, isTrue);
    nodeOf(tester, '热门').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(down, isTrue);
  });
}
