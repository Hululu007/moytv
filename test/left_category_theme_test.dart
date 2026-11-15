import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/flip_card_stack.dart';
import 'package:moyi/left_category_layout.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/main.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 第 9 套主题“左侧分类”测试：三层结构、空数据隐藏、卡堆手势、
///
/// 切主题布局跟变、12 套固定映射。只写代码不运行，由父代理统一验证。

class _LeftCategoryRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory.all,
    CatalogCategory('ai-duanju', 'AI 短剧'),
    CatalogCategory('ai-manju', 'AI 漫剧'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async => CatalogPage([
    Drama(
      id: '$source:1',
      source: source,
      title: '有封面的剧甲',
      cover: 'https://x.test/a.jpg',
      episodes: 12,
    ),
    Drama(
      id: '$source:2',
      source: source,
      title: '有封面的剧乙',
      cover: 'https://x.test/b.jpg',
      episodes: 8,
    ),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const categories = [
    CatalogCategory.all,
    CatalogCategory('real', '真人剧'),
    CatalogCategory('comic', '漫剧'),
  ];
  const subCategories = [
    CatalogCategory('comedy', '喜剧'),
    CatalogCategory('fantasy', '玄幻'),
  ];
  const filterGroups = [
    CatalogFilterGroup('type', '类型', [
      CatalogFilterOption('action', '动作'),
      CatalogFilterOption('love', '爱情'),
    ]),
    CatalogFilterGroup('area', '地区', [
      CatalogFilterOption('cn', '大陆'),
    ]),
  ];

  Future<void> mountLayout(
    WidgetTester tester, {
    List<CatalogCategory> subs = subCategories,
    List<CatalogFilterGroup> filters = filterGroups,
    List<Drama> stack = const [],
    ValueChanged<String>? onCategory,
    void Function(String, String)? onFilter,
    void Function(Drama)? onOpen,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemeConfig.forTheme(
          AppThemeMode.leftCategories,
        ).toThemeData(),
        home: Scaffold(
          body: LeftCategoryLayout(
            categories: categories,
            selectedCategory: '',
            onCategory: onCategory ?? (_) {},
            subCategories: subs,
            filterGroups: filters,
            selectedFilters: const {'type': ''},
            onFilter: onFilter,
            stackItems: stack,
            repository: FixtureRepository(),
            onOpen: onOpen,
            body: const Center(child: Text('网格')),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('有二级与筛选的站：左栏+二级行+筛选行三层齐全', (tester) async {
    final pickedCategories = <String>[];
    final pickedFilters = <String>[];
    await mountLayout(
      tester,
      onCategory: pickedCategories.add,
      onFilter: (group, option) => pickedFilters.add('$group:$option'),
    );
    expect(find.byKey(const ValueKey('left-category-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('left-category-rail')), findsOneWidget);
    expect(find.text('真人剧'), findsWidgets);
    expect(
      find.byKey(const ValueKey('left-category-sublevel')),
      findsOneWidget,
    );
    expect(find.text('喜剧'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    // 筛选行只显示站点真实有的维度与选项。
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('地区'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('爱情'), findsOneWidget);
    expect(find.text('大陆'), findsOneWidget);
    expect(find.text('网格'), findsOneWidget);

    // 二级点选与筛选点选走回调，不编假选项。
    await tester.tap(find.byKey(const ValueKey('left-category-sub-comedy')));
    expect(pickedCategories, ['comedy']);
    await tester.tap(find.text('动作'));
    expect(pickedFilters, ['type:action']);
  });

  testWidgets('无筛选的站：只显示一级，二级行与筛选行不存在', (tester) async {
    await mountLayout(tester, subs: const [], filters: const []);
    expect(find.byKey(const ValueKey('left-category-rail')), findsOneWidget);
    expect(find.text('真人剧'), findsWidgets);
    expect(
      find.byKey(const ValueKey('left-category-sublevel')),
      findsNothing,
    );
    expect(find.text('喜剧'), findsNothing);
    expect(find.text('类型'), findsNothing);
    expect(find.text('动作'), findsNothing);
    // 卡堆无数据时整区隐藏，不留空壳。
    expect(find.byKey(const ValueKey('flip-card-stack')), findsNothing);
    expect(find.text('网格'), findsOneWidget);
  });

  testWidgets('卡堆无数据时不存在，有数据时点卡进详情不播', (tester) async {
    final opened = <Drama>[];
    await mountLayout(
      tester,
      subs: const [],
      filters: const [],
      stack: [
        const Drama(
          id: 's1:1',
          source: 's1',
          title: '卡堆剧甲',
          cover: 'https://x.test/a.jpg',
          episodes: 12,
        ),
        const Drama(
          id: 's1:2',
          source: 's1',
          title: '卡堆剧乙',
          cover: 'https://x.test/b.jpg',
          episodes: 8,
        ),
      ],
      onOpen: opened.add,
    );
    expect(find.byKey(const ValueKey('flip-card-stack')), findsOneWidget);
    expect(find.text('卡堆剧甲'), findsWidgets);
    // 卡上绝无播放按钮文案。
    expect(find.text('马上看'), findsNothing);
    expect(find.text('立即播放'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('flip-card-top')));
    await tester.pump();
    expect(opened.map((d) => d.id).toList(), ['s1:1']);
  });

  testWidgets('卡堆拖动翻页后顶卡变化', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlipCardStack(
            items: const [
              Drama(
                id: 's1:1',
                source: 's1',
                title: '翻页剧甲',
                cover: 'https://x.test/a.jpg',
              ),
              Drama(
                id: 's1:2',
                source: 's1',
                title: '翻页剧乙',
                cover: 'https://x.test/b.jpg',
              ),
              Drama(
                id: 's1:3',
                source: 's1',
                title: '翻页剧丙',
                cover: 'https://x.test/c.jpg',
              ),
            ],
            repository: FixtureRepository(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    final top = find.byKey(const ValueKey('flip-card-top'));
    expect(
      find.descendant(of: top, matching: find.text('翻页剧甲')),
      findsOneWidget,
    );
    await tester.drag(top, const Offset(-200, 0));
    await tester.pump();
    expect(
      find.descendant(of: top, matching: find.text('翻页剧乙')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: top, matching: find.text('翻页剧甲')),
      findsNothing,
    );
    // 反向拖回上一张。
    await tester.drag(top, const Offset(200, 0));
    await tester.pump();
    expect(
      find.descendant(of: top, matching: find.text('翻页剧甲')),
      findsOneWidget,
    );
  });

  testWidgets('卡堆空数据时自身回空盒', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FlipCardStack(
            items: const [],
            repository: FixtureRepository(),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('flip-card-top')), findsNothing);
  });

  testWidgets('切主题布局跟变：新主题左栏出现、切回消失', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      // 不设 hiddenSites 时新用户默认隐藏集会把待测站源藏掉，
      // source 回落到红果、走戏剧首页分支，左栏永不出现。
      'hiddenSites': '[]',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // setSource 要求站源在 allowsSource 内：先把源登记进导入表。
    SourceSite.importedSites['huangguoai'] = SourceSite(
      'huangguoai',
      '黄果短剧',
      '',
      section: SourceSite.sectionVideo,
      origin: SourceSite.originBuiltin,
    );
    addTearDown(() => SourceSite.importedSites.remove('huangguoai'));
    await store.setSource('huangguoai');
    await tester.pumpWidget(
      MoyiApp(repository: _LeftCategoryRepository(), store: store),
    );
    await tester.pumpAndSettle();
    // 默认主题下无左栏。
    expect(find.byKey(const ValueKey('left-category-rail')), findsNothing);

    await store.setAppTheme(AppThemeMode.leftCategories);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('left-category-rail')), findsOneWidget);
    expect(find.byKey(const ValueKey('left-category-layout')), findsOneWidget);

    await store.setAppTheme(AppThemeMode.purpleNeon);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('left-category-rail')), findsNothing);
    expect(find.byKey(const ValueKey('left-category-layout')), findsNothing);
    // 收尾：HomeScreen 的站源轮询定时器须手动卸树 + 排干，否则
    // 测试结束时框架会报“Timer 仍在等待”。
    await tester.pumpWidget(Container());
    await tester.pump(const Duration(seconds: 3));
  });

  test('12 套主题导航与列表样式固定映射', () {
    expect(AppThemeMode.values.length, 12);
    for (final mode in AppThemeMode.values) {
      expect(
        navStyleForTheme(mode),
        mode == AppThemeMode.purpleNeon
            ? NavStyle.bottomTabs
            : NavStyle.drawer,
        reason: '$mode 导航',
      );
      expect(
        siteListStyleForTheme(mode),
        mode == AppThemeMode.purpleNeon
            ? SiteListStyle.cube
            : SiteListStyle.normal,
        reason: '$mode 列表样式',
      );
    }
    expect(navStyleForTheme(AppThemeMode.leftCategories), NavStyle.drawer);
    expect(
      siteListStyleForTheme(AppThemeMode.leftCategories),
      SiteListStyle.normal,
    );
  });
}
