// 演员库入口替换测试：合并页资源在位时入口落到 HTML 宿主页；
// 资源内容含女优库板块与 fm.nvku 兜底调用（防打包漏文件）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/actress/actress_html_entry.dart';
import 'package:moyi/html_host/html_host_page.dart';
import 'package:moyi/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('合并页资源在位且含 whos 板块与 fm.nvku 调用', () async {
    final html = await rootBundle.loadString(ActressHtmlEntryPage.assetPath);
    expect(html.length, greaterThan(100000));
    expect(html, contains('fm.nvku'));
    expect(html, contains('whos')); // 女优库板块适配器
    expect(html, contains('jable')); // 123 侧聚合站保留
    expect(html, contains('missav'));
    expect(html, contains('supjav'));
  });

  testWidgets('入口页资源加载后落到 HTML 宿主页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        home: ActressHtmlEntryPage(
          repository: FixtureRepository(),
          store: store,
          showTitle: false,
        ),
      ),
    );
    // 资源是真文件读取（异步 IO），用真时间轮询等宿主页出现。
    var found = false;
    for (var i = 0; i < 40 && !found; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      found = find.byType(HtmlHostPage).evaluate().isNotEmpty;
    }
    expect(found, isTrue, reason: '入口应落到 HtmlHostPage（合并页）');
  });
}
