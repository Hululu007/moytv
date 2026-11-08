import 'package:moyi/core_bridge.dart';
import 'package:moyi/rule_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class RuleEditorRepository extends FixtureRepository {
  String? failValidate;
  String? failPreview;

  @override
  Future<Map<String, String>> validateCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    if (failValidate != null) throw AppFailure(failValidate!);
    return {'name': name, 'base': base, 'kind': kind};
  }

  @override
  Future<List<Map<String, String>>> previewCustomRule({
    required String name,
    required String base,
    String rule = '',
    String kind = '',
  }) async {
    if (failPreview != null) throw AppFailure(failPreview!);
    return [
      {'id': 'v1', 'title': '试跑剧集', 'cover': 'https://example.test/c.jpg'},
    ];
  }
}

void main() {
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 10 && finder.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> pump(
    WidgetTester tester,
    RuleEditorRepository repository,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: RuleEditorScreen(repository: repository)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('rule editor validates and shows the result', (tester) async {
    final repository = RuleEditorRepository();
    await pump(tester, repository);
    await tester.enterText(find.byType(TextField).at(0), '测试源');
    await tester.enterText(
      find.byType(TextField).at(1),
      'https://example.com/',
    );
    await reveal(tester, find.text('校验'));
    await tester.tap(find.text('校验'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('校验通过：测试源'));
    expect(find.textContaining('校验通过：测试源'), findsOneWidget);
  });

  testWidgets('rule editor shows validation errors verbatim', (tester) async {
    final repository = RuleEditorRepository()
      ..failValidate = '源网址需为 http 或 https 开头的完整地址';
    await pump(tester, repository);
    await reveal(tester, find.text('校验'));
    await tester.tap(find.text('校验'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('源网址需为 http 或 https 开头的完整地址'));
    expect(find.textContaining('源网址需为 http 或 https 开头的完整地址'), findsOneWidget);
  });

  testWidgets('rule editor previews items and failures', (tester) async {
    final repository = RuleEditorRepository();
    await pump(tester, repository);
    await reveal(tester, find.text('本地试跑'));
    await tester.tap(find.text('本地试跑'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('试跑成功：1 条'));
    expect(find.text('试跑成功：1 条'), findsOneWidget);
    await reveal(tester, find.text('试跑剧集'));
    expect(find.text('试跑剧集'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);
    repository.failPreview = '目录获取失败';
    await reveal(tester, find.text('本地试跑'));
    await tester.tap(find.text('本地试跑'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('目录获取失败'));
    expect(find.textContaining('目录获取失败'), findsOneWidget);
    expect(find.text('试跑剧集'), findsNothing);
  });
}
