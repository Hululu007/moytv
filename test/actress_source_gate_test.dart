// 演员库内部源门禁回归测试（2026-11-26 发版实报修复）：
// 演员库整批新接的 6 个源 id（javdb / av123 / ph / av01 /
// jable / pan115）此前没在任何登记表里登记，详情页源门禁
// allowsSource 对它们恒为假——从演员库点开任何作品都误落
// 「当前用户无权访问」面板（诊断报告 moyi_noperm_diag_
// 20261126）。修法是给 6 个 id 建演员库专用登记
// （SourceSite.actressOnlySites），不进选站列表、不放宽
// allowsSource 本身。
//
// 本测试的口径是上一轮漏检的反面：全程按正式 App 的真实
// 登记状态跑——新建空 LocalStore、不往任何登记表里塞测试
// 侧条目。谁把专用登记删了，这批测试立刻红。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

const _actressIds = ['javdb', 'av123', 'ph', 'av01', 'jable', 'pan115'];

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('演员库专用登记（真实登记状态，不做测试侧登记）', () {
    test('6 个 id 被 isAvailable / isKnown / byId 认得', () {
      for (final id in _actressIds) {
        expect(SourceSite.isAvailable(id), isTrue, reason: id);
        expect(SourceSite.isKnown(id), isTrue, reason: id);
        // byId 不许回落红果（详情页顶栏站名靠它）。
        expect(SourceSite.byId(id).id, id, reason: id);
      }
    });

    test('allowsSource 对 6 个 id 放行、对未注册 id 照旧拦', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      for (final id in _actressIds) {
        expect(store.allowsSource(id), isTrue, reason: id);
      }
      expect(SourceSite.isAvailable('unregistered-random-id'), isFalse);
      expect(store.allowsSource('unregistered-random-id'), isFalse);
    });

    test('6 个 id 不进选站列表，网盘 cloud:pan115 不受牵连', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final listed = store.sources.map((site) => site.id).toSet();
      for (final id in _actressIds) {
        expect(listed.contains(id), isFalse, reason: id);
      }
      // pan115（演员库 115 线）与 cloud:pan115（网盘站）是两个
      // id：专用登记只认前者，后者仍只由网盘登录态注册表决定。
      expect(SourceSite.actressOnlySites.containsKey('cloud:pan115'), isFalse);
      expect(SourceSite.cloudDriveSites.containsKey('pan115'), isFalse);
    });
  });

  group('详情页进页门禁（正式状态）', () {
    for (final id in _actressIds) {
      testWidgets('source=$id 的作品进详情页出内容、不落没权限面板', (
        tester,
      ) async {
        viewport(tester);
        final store = await createStore();
        final drama = Drama(
          id: 'gate-$id',
          source: id,
          title: '门禁回归作品 $id',
          episodes: 2,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(
              drama: drama,
              repository: FixtureRepository(),
              store: store,
            ),
          ),
        );
        await _settle(tester);
        expect(find.text('当前用户无权访问'), findsNothing);
        expect(find.text('门禁回归作品 $id'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('未注册随机 id 的作品仍被门禁拦下', (tester) async {
      viewport(tester);
      final store = await createStore();
      const drama = Drama(
        id: 'gate-unknown',
        source: 'unregistered-random-id',
        title: '未注册来源作品',
        episodes: 1,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            drama: drama,
            repository: FixtureRepository(),
            store: store,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('当前用户无权访问'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('pan115 竞速赢家详情进页能起播（direct 直链集）', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      viewport(tester);
      final store = await createStore();
      // 与 actress_detail_page 里 115 线造 DramaDetail 的形状
      // 一字不差（只把地址换成回环，跳过真实网络预解析）。
      final detail = DramaDetail(
        const Drama(
          id: 'pan115:file-1',
          source: 'pan115',
          sourceId: 'file-1',
          title: '115 线作品',
          tags: ['TEST-001'],
        ),
        [
          Episode({
            'id': 'http://127.0.0.1:9/pan115/test.m3u8',
            'title': '正片',
            'direct': true,
            'headers': <String, String>{},
          }, 1),
        ],
      );
      final created = <ScriptedPlayer>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DetailScreen(
            drama: detail.drama,
            repository: FixtureRepository(),
            store: store,
            initialDetail: detail,
            playerFactory: () {
              final platform = ScriptedPlayer();
              created.add(platform);
              return Player(platformPlayer: platform);
            },
            videoBuilder: (controls) => controls,
          ),
        ),
      );
      await _settle(tester);
      expect(find.text('当前用户无权访问'), findsNothing);
      expect(find.byType(PlayerScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('detail-poster-play')));
      await _settle(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(find.text('当前用户无权访问'), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
