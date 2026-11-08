import 'dart:convert';

import 'package:moyi/local_profiles.dart';
import 'package:moyi/local_snapshot.dart';
import 'package:moyi/local_store.dart';
import 'package:moyi/models.dart';
import 'package:moyi/playback_preferences.dart';
import 'package:moyi/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences(super.data) : super.withData();
  String failure = '';
  int snapshots = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith(LocalSnapshot.storageKey)) {
      snapshots++;
      if (failure == 'false') return false;
      if (failure == 'throw') throw StateError('synthetic write failure');
      if (failure == 'after') {
        failure = '';
        await super.setValue(valueType, key, value);
        throw StateError('synthetic acknowledgement failure');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '旧资料');
  const next = Drama(id: 'hongguo:2', source: 'hongguo', title: '新资料');

  Future<(LocalStore, FailingPreferences)> create([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.resetStatic();
    final platform = FailingPreferences({
      for (final entry in initial.entries) 'flutter.${entry.key}': entry.value,
    });
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return (store, platform);
  }

  Future<LocalStore> restart(FailingPreferences platform) async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  for (final failure in ['false', 'throw', 'after']) {
    test(
      'failed $failure writes keep favorites, preferences and progress after restart',
      () async {
        final (store, platform) = await create({
          'plugin_secret': 'outside-the-backup',
        });
        await store.toggleFavorite(drama);
        await store.saveWatch(
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 15,
            duration: 100,
            updatedAt: DateTime.now(),
          ),
        );
        for (final change in <Future<void> Function()>[
          () => store.toggleFavorite(next),
          () => store.clearHistory(),
          () => store.setThemeMode('light'),
          () => store.setPlaybackPreferences(
            const PlaybackPreferences(
              speed: 2,
              quality: 720,
              autoAdvance: false,
            ),
          ),
        ]) {
          platform.failure = failure;
          await expectLater(change(), throwsStateError);
          expect(store.favorites.map((entry) => entry.id), [drama.id]);
          expect(store.watched(drama.id)?.position, 15);
          expect(store.themeMode, 'system');
          expect(store.playbackPreferences.speed, 1);
          final restored = await restart(platform);
          expect(restored.favorites.single.id, drama.id);
          expect(restored.watched(drama.id)?.position, 15);
          expect(restored.themeMode, 'system');
          expect(
            restored.preferences.getString('plugin_secret'),
            'outside-the-backup',
          );
        }
        platform.failure = '';
        await store.toggleFavorite(next);
        expect((await restart(platform)).favorites.length, 2);
      },
    );
  }


  test(
    'queued mutations preserve all successful records and isolate playback preferences',
    () async {
      final (store, platform) = await create();
      await Future.wait([
        store.toggleFavorite(drama),
        store.toggleFavorite(next),
      ]);
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720, autoAdvance: false),
      );
      await store.saveProfile(
        name: '访客',
        sources: ['hongguo'],
        download: false,
      );
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(visitor.id);
      expect(store.playbackPreferences.speed, 1);
      await store.setPlaybackPreferences(const PlaybackPreferences(speed: .75));
      await store.switchProfile('default', pin: 'abcdef12');
      expect(store.playbackPreferences.speed, 1.5);
      final restored = await restart(platform);
      expect(restored.locked, isFalse);
      await restored.switchProfile('default', pin: 'abcdef12');
      expect(restored.favorites.length, 2);
      expect(restored.playbackPreferences.autoAdvance, isFalse);
    },
  );

  for (final records in <Object>[
    'broken-json',
    '[]',
    jsonEncode([
      const LocalProfile(
        id: 'default',
        name: '管理员',
        admin: true,
        salt: '11111111111111111111111111111111',
        pinHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ).toJson(),
      {'id': 'visitor', 'name': 7},
    ]),
    jsonEncode([
      {
        'id': 'default',
        'name': '管理员',
        'admin': true,
        'sources': [],
        'salt': 'bad',
      },
    ]),
  ]) {
    test(
      'damaged profiles remain locked without replacing raw data: $records',
      () async {
        final (store, platform) = await create({
          'profiles': records,
          'favorites': jsonEncode([drama.toJson()]),
        });
        expect(store.configurationError, isNotNull);
        expect(store.locked, isTrue);
        expect(store.profile.admin, isFalse);
        expect(store.canDownload, isFalse);
        expect(store.favorites, isEmpty);
        expect(store.sources, isEmpty);
        await expectLater(store.switchProfile('default'), throwsStateError);
        expect(platform.snapshots, 0);
        final restored = await restart(platform);
        expect(restored.configurationError, isNotNull);
        expect(restored.preferences.get('profiles'), records);
      },
    );
  }

  testWidgets(
    'damaged profile screen offers recovery without an unlocked administrator',
    (tester) async {
      final (store, _) = await create({'profiles': 'bad'});
      await tester.pumpWidget(
        MaterialApp(home: ProfilesScreen(store: store, locked: true)),
      );
      expect(find.text('重新读取配置'), findsOneWidget);
      expect(find.text('添加用户'), findsNothing);
      expect(find.text('管理员 · 全部权限'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('视频区按区记忆上次站点，重启后各区恢复自己的站', () async {
    final (store, platform) = await create();
    expect(store.zoneSource('drama'), '');
    await store.setZoneSource('drama', 'hongguo');
    await store.setZoneSource('vod', 'missav');
    await store.setZoneSource('midnight', '__all__');
    expect(store.zoneSource('drama'), 'hongguo');
    expect(store.zoneSource('vod'), 'missav');
    expect(store.zoneSource('midnight'), '__all__');

    final restarted = await restart(platform);
    expect(restarted.zoneSource('drama'), 'hongguo');
    expect(restarted.zoneSource('vod'), 'missav');
    expect(restarted.zoneSource('midnight'), '__all__');
  });

  test('视频区记忆写盘失败也不抛错', () async {
    final (store, platform) = await create();
    platform.failure = 'throw';
    await store.setZoneSource('vod', 'missav');
    expect(store.zoneSource('vod'), '');
    platform.failure = '';
    await store.setZoneSource('vod', 'missav');
    expect(store.zoneSource('vod'), 'missav');
  });
}
