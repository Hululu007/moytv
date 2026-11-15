import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/collapsible_section_help.dart';
import 'package:moyi/custom_sources_screen.dart';
import 'package:moyi/import_center_section.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/py_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _customFull =
    '自定义源读取网站地址并判断是否符合 MacCMS 规范；符合后套用通用规则自动完成列表展示、搜索与播放。录入 XBPQ 爬虫规则的站点按规则字段逐项截取。';
const _customEmptyFull =
    '还没有自定义源。点击「新增」填入 MacCMS 站点地址或粘贴 XBPQ 爬虫规则；也可以「导入文件」批量添加，「导出 JSON」备份迁移。';
const _importFull =
    '批量扫描文件夹或多选文件导入 py / js / json / jar / zip：py 经 Python 桥成站，'
    'XBPQ 规则 JSON 进核心规则通道，自定义源 JSON 进自定义源通道，'
    'TVBox 配置与 jar 转交 jar 桥（未接入时明确失败），js 先注册占位。'
    'jar + 配置 JSON 的 zip 包会拆开导入，包里的站点配置自动带上 ext 与站名；'
    '没有配置的 jar 站点会在报告里明确提醒。'
    '导入按内容哈希去重，并逐个给出结果报告。';
const _m3uFull =
    '导入本地 m3u 文件或订阅远程地址：#EXTINF 的 group-title 作频道分类、'
    'tvg-logo 作台标，频道进入直播区；订阅可刷新、改名、删除，解析失败会明确报错。';
const _crackFull =
    '导入 JSON 配置文件，让各站过盾与 VIP 配置由壳应用：过盾项按域名作用于抓取层，'
    'VIP 项只在本站已有令牌口子时生效。导入整单校验，不合格整单拒收；'
    '密钥只存本机，不写入日志；导出文件含密钥，请妥善保管。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Python 运行时一行', () {
    test('完整版本串只取第一段', () {
      const status = PyRuntimeStatus(
        available: true,
        python:
            '3.11.17 (main, Oct 2 2026, 02:59:43) [Clang 18.0.4 (https://android.googlesource.com/toolchain/llvm-project d8003a456)]',
      );
      final label = pythonRuntimeLabel(status);
      expect(label, 'Python 运行时：可用（3.11.17）');
      expect(label, isNot(contains('Clang')));
      expect(label, isNot(contains('https://')));
    });

    test('可用但版本号为空时不带括号', () {
      expect(
        pythonRuntimeLabel(const PyRuntimeStatus(available: true)),
        'Python 运行时：可用',
      );
    });

    test('版本号前有空白也只取第一段', () {
      expect(
        pythonRuntimeLabel(
          const PyRuntimeStatus(available: true, python: '  3.12.0 (main)'),
        ),
        'Python 运行时：可用（3.12.0）',
      );
    });

    test('未就绪只有一行', () {
      expect(
        pythonRuntimeLabel(
          const PyRuntimeStatus(available: false, detail: '桥未报告可用'),
        ),
        'Python 运行时：未就绪',
      );
    });
  });

  group('可展开说明组件', () {
    testWidgets('默认收起、点开显示全文、再点收起', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CollapsibleSectionHelp(
              key: ValueKey('standalone-help'),
              toggleKey: ValueKey('standalone-help-toggle'),
              brief: '批量导入各格式源文件',
              fullText: _importFull,
            ),
          ),
        ),
      );
      expect(find.text('批量导入各格式源文件'), findsOneWidget);
      expect(find.text(_importFull), findsNothing);
      await tester.tap(find.byKey(const ValueKey('standalone-help-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(_importFull), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('standalone-help-toggle')));
      await tester.pumpAndSettle();
      expect(find.text(_importFull), findsNothing);
    });
  });

  group('内容源管理页压缩', () {
    Future<LocalStore> pumpPage(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: CustomSourcesScreen(
            repository: FixtureRepository(),
            store: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('默认全文收起、按钮都在、运行时一行', (tester) async {
      final store = await pumpPage(tester);
      expect(find.text('MacCMS 规范站点自动成站'), findsOneWidget);
      expect(find.text('还没有自定义源，点新增添加'), findsOneWidget);
      expect(find.text('批量导入各格式源文件'), findsOneWidget);
      expect(find.text('导入 m3u 文件或订阅地址'), findsOneWidget);
      expect(find.text('导入 JSON 配置过盾与 VIP'), findsOneWidget);
      for (final full in [
        _customFull,
        _customEmptyFull,
        _importFull,
        _m3uFull,
        _crackFull,
      ]) {
        expect(find.text(full), findsNothing);
      }
      for (final label in [
        '新增',
        '扫描文件夹批量导入',
        '多选文件批量导入',
        '导入单个 py',
        '安装插件',
        '导入 m3u 文件',
        '订阅 m3u 地址',
        '导入 JSON 配置',
        '导出当前配置',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Python 运行时：未就绪'), findsOneWidget);
      expect(find.textContaining('Clang'), findsNothing);
      expect(find.textContaining('py 站可见'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });

    testWidgets('逐区点说明展开后全文可见', (tester) async {
      final store = await pumpPage(tester);
      const helps = <String, String>{
        'custom-source-help-toggle': _customFull,
        'custom-source-empty-help-toggle': _customEmptyFull,
        'import-center-help-toggle': _importFull,
        'm3u-help-toggle': _m3uFull,
        'crack-config-help-toggle': _crackFull,
      };
      for (final entry in helps.entries) {
        final toggle = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      }
      expect(find.text('扫描文件夹批量导入'), findsOneWidget);
      expect(find.text('导入 m3u 文件'), findsOneWidget);
      expect(find.text('导入 JSON 配置'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
  });
}
