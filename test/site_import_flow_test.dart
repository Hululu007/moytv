import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/import_center.dart';
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
      find.byKey(const ValueKey('site-import-local-files')),
      findsOneWidget,
    );
    expect(find.text('导入本地文件'), findsOneWidget);
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
        of: find.text('导入本地文件'),
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

  test('汇总文本：计数行 + 每个未成功文件的名字与原因', () {
    final text = buildImportResultText([
      const ImportOutcome(
        fileName: '好站.py',
        status: ImportOutcomeStatus.success,
        reason: '已注册为 Python 蜘蛛站',
      ),
      const ImportOutcome(
        fileName: '重复.json',
        status: ImportOutcomeStatus.duplicate,
        reason: '内容与已导入的「旧站」完全相同，跳过',
      ),
      const ImportOutcome(
        fileName: '坏站.html',
        status: ImportOutcomeStatus.failed,
        reason: '解析失败：缺主页',
      ),
    ]);
    expect(text, contains('成功 1 · 重复跳过 1 · 失败 1'));
    expect(text, contains('重复.json：内容与已导入的「旧站」完全相同，跳过'));
    expect(text, contains('坏站.html：解析失败：缺主页'));
    // 成功的文件只出现在计数里，不逐条列出。
    expect(text, isNot(contains('好站.py')));
  });

  test('汇总文本：全部成功时只有计数行', () {
    final text = buildImportResultText([
      const ImportOutcome(
        fileName: '好站.py',
        status: ImportOutcomeStatus.success,
        reason: '已注册',
      ),
    ]);
    expect(text, '成功 1 · 重复跳过 0 · 失败 0');
  });

  testWidgets('导入完成汇总弹窗列出失败文件与原因，点确定关闭', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showImportResultDialog(context, [
                  const ImportOutcome(
                    fileName: '好站.py',
                    status: ImportOutcomeStatus.success,
                    reason: '已注册',
                  ),
                  const ImportOutcome(
                    fileName: '坏站.html',
                    status: ImportOutcomeStatus.failed,
                    reason: '解析失败：缺主页',
                  ),
                ]),
                child: const Text('打开汇总'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开汇总'));
    await tester.pumpAndSettle();
    expect(find.text('导入完成'), findsOneWidget);
    expect(find.textContaining('成功 1 · 重复跳过 0 · 失败 1'), findsOneWidget);
    expect(find.textContaining('坏站.html：解析失败：缺主页'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('导入完成'), findsNothing);
  });
}
