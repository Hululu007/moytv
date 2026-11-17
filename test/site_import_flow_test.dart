import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/site_import_flow.dart';

Future<void> _openChoice(WidgetTester tester, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const SiteImportChoiceDialog(),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分流弹窗有两个导入选项与取消', (tester) async {
    await _openChoice(tester);
    expect(find.text('导入站点'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('site-import-local-py')),
      findsOneWidget,
    );
    expect(find.text('导入本地 py'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('site-import-remote-config')),
      findsOneWidget,
    );
    expect(find.text('添加远程配置'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('点选项后弹窗关闭', (tester) async {
    await _openChoice(tester);
    await tester.tap(find.byKey(const ValueKey('site-import-remote-config')));
    await tester.pumpAndSettle();
    expect(find.text('导入站点'), findsNothing);
  });

  testWidgets('分流弹窗背景跟随主题 surface，不固定白色', (tester) async {
    const surface = Color(0xFF1C1C1E);
    await _openChoice(
      tester,
      theme: ThemeData(colorScheme: const ColorScheme.dark(surface: surface)),
    );
    // AlertDialog 不在 Dialog 上写死背景色，渲染时回落到 surface：
    // 取标题最近的 Material 祖先验实际渲染色。
    final material = tester.widget<Material>(
      find.ancestor(
        of: find.text('导入本地 py'),
        matching: find.byType(Material),
      ),
    );
    expect(material.color, surface);
  });

  testWidgets('添加接口弹窗字段齐全', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AddInterfaceDialog(),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('添加接口'), findsOneWidget);
    expect(find.text('配置名称'), findsOneWidget);
    expect(find.text('接口地址'), findsOneWidget);
    expect(find.text('选择本地文件'), findsOneWidget);
    expect(find.text('添加'), findsOneWidget);
  });
}
