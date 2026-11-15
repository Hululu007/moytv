import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/app_theme_config.dart';
import 'package:moyi/site_cube.dart';
import 'package:moyi/source_picker_sheet.dart';

import 'fixtures.dart';

const _groups = [
  SourcePickerGroup(
    title: '内置短剧',
    entries: [
      SourcePickerEntry(id: 'a', name: 'A站'),
      SourcePickerEntry(id: 'b', name: 'B站'),
    ],
  ),
];

Widget _cubeHost(SiteCube cube) =>
    MaterialApp(home: Scaffold(body: Center(child: cube)));

Widget _pickerHost({
  required AppThemeMode mode,
  required void Function(String?) onResult,
  bool editMode = false,
  Future<bool> Function(SourcePickerEntry entry)? onDelete,
}) => MaterialApp(
  theme: AppThemeConfig.forTheme(mode).toThemeData(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () async {
            final picked = await showSitePickerDialog(
              context,
              sectionName: '片库',
              currentId: 'b',
              groups: _groups,
              initialEditMode: editMode,
              onDeleteSite: onDelete,
              repository: FixtureRepository(),
            );
            onResult(picked);
          },
          child: const Text('打开'),
        ),
      ),
    ),
  ),
);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('方块无封面时六个面都显示站名与图标占位', (tester) async {
    await tester.pumpWidget(
      _cubeHost(const SiteCube(siteName: '测试站')),
    );
    await tester.pump();
    expect(find.text('测试站'), findsWidgets);
    expect(find.byIcon(Icons.dns_outlined), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('点方块触发回调', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _cubeHost(SiteCube(siteName: '测试站', onTap: () => taps++)),
    );
    await tester.pump();
    await tester.tap(find.byType(SiteCube));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('拖动旋转后不触发点按，之后点按仍可用', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _cubeHost(SiteCube(siteName: '测试站', onTap: () => taps++)),
    );
    await tester.pump();
    await tester.drag(find.byType(SiteCube), const Offset(120, 0));
    await tester.pump();
    expect(taps, 0);
    await tester.tap(find.byType(SiteCube));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('封面为空字符串的面同样显示占位', (tester) async {
    await tester.pumpWidget(
      _cubeHost(
        const SiteCube(siteName: '测试站', covers: ['', '']),
      ),
    );
    await tester.pump();
    expect(find.text('测试站'), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('紫蓝霓虹主题下站源弹窗渲染方块列，点方块返回站 id', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _pickerHost(
        mode: AppThemeMode.purpleNeon,
        onResult: (value) => picked = value,
      ),
    );
    await _openPicker(tester);
    expect(find.byType(SiteCube), findsWidgets);
    expect(find.text('A站'), findsWidgets);
    // 弹窗打开后自动滚到当前站（b），a 行中心已滑出可视区被裁剪、
    // 点按会落空；点 b 行同样验证“点方块返回站 id”。
    await tester.tap(find.byKey(const ValueKey('site-picker-row-b')));
    await tester.pumpAndSettle();
    expect(picked, 'b');
  });

  testWidgets('其它主题下站源弹窗保持普通列表，不渲染方块', (tester) async {
    await tester.pumpWidget(
      _pickerHost(
        mode: AppThemeMode.lightClean,
        onResult: (_) {},
      ),
    );
    await _openPicker(tester);
    expect(find.byType(SiteCube), findsNothing);
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('编辑模式下即使紫蓝霓虹主题也用普通列表', (tester) async {
    await tester.pumpWidget(
      _pickerHost(
        mode: AppThemeMode.purpleNeon,
        onResult: (_) {},
        editMode: true,
        onDelete: (_) async => false,
      ),
    );
    await _openPicker(tester);
    expect(find.byType(SiteCube), findsNothing);
    expect(find.byKey(const ValueKey('site-picker-row-a')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('site-picker-delete-a')),
      findsOneWidget,
    );
  });
}
