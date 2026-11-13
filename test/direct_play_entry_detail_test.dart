import 'package:moyi/detail_screen.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/player_screen.dart';
import 'package:moyi/recommendations_screen.dart';
import 'package:moyi/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class DetailOpenRepository extends FixtureRepository {
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => CatalogPage([FixtureRepository.free]);
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

  // 设置页子树有不收敛的帧源，pumpAndSettle 永远等不到头（实测挂死
  // 10 分钟）；按树里预览测试的 settlePreview 模式用定额 pump。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('recommendation card tap opens detail instead of playback',
      (tester) async {
    viewport(tester);
    final store = await createStore();
    final repository = DetailOpenRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendationsScreen(repository: repository, store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsOneWidget);
    await tester.tap(find.text('测试短剧'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saved history tile tap opens detail instead of playback',
      (tester) async {
    viewport(tester);
    final store = await createStore();
    // saveWatch 会走数据库同步（AppDatabase 打开时调平台通道取文档目录）。
    // testWidgets 的假时间里、无 mock 的平台通道调用在无人 pump 时永不
    // 返回（实测：直接 await 会挂满 2 分钟超时），而这里 pumpWidget 之前
    // 不可能 pump。runAsync 用真异步跑完这次调用：通道调用立即抛
    // MissingPluginException，被数据库同步的 try/catch 吃掉，写盘照常完成。
    await tester.runAsync(() async {
      await store.saveWatch(
        WatchEntry(
          drama: FixtureRepository.free,
          episode: 1,
          position: 12,
          duration: 60,
          updatedAt: DateTime.utc(2026, 9, 21),
        ),
      );
    });
    final repository = DetailOpenRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(repository: repository, store: store),
      ),
    );
    await settle(tester);
    // ensureVisible / scrollUntilVisible 末尾都会等滚动动画完成，假时间
    // 下无人 pump 即死锁（实测挂死两次）；改手动 fling + 定额 pump。
    final rowFinder = find.byKey(const ValueKey('saved-history-entry'));
    for (var i = 0; i < 8; i++) {
      final matches = rowFinder.evaluate();
      if (matches.isNotEmpty) {
        final center = tester.getCenter(rowFinder);
        if (center.dy > 40 && center.dy < 800) break;
      }
      await tester.fling(
        find.byType(SettingsScreen),
        const Offset(0, -400),
        1000,
      );
      await settle(tester);
    }
    await tester.tap(rowFinder);
    await settle(tester);
    expect(find.byKey(ValueKey('saved-${FixtureRepository.free.id}')),
        findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('saved-${FixtureRepository.free.id}')),
    );
    await settle(tester);
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
