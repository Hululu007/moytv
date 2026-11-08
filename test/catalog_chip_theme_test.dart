import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/catalog_filters.dart';
import 'package:moyi/compact_chip.dart';
import 'package:moyi/models.dart';

void main() {
  const container = Color(0xFF123456);
  const selected = Color(0xFFC8E6C9);
  ThemeData theme() => ThemeData(
    colorScheme: const ColorScheme.light(surfaceContainerHighest: container),
  );

  Color chipColor(WidgetTester tester, String label) {
    final chip = find.widgetWithText(CompactFilterChip, label);
    final box = find.descendant(
      of: chip,
      matching: find.byType(Container),
    );
    final decoration =
        tester.widget<Container>(box).decoration as BoxDecoration?;
    return decoration?.color ?? Colors.transparent;
  }

  TextStyle labelStyle(WidgetTester tester, String label) {
    final text = find.descendant(
      of: find.widgetWithText(CompactFilterChip, label),
      matching: find.byType(Text),
    );
    return tester.widget<Text>(text).style!;
  }

  testWidgets('catalog chips use theme container color, not white', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: CatalogFilterRows(
            groups: const [
              CatalogFilterGroup('tag', '标签', [
                CatalogFilterOption('daily', '日常'),
              ]),
            ],
            selected: const {'tag': ''},
            onSelected: (_, _) {},
          ),
        ),
      ),
    );
    final all = tester.widget<CompactFilterChip>(
      find.widgetWithText(CompactFilterChip, '全部'),
    );
    final daily = tester.widget<CompactFilterChip>(
      find.widgetWithText(CompactFilterChip, '日常'),
    );
    expect(all.selected, isTrue);
    expect(chipColor(tester, '全部'), selected);
    expect(chipColor(tester, '全部'), isNot(Colors.white));
    expect(labelStyle(tester, '全部').color, theme().colorScheme.onSurface);
    expect(labelStyle(tester, '全部').color, isNot(Colors.white));
    expect(daily.selected, isFalse);
    expect(chipColor(tester, '日常'), container);
    expect(chipColor(tester, '日常'), isNot(Colors.white));
    expect(chipColor(tester, '日常'), isNot(selected));
    expect(labelStyle(tester, '日常').fontSize, 8);
  });

  testWidgets('category chips use theme container color, not white', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: CatalogFilters(
            categories: const [
              CatalogCategory('', '全部'),
              CatalogCategory('real', '真人剧'),
            ],
            category: '',
            onCategory: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    final other = tester.widget<CompactFilterChip>(
      find.widgetWithText(CompactFilterChip, '真人剧'),
    );
    expect(other.selected, isFalse);
    expect(chipColor(tester, '真人剧'), container);
    expect(chipColor(tester, '真人剧'), isNot(Colors.white));
    expect(chipColor(tester, '全部'), selected);
    expect(chipColor(tester, '全部'), isNot(chipColor(tester, '真人剧')));
    expect(labelStyle(tester, '真人剧').fontSize, 8);
  });
}
