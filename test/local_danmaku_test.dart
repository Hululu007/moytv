import 'dart:convert';

import 'package:moyi/danmaku_controller.dart';
import 'package:moyi/local_danmaku_store.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'danmaku_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local danmaku store round-trips and clears', () async {
    SharedPreferences.setMockInitialValues({});
    await LocalDanmakuStore.add(
      'dm:1001',
      const LocalDanmakuEntry(text: 'hello', timeMs: 5000),
    );
    await LocalDanmakuStore.add(
      'dm:1001',
      const LocalDanmakuEntry(text: 'world', timeMs: 9000),
    );
    final loaded = await LocalDanmakuStore.load('dm:1001');
    expect(loaded.map((entry) => entry.text), ['hello', 'world']);
    expect(loaded.map((entry) => entry.timeMs), [5000, 9000]);
    expect(await LocalDanmakuStore.load('dm:other'), isEmpty);
    await LocalDanmakuStore.clear('dm:1001');
    expect(await LocalDanmakuStore.load('dm:1001'), isEmpty);
  });

  test('local playback shows stored local danmaku without remote', () async {
    SharedPreferences.setMockInitialValues({
      LocalDanmakuStore.keyFor('local:/sdcard/movie.mp4'): jsonEncode([
        {'text': 'offline one', 'timeMs': 2000},
      ]),
    });
    final repository = DanmakuFixtureRepository();
    final controller = DanmakuController(repository)
      ..setPlan(
        const PlaybackPlan(url: '/sdcard/movie.mp4', local: true),
      );
    for (var i = 0; i < 8; i++) {
      await Future<void>.value();
    }
    expect(controller.canSendLocal, isTrue);
    expect(controller.visible, isFalse);
    expect(controller.items.map((item) => item.text), contains('offline one'));
    controller.update(
      position: const Duration(milliseconds: 3000),
      duration: const Duration(milliseconds: 60000),
      speed: 1,
      playing: true,
      buffering: false,
      foreground: true,
      available: true,
    );
    expect(controller.localVisible, isTrue);
    expect(controller.anyVisible, isTrue);
    expect(controller.anyMoving, isTrue);
    expect(controller.status, '本地弹幕 1 条');
    expect(repository.danmakuCalls, isEmpty);
    controller.dispose();
  });

  test('controller merges stored local danmaku and sends new ones', () async {
    SharedPreferences.setMockInitialValues({
      LocalDanmakuStore.keyFor('dm:1001'): jsonEncode([
        {'text': 'stored one', 'timeMs': 3000},
      ]),
    });
    final controller = DanmakuController(DanmakuFixtureRepository())
      ..setPlan(
        const PlaybackPlan(
          url: 'https://media.example.test/s.mp4',
          session: 'current',
          danmakuId: '1001',
        ),
      );
    for (var i = 0; i < 8; i++) {
      await Future<void>.value();
    }
    expect(
      controller.items.map((item) => item.text),
      contains('stored one'),
    );
    await controller.sendLocal('  fresh  ');
    expect(controller.items.map((item) => item.text), contains('fresh'));
    final stored = await LocalDanmakuStore.load('dm:1001');
    expect(stored.map((entry) => entry.text), ['stored one', 'fresh']);
    await controller.clearLocal();
    expect(
      controller.items.map((item) => item.text),
      isNot(contains('fresh')),
    );
    expect(await LocalDanmakuStore.load('dm:1001'), isEmpty);
    controller.dispose();
  });
}
