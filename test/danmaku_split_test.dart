import 'package:moyi/danmaku_loader.dart';
import 'package:moyi/danmaku_models.dart';
import 'package:moyi/danmaku_time_sync.dart';
import 'package:moyi/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('time sync holds position when not moving', () {
    var now = DateTime(2026, 10, 27, 12, 0, 0);
    final sync = DanmakuTimeSync(now: () => now);
    sync.reset(positionMs: 5000, rate: 1, moving: false);
    now = now.add(const Duration(seconds: 30));
    expect(sync.expectedPosition(), 5000);
  });

  test('time sync advances with rate while moving', () {
    var now = DateTime(2026, 10, 27, 12, 0, 0);
    final sync = DanmakuTimeSync(now: () => now);
    sync.reset(positionMs: 10000, rate: 2, moving: true);
    now = now.add(const Duration(seconds: 3));
    expect(sync.expectedPosition(), 16000);
  });

  test('loader loads the covering window and reuses it', () async {
    var loads = 0;
    var position = 0;
    var moving = false;
    const duration = 3600000;
    final plan = PlaybackPlan(
      url: 'https://example.test/video.mp4',
      headers: const {},
      session: 's1',
      danmakuId: 'ep1',
    );
    final itemsSeen = <DanmakuItem>[];
    final loader = DanmakuLoader(
      state: () => DanmakuWindowState(
        visible: true,
        buffering: false,
        positionMs: position,
        moving: moving,
        durationMs: duration,
        plan: plan,
      ),
      loadPage: (loadedPlan, start, durationMs) async {
        loads++;
        expect(loadedPlan, plan);
        expect(durationMs, duration);
        return DanmakuPage(
          episodeId: 'ep1',
          startMs: start,
          nextMs: start + danmakuWindowMs,
          items: [DanmakuItem(id: 'd$start', text: 'hi', timeMs: start + 100)],
        );
      },
      cancelLoad: () async {},
      onItems: (list) {
        itemsSeen
          ..clear()
          ..addAll(list);
      },
      onChanged: () {},
    );
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
    expect(itemsSeen.map((item) => item.id), ['d0']);
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
    moving = true;
    position = danmakuWindowMs - 1000;
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 2);
    expect(itemsSeen.map((item) => item.id), ['d0', 'd30000']);
  });

  test('loader keeps six nearest pages and backs off after failure', () async {
    var now = DateTime(2026, 10, 27, 12, 0, 0);
    var position = 0;
    var loads = 0;
    var failOnce = true;
    const duration = 3600000;
    final plan = PlaybackPlan(
      url: 'https://example.test/video.mp4',
      headers: const {},
      session: 's1',
      danmakuId: 'ep1',
    );
    var pageCount = 0;
    final loader = DanmakuLoader(
      now: () => now,
      state: () => DanmakuWindowState(
        visible: true,
        buffering: false,
        positionMs: position,
        moving: true,
        durationMs: duration,
        plan: plan,
      ),
      loadPage: (loadedPlan, start, durationMs) async {
        loads++;
        if (failOnce) {
          failOnce = false;
          throw Exception('network down');
        }
        pageCount++;
        return DanmakuPage(
          episodeId: 'ep1',
          startMs: start,
          nextMs: start + danmakuWindowMs,
          items: const [],
        );
      },
      cancelLoad: () async {},
      onItems: (_) {},
      onChanged: () {},
    );
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
    expect(loader.hasFailures, isTrue);
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
    now = now.add(const Duration(seconds: 16));
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    expect(loads, 2);
    expect(loader.hasFailures, isFalse);
    for (var step = 0; step < 7; step++) {
      position = (step + 1) * danmakuWindowMs - 1000;
      loader.ensureWindow();
      await Future<void>.delayed(Duration.zero);
    }
    expect(pageCount, 8);
    var retained = 0;
    position = 0;
    loader.ensureWindow();
    await Future<void>.delayed(Duration.zero);
    retained = loads;
    expect(retained, 10);
  });
}
