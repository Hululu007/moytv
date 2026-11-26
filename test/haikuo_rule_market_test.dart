import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/miniapp/haikuo/haikuo_program.dart';
import 'package:moyi/miniapp/haikuo/haikuo_rule_market.dart';
import 'package:moyi/miniapp/haikuo/haikuo_store.dart';

Map<String, dynamic> _rule(String title, {Object? version}) => {
  'title': title,
  'type': 'video',
  'url': 'hiker://empty##https://example.com/$title',
  'col_type': 'movie_3',
  'find_rule': 'js:\nsetResult([{title: "$title"}]);',
  'version': ?version,
};

const _indexJson = {
  'name': '皇帝影院海阔规则仓库',
  'updated': '2026-11-26',
  'rules': [
    {
      'title': '🔞鉴黄师',
      'file': 'rules/鉴黄师.json',
      'version': 16,
      'author': '皇帝影院',
      'group': '🔞 成人专区',
      'icon': '',
      'updated': '2026-11-26',
    },
    {
      'title': '测试站',
      'file': 'rules/测试站.json',
      'version': '3',
      'author': '皇帝影院',
      'group': '普通区',
      'icon': '',
      'updated': '2026-11-26',
    },
  ],
};

/// 假拉取层：按地址分发本地夹具字节，不真联网。
HaikuoMarketFetcher _fakeFetcher({bool failIndex = false}) {
  return (Uri uri) async {
    if (uri.path.endsWith('index.json')) {
      if (failIndex) {
        throw const HaikuoRuleMarketException('下载失败：HTTP 404');
      }
      return utf8.encode(jsonEncode(_indexJson));
    }
    final fileName = uri.pathSegments.last; // pathSegments 已是解码后的段
    if (fileName == '鉴黄师.json') {
      return utf8.encode(jsonEncode(_rule('🔞鉴黄师', version: 16)));
    }
    if (fileName == '测试站.json') {
      return utf8.encode(jsonEncode(_rule('测试站', version: 3)));
    }
    throw HaikuoRuleMarketException('下载失败：未知地址 $uri');
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('版本号比较', () {
    test('数字与字符串混杂先按数值比', () {
      expect(compareHaikuoVersions(16, '16'), 0);
      expect(compareHaikuoVersions('2', '10'), lessThan(0));
      expect(compareHaikuoVersions('17', 16), greaterThan(0));
      expect(compareHaikuoVersions('1.2', '1.10'), lessThan(0));
      expect(compareHaikuoVersions(3, '3.0'), 0);
    });

    test('比不了数值时按字典序且不崩', () {
      expect(compareHaikuoVersions('v2', 'v10'), greaterThan(0)); // 字典序
      expect(compareHaikuoVersions(null, '1'), lessThan(0));
      expect(compareHaikuoVersions('', ''), 0);
      expect(compareHaikuoVersions('abc', 'abd'), lessThan(0));
    });
  });

  group('索引解析与下载地址', () {
    test('按仓库契约解析 index.json', () {
      final index = HaikuoRuleIndex.parse(
        jsonEncode(_indexJson),
        sourceUri: Uri.parse(haikuoRulesIndexUrl),
      );
      expect(index.name, '皇帝影院海阔规则仓库');
      expect(index.rules, hasLength(2));
      final first = index.rules.first;
      expect(first.title, '🔞鉴黄师');
      expect(first.version, '16'); // 数字 16 统一成字符串
      expect(first.group, '🔞 成人专区');
    });

    test('下载地址 = 索引同目录 + file，中文文件名做 URL 编码', () {
      final index = HaikuoRuleIndex.parse(
        jsonEncode(_indexJson),
        sourceUri: Uri.parse(haikuoRulesIndexUrl),
      );
      final uri = index.rules.first.downloadUri(index.sourceUri);
      expect(
        uri.toString().startsWith(
          'https://raw.githubusercontent.com/hoyittvggfh45/haikuo-rules/main/rules/',
        ),
        isTrue,
      );
      expect(uri.toString(), isNot(contains('鉴黄师')));
      expect(uri.pathSegments.last, '鉴黄师.json');
    });

    test('坏索引直接报错，不返回假数据', () {
      expect(
        () => HaikuoRuleIndex.parse(
          'not json',
          sourceUri: Uri.parse(haikuoRulesIndexUrl),
        ),
        throwsA(isA<HaikuoRuleMarketException>()),
      );
    });
  });

  group('市场服务链路', () {
    late Directory temp;
    late HaikuoStore store;
    late HaikuoRuleMarketService service;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('haikuo-market-');
      store = HaikuoStore(rootOverride: temp);
      service = HaikuoRuleMarketService(
        store: store,
        fetcher: _fakeFetcher(),
      );
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('拉索引 → 点安装调既有导入 → 本地库出现该规则', () async {
      final index = await service.fetchIndex();
      expect(index.rules, hasLength(2));
      expect(
        await service.installState(index.rules.first),
        HaikuoRuleInstallState.notInstalled,
      );
      final result = await service.install(index.rules.first, index: index);
      expect(result.added, hasLength(1));
      final programs = await store.list();
      expect(programs.map((p) => p.name), contains('🔞鉴黄师'));
      expect(programs.single.version, '16');
      expect(programs.single.origin, '海阔规则仓库');
      expect(
        await service.installState(index.rules.first),
        HaikuoRuleInstallState.installed,
      );
    });

    test('本地版本低于索引时判定可更新', () async {
      await store.importText(
        jsonEncode(_rule('🔞鉴黄师', version: 15)),
        origin: '测试',
      );
      final index = await service.fetchIndex();
      expect(
        await service.installState(index.rules.first),
        HaikuoRuleInstallState.updateAvailable,
      );
      // 批量状态与逐条判定一致
      final states = await service.installStates(index);
      expect(
        states['🔞鉴黄师'],
        HaikuoRuleInstallState.updateAvailable,
      );
      expect(states['测试站'], HaikuoRuleInstallState.notInstalled);
    });

    test('索引拉取失败抛错（页面据此走空态）', () async {
      final failing = HaikuoRuleMarketService(
        store: store,
        fetcher: _fakeFetcher(failIndex: true),
      );
      await expectLater(
        failing.fetchIndex(),
        throwsA(isA<HaikuoRuleMarketException>()),
      );
    });

    test('同名不同内容安装走既有 onDuplicates 口径（替换）', () async {
      // 先装一份同名但内容不同（id 不同）的旧规则。
      final old = _rule('🔞鉴黄师', version: 15);
      old['url'] = 'hiker://empty##https://example.com/old';
      await store.importText(jsonEncode(old), origin: '测试');
      final index = await service.fetchIndex();
      var asked = 0;
      final result = await service.install(
        index.rules.first,
        index: index,
        onDuplicates: (duplicates) async {
          asked++;
          expect(duplicates.single.incoming.name, '🔞鉴黄师');
          return HaikuoDuplicateDecision.replace;
        },
      );
      expect(asked, 1);
      expect(result.updated, hasLength(1));
      final programs = await store.list();
      expect(programs, hasLength(1));
      expect(programs.single.version, '16');
    });
  });

  group('市场区界面', () {
    late Directory temp;
    late HaikuoStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('haikuo-market-ui-');
      store = HaikuoStore(rootOverride: temp);
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<void> pumpView(
      WidgetTester tester,
      HaikuoRuleMarketService service,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HaikuoRuleMarketView(service: service))),
      );
      // 等假拉取与本地库读取完成（真时间轮询，不用 pumpAndSettle 死等）。
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('🔞鉴黄师').evaluate().isNotEmpty ||
            find.text('海阔规则仓库拉取失败').evaluate().isNotEmpty) {
          return;
        }
      }
    }

    testWidgets('列表展示索引条目，点安装后本地库出现规则且按钮变已安装', (
      tester,
    ) async {
      final service = HaikuoRuleMarketService(
        store: store,
        fetcher: _fakeFetcher(),
      );
      await pumpView(tester, service);
      expect(find.text('🔞鉴黄师'), findsOneWidget);
      expect(find.text('测试站'), findsOneWidget);
      expect(find.text('🔞 成人专区'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '安装').first);
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('已安装').evaluate().isNotEmpty) break;
      }
      expect(find.text('已安装'), findsOneWidget);
      final programs = await tester.runAsync(() => store.list());
      expect(programs!.map((p) => p.name), contains('🔞鉴黄师'));
    });

    testWidgets('索引拉取失败显示诚实空态与重试', (tester) async {
      final service = HaikuoRuleMarketService(
        store: store,
        fetcher: _fakeFetcher(failIndex: true),
      );
      await pumpView(tester, service);
      expect(find.text('海阔规则仓库拉取失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('🔞鉴黄师'), findsNothing);
    });
  });
}
