import 'package:moyi/source_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _groups = [
  SourcePickerGroup(
    title: '内置短剧',
    entries: [
      SourcePickerEntry(id: 'all', name: '全部站源', deletable: false),
      SourcePickerEntry(id: 'a', name: 'A站'),
      SourcePickerEntry(id: 'b', name: 'B站'),
    ],
  ),
  SourcePickerGroup(
    title: '导入',
    entries: [SourcePickerEntry(id: 'c', name: 'C站')],
  ),
];

Widget _host({
  required void Function(String?) onResult,
  bool editMode = false,
  Future<bool> Function(SourcePickerEntry entry)? onDelete,
  Future<void> Function()? onImport,
}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () async {
            final picked = await showSitePickerDialog(
              context,
              sectionName: '短剧',
              currentId: 'b',
              groups: _groups,
              initialEditMode: editMode,
              onDeleteSite: onDelete,
              onImport: onImport,
            );
            onResult(picked);
          },
          child: const Text('打开'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(_host(onResult: (_) {}));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('列表行展示当前站打勾，点选返回站 id', (tester) async {
    String? picked;
    await tester.pumpWidget(_host(onResult: (value) => picked = value));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('切换短剧源'), findsOneWidget);
    expect(find.text('A站'), findsOneWidget);
    expect(find.text('B站'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-delete-a')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('site-picker-row-a')));
    await tester.pumpAndSettle();
    expect(picked, 'a');
  });

  testWidgets('搜索框按站名过滤，清空恢复', (tester) async {
    await _open(tester);

    await tester.enterText(
      find.byKey(const ValueKey('site-picker-search')),
      'C站',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-picker-row-c')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsNothing);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-row-c')), findsOneWidget);
  });

  testWidgets('搜索无匹配显示空态', (tester) async {
    await _open(tester);

    await tester.enterText(
      find.byKey(const ValueKey('site-picker-search')),
      '不存在',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的站点'), findsOneWidget);
  });

  testWidgets('编辑模式删除确认后行消失，取消则保留', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(
      _host(
        onResult: (_) {},
        editMode: true,
        onDelete: (entry) async {
          if (entry.id == 'a') {
            deleted.add(entry.id);
            return true;
          }
          return false;
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('site-picker-delete-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-picker-delete-all')), findsNothing);
    expect(find.text('A站'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('site-picker-delete-a')));
    await tester.pumpAndSettle();
    expect(deleted, ['a']);
    expect(find.text('A站'), findsNothing);
    expect(find.text('B站'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-picker-delete-c')));
    await tester.pumpAndSettle();
    expect(find.text('C站'), findsOneWidget);
  });

  testWidgets('深色主题下弹窗背景跟随 surface，不固定白色', (tester) async {
    const surface = Color(0xFF1C1C1E);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: const ColorScheme.dark(surface: surface)),
        home: const Scaffold(
          body: SitePickerDialog(
            sectionName: '短剧',
            currentId: 'b',
            groups: _groups,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, surface);
  });

  testWidgets('编辑模式点行不切换，点完成退出编辑模式', (tester) async {
    await tester.pumpWidget(
      _host(onResult: (_) {}, editMode: true, onDelete: (_) async => true),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('site-picker-row-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-picker-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('site-picker-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-picker-delete-a')), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('打开弹窗自动滚到当前选中的站（宫格）', (tester) async {
    final groups = [
      SourcePickerGroup(
        title: '内置',
        entries: [
          for (var i = 1; i <= 30; i++)
            SourcePickerEntry(id: 's$i', name: '站$i'),
        ],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  await showSitePickerDialog(
                    context,
                    sectionName: '短剧',
                    currentId: 's30',
                    groups: groups,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final states = tester.stateList<ScrollableState>(find.byType(Scrollable));
    expect(states.any((s) => s.position.pixels > 0), isTrue);
    expect(
      find.byKey(const ValueKey('site-picker-row-s30')),
      findsOneWidget,
    );
  });

  testWidgets('不传 onImport 时右上角没有 + 号', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('site-picker-add')), findsNothing);
  });

  testWidgets('点 + 号先关弹窗再调导入回调，不切站', (tester) async {
    var imports = 0;
    String? picked = 'unset';
    await tester.pumpWidget(
      _host(
        onResult: (value) => picked = value,
        onImport: () async {
          imports++;
        },
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final addButton = find.byKey(const ValueKey('site-picker-add'));
    expect(addButton, findsOneWidget);
    // + 号在标题同一行、靠右：横坐标大于标题。
    expect(
      tester.getRect(addButton).left,
      greaterThan(tester.getRect(find.text('切换短剧源')).left),
    );

    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(picked, isNull);
    expect(find.byKey(const ValueKey('site-picker-dialog')), findsNothing);
  });
}
