import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/category_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const items = [
    CategorySidebarItem(id: '', name: '热门'),
    CategorySidebarItem(id: 'movie', name: '电影'),
    CategorySidebarItem(id: 'drama', name: '电视剧'),
  ];

  Future<void> pumpSidebar(
    WidgetTester tester, {
    required AppThemeMode mode,
    List<CategorySidebarItem> sidebarItems = items,
    String selectedId = '',
    ValueChanged<String>? onSelect,
    double width = 390,
    bool settle = true,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(mode).toThemeData(),
        home: Scaffold(
          body: CategorySidebar(
            config: AppThemeConfig.forTheme(mode),
            items: sidebarItems,
            selectedId: selectedId,
            onSelect: onSelect ?? (_) {},
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('紫蓝霓虹用简约暗黑侧边栏，点分类回调 id', (tester) async {
    String? selected;
    await pumpSidebar(
      tester,
      mode: AppThemeMode.purpleNeon,
      onSelect: (id) => selected = id,
    );
    expect(find.text('影库'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('category-sidebar-item-movie')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('category-sidebar-item-movie')),
    );
    expect(selected, 'movie');
  });

  testWidgets('浅色清爽用浅色侧边栏（无影库标题）', (tester) async {
    await pumpSidebar(tester, mode: AppThemeMode.lightClean);
    expect(find.text('影库'), findsNothing);
    expect(
      find.byKey(const ValueKey('category-sidebar-item-drama')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.video_library), findsOneWidget);
  });

  testWidgets('空分类显示加载中，不崩', (tester) async {
    await pumpSidebar(
      tester,
      mode: AppThemeMode.purpleNeon,
      sidebarItems: const [],
      // 转圈动画永不收敛，pumpAndSettle 会超时。
      settle: false,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(CategorySidebar), findsOneWidget);
  });

  testWidgets('复古胶片折叠样式：有真实筛选才画筛选区', (tester) async {
    const withFilters = [
      CategorySidebarItem(id: '', name: '热门'),
      CategorySidebarItem(
        id: 'movie',
        name: '电影',
        filters: [
          CategorySidebarFilter(name: '2024', value: '2024'),
          CategorySidebarFilter(name: '动作', value: 'action'),
        ],
      ),
    ];
    await pumpSidebar(
      tester,
      mode: AppThemeMode.retroFilm,
      sidebarItems: withFilters,
      selectedId: 'movie',
    );
    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('2024'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
  });

  testWidgets('复古胶片折叠样式：没有筛选数据就不画筛选区', (tester) async {
    await pumpSidebar(
      tester,
      mode: AppThemeMode.retroFilm,
      selectedId: 'movie',
    );
    expect(find.text('筛选'), findsNothing);
    expect(
      find.byKey(const ValueKey('category-sidebar-item-movie')),
      findsOneWidget,
    );
  });

  testWidgets('窄屏上侧边栏宽度收敛到屏宽 36%', (tester) async {
    await pumpSidebar(tester, mode: AppThemeMode.purpleNeon, width: 300);
    final size = tester.getSize(
      find.byKey(const ValueKey('category-sidebar-list')),
    );
    // 演示宽 110，屏宽 300 的 36% 是 108，取小者。
    expect(size.width, closeTo(108, 1));
  });

  testWidgets('宽屏上用演示宽度', (tester) async {
    await pumpSidebar(tester, mode: AppThemeMode.purpleNeon, width: 800);
    final size = tester.getSize(
      find.byKey(const ValueKey('category-sidebar-list')),
    );
    expect(size.width, closeTo(110, 1));
  });

  test('8 种样式演示宽度在 72–140 之间', () {
    for (final style in CategoryNavStyle.values) {
      final width = CategorySidebar.demoWidthFor(style);
      expect(width, greaterThanOrEqualTo(72));
      expect(width, lessThanOrEqualTo(140));
    }
    expect(
      CategorySidebar.demoWidthFor(CategoryNavStyle.miniIconSidebar),
      72,
    );
    expect(
      CategorySidebar.demoWidthFor(CategoryNavStyle.foldFilterSidebar),
      140,
    );
  });
}
