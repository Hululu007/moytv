import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/models.dart';
import 'package:moyi/neon/neon_channel_view.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpChannel(
    WidgetTester tester, {
    VoidCallback? onSwitchSource,
    String? sourceLabel,
    required VoidCallback onFilter,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NeonChannelView(
            items: const [],
            repository: FixtureRepository(),
            categories: const [CatalogCategory('c1', '冒险')],
            selectedCategory: '',
            onCategory: (_) {},
            onOpen: (_) {},
            onBack: () {},
            onSearch: () {},
            onFilter: onFilter,
            onRankings: () {},
            onSwitchSource: onSwitchSource,
            sourceLabel: sourceLabel,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('第一个胶囊显示当前站名，点按打开站点切换', (tester) async {
    var switched = 0;
    var filtered = 0;
    await pumpChannel(
      tester,
      onSwitchSource: () => switched++,
      sourceLabel: '黄豆短剧',
      onFilter: () => filtered++,
    );
    expect(find.text('黄豆短剧'), findsOneWidget);
    expect(find.text('全部类型'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('neon-filter-all')));
    expect(switched, 1);
    expect(filtered, 0);
  });

  testWidgets('排序胶囊仍走筛选，不触发站点切换', (tester) async {
    var switched = 0;
    var filtered = 0;
    await pumpChannel(
      tester,
      onSwitchSource: () => switched++,
      sourceLabel: '黄豆短剧',
      onFilter: () => filtered++,
    );
    // 侧栏首项也叫“热门”，排序胶囊是树里的第一个“热门”。
    await tester.tap(find.text('热门').first);
    await tester.tap(find.text('最新'));
    await tester.tap(find.text('完结'));
    expect(filtered, 3);
    expect(switched, 0);
  });

  testWidgets('未接站点切换时第一个胶囊回落旧行为', (tester) async {
    var filtered = 0;
    await pumpChannel(tester, onFilter: () => filtered++);
    expect(find.text('全部类型'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('neon-filter-all')));
    expect(filtered, 1);
  });
}
