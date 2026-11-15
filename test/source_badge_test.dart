import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/follow_state.dart';
import 'package:moyi/jar_bridge.dart';
import 'package:moyi/local_profiles.dart';
import 'package:moyi/local_snapshot.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/plugin_icons.dart';
import 'package:moyi/saved_library.dart';
import 'package:moyi/source_badge.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

void main() {
  const jarId = 'jar:zakatv:fakebadge';
  const pyId = 'py:fakebadge';

  void registerJarSite() {
    SourceSite.importedSites[jarId] = const SourceSite(
      jarId,
      '假 jar 站',
      '合成数据',
      section: SourceSite.sectionVideo,
    );
    JarBridge.register(
      const JarSiteSpec(
        siteId: jarId,
        configId: 'zakatv',
        name: '假 jar 站',
        className: 'Fake',
        jarUrl: '',
        jarMd5: '',
        ext: '',
      ),
    );
    addTearDown(() {
      JarBridge.unregister(jarId);
      SourceSite.importedSites.remove(jarId);
    });
  }

  void registerPySite() {
    SourceSite.importedSites[pyId] = const SourceSite(
      pyId,
      '假 py 站',
      '合成数据',
      section: SourceSite.sectionVideo,
    );
    SourceSite.importedPyFiles[pyId] = 'fakebadge.py';
    addTearDown(() {
      SourceSite.importedSites.remove(pyId);
      SourceSite.importedPyFiles.remove(pyId);
    });
  }

  Future<void> pumpBadge(WidgetTester tester, String sourceId) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SourceBadge(sourceId: sourceId)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Go 核源只显示文字徽标，不编图标', (tester) async {
    await pumpBadge(tester, 'hongguo');
    expect(find.text('红果'), findsOneWidget);
    expect(find.byType(PluginTypeIcon), findsNothing);
  });

  testWidgets('jar 站徽标显示站名与咖啡杯图标', (tester) async {
    registerJarSite();
    await pumpBadge(tester, jarId);
    expect(find.text('假 jar 站'), findsOneWidget);
    final icon = tester.widget<PluginTypeIcon>(find.byType(PluginTypeIcon));
    expect(icon.kind, PluginIconKind.jar);
  });

  testWidgets('py 站徽标显示站名与爬虫图标', (tester) async {
    registerPySite();
    await pumpBadge(tester, pyId);
    expect(find.text('假 py 站'), findsOneWidget);
    final icon = tester.widget<PluginTypeIcon>(find.byType(PluginTypeIcon));
    expect(icon.kind, PluginIconKind.py);
  });

  testWidgets('未知来源与空来源不显示徽标，不借用其它站名', (tester) async {
    await pumpBadge(tester, 'no-such-site');
    expect(find.text('红果'), findsNothing);
    expect(find.byType(SourceBadge), findsOneWidget);
    expect(tester.getSize(find.byType(SourceBadge)), Size.zero);

    await pumpBadge(tester, '');
    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(SourceBadge)), Size.zero);
  });

  // 有界 pump：SavedLibrary 所在的屏在 pumpAndSettle 下不收敛
  // （预览测试同款套路），不等它 settle，只推固定帧数。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      try {
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
    for (var i = 0; i < 10; i++) {
      try {
        if (tester.takeException() == null) break;
      } catch (_) {
        break;
      }
    }
  }

  // 追剧数据直接预置进偏好快照、由 LocalStore 构造时同步读入：
  // setFollowStatus 这类写路径在本测试环境下永不返回（二分定位：
  // 卡在写路径的 AppDatabase 同步上，与徽标无关的旧坑），测试里
  // 不走写路径。
  Future<LocalStore> seededStore(List<(Drama, FollowState)> items) async {
    const profile = LocalProfile(id: 'default', name: '管理员', admin: true);
    final values = <String, Object>{
      'profiles': jsonEncode([profile.toJson()]),
      'activeProfile': 'default',
      'favorites': jsonEncode([for (final (drama, _) in items) drama.toJson()]),
      'followStates': jsonEncode({
        for (final (drama, state) in items) drama.id: state.toJson(),
      }),
    };
    SharedPreferences.setMockInitialValues({
      LocalSnapshot.storageKey: jsonEncode({'version': 1, 'values': values}),
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  testWidgets('在看卡片徽标不与更多按钮、集数标、状态条重叠，点按照常进详情', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const drama = Drama(
      id: 'hongguo:badge-one',
      source: 'hongguo',
      title: '徽标一号',
      episodes: 12,
    );
    const state = FollowState(
      status: FollowStatus.watching,
      knownEpisodes: 12,
      readEpisodes: 12,
    );
    final store = await seededStore([(drama, state)]);
    final opened = <String>[];
    final continued = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SavedLibrary(
            repository: LibraryFeatureRepository(),
            store: store,
            history: false,
            onOpen: (item) => opened.add(item.id),
            onContinue: (item) => continued.add(item.id),
          ),
        ),
      ),
    );
    await settle(tester);

    final badgeFinder = find.byType(SourceBadge);
    expect(badgeFinder, findsOneWidget);
    // 副标题里也会出现源名，只断言徽标内部的那一个。
    expect(
      find.descendant(of: badgeFinder, matching: find.text('红果')),
      findsOneWidget,
    );
    expect(find.text('立即播放'), findsNothing);
    final badgeRect = tester.getRect(badgeFinder);
    final actionsRect = tester.getRect(
      find.byKey(ValueKey('drama-actions-${drama.id}')),
    );
    expect(badgeRect.overlaps(actionsRect), isFalse);
    expect(badgeRect.top, greaterThanOrEqualTo(actionsRect.bottom));
    final episodeRect = tester.getRect(find.text('共 12 集'));
    expect(badgeRect.overlaps(episodeRect), isFalse);
    final statusRect = tester.getRect(
      find.descendant(
        of: find.byKey(ValueKey('saved-${drama.id}')),
        matching: find.text('在看'),
      ),
    );
    expect(badgeRect.overlaps(statusRect), isFalse);

    // 点在徽标正中心：徽标不拦点按，卡片照常进详情、不直接播。
    await tester.tapAt(badgeRect.center);
    await settle(tester);
    expect(opened, [drama.id]);
    expect(continued, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
