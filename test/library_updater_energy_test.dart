// 能耗优化：LibraryUpdater 切后台暂停。
//
// 首页以前即使用户闲着、甚至 App 切后台，也每 10 秒全量刷一次
// 站源状态再加一次全屏 setState。修法：
//  1. setPaused(true) 后 refresh() 直接返回，不碰桥接、不发通知；
//  2. setPaused(false) 回前台时立刻补一次刷新，不丢状态变化。
// 空闲刷新由每 10 秒放慢到每 30 秒（_ticks % 5 -> % 15），
// 是单行常量改动，靠代码检查确认，不在此用慢测试覆盖。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/library_updater.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('paused updater skips refresh and resumes with a catch-up refresh',
      () async {
    final store = await createStore();
    final repository = LibraryFeatureRepository();
    final updater = LibraryUpdater(repository, store);
    addTearDown(updater.dispose);
    final sources = [SourceSite.byId('hongguo')];

    // 先登记一个站源，让 refresh() 有真实工作可做。
    await updater.update(sources);
    expect(updater.busy('hongguo'), isTrue);

    var notifications = 0;
    updater.addListener(() => notifications++);

    // 未暂停时 refresh() 正常跑，会发通知。
    await updater.refresh();
    expect(notifications, greaterThan(0));

    // 暂停后 refresh() 直接返回：不碰桥接、不发通知。
    updater.setPaused(true);
    notifications = 0;
    await updater.refresh();
    expect(notifications, 0);
    // 重复暂停是空操作，不炸。
    updater.setPaused(true);
    await updater.refresh();
    expect(notifications, 0);

    // 恢复时立刻补一次刷新，状态变化不丢。
    updater.setPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(notifications, greaterThan(0));
    expect(updater.busy('hongguo'), isTrue);
  });

  test('setPaused is a no-op after dispose', () async {
    final store = await createStore();
    final repository = LibraryFeatureRepository();
    final updater = LibraryUpdater(repository, store);
    updater.dispose();
    // 恢复/暂停都不应抛异常（首页 dispose 先摘观察者再销毁，
    // 正常流程走不到这里，这是兜底）。
    updater.setPaused(true);
    updater.setPaused(false);
  });
}
