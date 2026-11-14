import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/catalog_filters.dart';
import 'package:moyi/category_levels.dart';
import 'package:moyi/models.dart';

void main() {
  group('splitCategoryLevels', () {
    const mixed = [
      CatalogCategory('', '全部'),
      CatalogCategory('novel', '小说'),
      CatalogCategory('audio', '听书'),
      CatalogCategory('local:冒险', '冒险', local: true),
      CatalogCategory('local:剧情', '剧情', local: true),
    ];

    test('站方分类进一级，本地筛分类进二级，顺序不变', () {
      final levels = splitCategoryLevels(mixed);
      expect(
        levels.level1.map((entry) => entry.name),
        ['全部', '小说', '听书'],
      );
      expect(levels.level2.map((entry) => entry.name), ['冒险', '剧情']);
    });

    test('没有二级时不分排', () {
      final levels = splitCategoryLevels(mixed.take(3).toList());
      expect(levels.level1.length, 3);
      expect(levels.level2, isEmpty);
    });

    test('全是本地分类时回落单排', () {
      final levels = splitCategoryLevels(mixed.skip(3).toList());
      expect(levels.level1.length, 2);
      expect(levels.level2, isEmpty);
    });

    test('文件夹分类留在第一级', () {
      const folders = [
        CatalogCategory('f1', '合集', kind: 'folder', folderId: 'f1'),
        CatalogCategory('local:冒险', '冒险', local: true),
      ];
      final levels = splitCategoryLevels(folders);
      expect(levels.level1.map((entry) => entry.name), ['合集']);
      expect(levels.level2.map((entry) => entry.name), ['冒险']);
    });
  });

  testWidgets('CatalogFilters 一级与二级分两排，点二级回传原 id', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogFilters(
            categories: const [
              CatalogCategory('', '全部'),
              CatalogCategory('novel', '小说'),
              CatalogCategory('local:冒险', '冒险', local: true),
              CatalogCategory('local:剧情', '剧情', local: true),
            ],
            category: '',
            onCategory: (id) => picked = id,
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final level1Top = tester.getTopLeft(find.text('小说')).dy;
    final level2Top = tester.getTopLeft(find.text('冒险')).dy;
    expect(level2Top, greaterThan(level1Top));
    await tester.tap(find.text('冒险'));
    expect(picked, 'local:冒险');
  });

  testWidgets('CatalogFilters 没有二级时保持单排', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogFilters(
            categories: const [
              CatalogCategory('', '全部'),
              CatalogCategory('novel', '小说'),
            ],
            category: '',
            onCategory: (_) {},
            onRetry: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('小说')).dy,
      tester.getTopLeft(find.text('全部')).dy,
    );
  });
}
