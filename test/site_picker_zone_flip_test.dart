// 站点列表 3D 翻页双区测试：内置区 / 导入区。
//
// 只测弹窗本身：区签、翻页切换、+ 号固定、导入区空态、
// 不开翻页时保持单列表（直播/阅读弹窗不受影响）。
import 'package:moyi/source_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _groups = [
  SourcePickerGroup(
    title: '内置短剧',
    entries: [
      SourcePickerEntry(id: 'all', name: '全部站源', deletable: false),
      SourcePickerEntry(id: 'a', name: 'A站'),
    ],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '内置影视',
    entries: [SourcePickerEntry(id: 'b', name: 'B站')],
    zone: SourcePickerGroup.zoneBuiltin,
  ),
  SourcePickerGroup(
    title: '导入',
    entries: [
      SourcePickerEntry(id: 'c', name: 'C站'),
      SourcePickerEntry(id: 'd', name: 'D站'),
    ],
    zone: SourcePickerGroup.zoneImport,
  ),
  SourcePickerGroup(
    title: '导入配置',
    entries: [SourcePickerEntry(id: 'e', name: 'E配置站')],
    zone: SourcePickerGroup.zoneImport,
  ),
];

Widget _host({
  required void Function(String?) onResult,
  bool enableZoneFlip = true,
  int initialZoneIndex = 0,
  Future<void> Function()? onImport,
  List<SourcePickerGroup> groups = _groups,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () async {
            final picked = await showSitePickerDialog(
              context,
              sectionName: '片库',
              currentId: 'a',
              groups: groups,
              onImport: onImport,
              enableZoneFlip: enableZoneFlip,
              initialZoneIndex: initialZoneIndex,
            );
            onResult(picked);
          },
          child: const Text('打开'),
        ),
      ),
    ),
  ),
);

Future<void> _open(
  WidgetTester tester, {
  bool enableZoneFlip = true,
  int initialZoneIndex = 0,
  Future<void> Function()? onImport,
  List<SourcePickerGroup> groups = _groups,
}) async {
  await tester.pumpWidget(
    _host(
      onResult: (_) {},
      enableZoneFlip: enableZoneFlip,
      initialZoneIndex: initialZoneIndex,
      // + 号只在传了 onImport 时渲染：翻页测试默认都要它在场。
      onImport: onImport ?? () async {},
      groups: groups,
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return;
}

void main() {
  testWidgets('区签显示两区带站数，默认内置区只见内置站', (tester) async {
    await _open(tester);

    expect(find.text('内置区（3）'), findsOneWidget);
    expect(find.text('导入区（3）'), findsOneWidget);
    expect(find.text('A站'), findsOneWidget);
    expect(find.text('B站'), findsOneWidget);
    expect(find.text('C站'), findsNothing);
    expect(find.text('E配置站'), findsNothing);
    expect(find.byKey(const ValueKey('site-picker-add')), findsOneWidget);
  });

  testWidgets('点导入区签翻页：只见导入站，+ 号还在', (tester) async {
    await _open(tester, onImport: () async {});

    await tester.tap(find.byKey(const ValueKey('site-picker-zone-import')));
    await tester.pumpAndSettle();
    expect(find.text('C站'), findsOneWidget);
    expect(find.text('D站'), findsOneWidget);
    expect(find.text('E配置站'), findsOneWidget);
    expect(find.text('A站'), findsNothing);
    expect(find.text('B站'), findsNothing);
    // + 号固定在顶栏：翻页前后都在，不消失。
    expect(find.byKey(const ValueKey('site-picker-add')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('site-picker-zone-builtin')));
    await tester.pumpAndSettle();
    expect(find.text('A站'), findsOneWidget);
    expect(find.text('C站'), findsNothing);
    expect(find.byKey(const ValueKey('site-picker-add')), findsOneWidget);
  });

  testWidgets('左滑进导入区、右滑回内置区', (tester) async {
    await _open(tester);

    // 横滑用 fling（带真实时间戳与速度）：tester.drag 发出的移动
    // 共用一个时间戳，算出的末速度是 0，过不了 80 的速度门——
    // 真手指滑是有速度的，fling 才是 faithful 的复现。
    await tester.fling(
      find.byKey(const ValueKey('site-picker-zone-0')),
      const Offset(-300, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('site-picker-row-c')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsNothing);

    await tester.fling(
      find.byKey(const ValueKey('site-picker-zone-1')),
      const Offset(300, 0),
      800,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('site-picker-row-a')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('site-picker-row-c')), findsNothing);
  });

  testWidgets('initialZoneIndex=1 打开即在导入区（导入后自动落区）', (
    tester,
  ) async {
    await _open(tester, initialZoneIndex: 1);

    expect(find.text('C站'), findsOneWidget);
    expect(find.text('A站'), findsNothing);
    expect(find.byKey(const ValueKey('site-picker-add')), findsOneWidget);
  });

  testWidgets('导入区空时给去处提示，不留白屏', (tester) async {
    const builtinOnly = [
      SourcePickerGroup(
        title: '内置短剧',
        entries: [SourcePickerEntry(id: 'a', name: 'A站')],
        zone: SourcePickerGroup.zoneBuiltin,
      ),
    ];
    await _open(tester, onImport: () async {}, groups: builtinOnly);

    expect(find.text('内置区（1）'), findsOneWidget);
    expect(find.text('导入区（0）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('site-picker-zone-import')));
    await tester.pumpAndSettle();
    expect(find.text('导入区还没有站，点右上角 + 导入一个'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-add')), findsOneWidget);
  });

  testWidgets('不开翻页时没有区签，单列表全显示（直播/阅读弹窗）', (
    tester,
  ) async {
    await _open(tester, enableZoneFlip: false);

    expect(find.text('内置区（3）'), findsNothing);
    expect(find.text('导入区（3）'), findsNothing);
    expect(find.text('A站'), findsOneWidget);
    // 宫格是懒加载的 GridView.builder：C站 在折叠线下，竖滑滚到它再断言。
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('C站'), findsOneWidget);
  });

  testWidgets('搜索只在活动区内过滤，切区后查询保留', (tester) async {
    await _open(tester);

    await tester.enterText(
      find.byKey(const ValueKey('site-picker-search')),
      'C站',
    );
    await tester.pumpAndSettle();
    // 内置区里没有 C站。
    expect(find.text('没有匹配的站点'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('site-picker-zone-import')));
    await tester.pumpAndSettle();
    // 行 key 断言：搜索框里也写着“C站”，find.text 会命中两个。
    expect(
      find.byKey(const ValueKey('site-picker-row-c')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('site-picker-row-d')), findsNothing);
  });

  testWidgets('导入区点选照常返回站 id', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _host(
        onResult: (value) => picked = value,
        initialZoneIndex: 1,
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('site-picker-row-c')));
    await tester.pumpAndSettle();
    expect(picked, 'c');
  });
}
