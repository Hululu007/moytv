import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/source_fanout.dart';

void main() {
  group('fanoutOrdered', () {
    test('空输入直接回空，不调 worker', () async {
      var calls = 0;
      final result = await fanoutOrdered<int, int>(const [], (input) async {
        calls++;
        return input;
      });
      expect(result, isEmpty);
      expect(calls, 0);
    });

    test('结果按输入顺序，与完成顺序无关', () async {
      final result = await fanoutOrdered<int, int>([1, 2, 3, 4], (input) async {
        // 后面的反而先完成：延迟递减。
        await Future<void>.delayed(Duration(milliseconds: 60 - input * 10));
        return input * 10;
      }, concurrency: 4);
      expect(result, [10, 20, 30, 40]);
    });

    test('在途数不超过并发上限', () async {
      var inflight = 0;
      var peak = 0;
      await fanoutOrdered<int, int>(
        List<int>.generate(12, (i) => i),
        (input) async {
          inflight++;
          if (inflight > peak) peak = inflight;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          inflight--;
          return input;
        },
        concurrency: 3,
      );
      expect(peak, 3);
    });

    test('并发上限大于输入数时全部并行', () async {
      var inflight = 0;
      var peak = 0;
      await fanoutOrdered<int, int>([1, 2], (input) async {
        inflight++;
        if (inflight > peak) peak = inflight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inflight--;
        return input;
      }, concurrency: 6);
      expect(peak, 2);
    });

    test('并发上限小于 1 时按 1 跑（串行）', () async {
      var inflight = 0;
      var peak = 0;
      final result = await fanoutOrdered<int, int>([1, 2, 3], (input) async {
        inflight++;
        if (inflight > peak) peak = inflight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inflight--;
        return input;
      }, concurrency: 0);
      expect(result, [1, 2, 3]);
      expect(peak, 1);
    });

    test('worker 抛错向上传播', () async {
      await expectLater(
        fanoutOrdered<int, int>([1, 2], (input) async {
          if (input == 2) throw StateError('boom');
          return input;
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('shouldStop 一开始就真：一个任务不跑，正常回空', () async {
      var calls = 0;
      final result = await fanoutOrdered<int, int>([1, 2, 3], (input) async {
        calls++;
        return input;
      }, shouldStop: () => true);
      expect(result, isEmpty);
      expect(calls, 0);
    });

    test('shouldStop 中途翻真：只回已完成的结果（按输入顺序），不挂起', () async {
      var finished = 0;
      final result = await fanoutOrdered<int, int>(
        [1, 2, 3, 4, 5],
        (input) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          finished++;
          return input * 10;
        },
        concurrency: 1,
        shouldStop: () => finished >= 2,
      );
      expect(result, [10, 20]);
      expect(finished, 2);
    });
  });

  group('fanoutEach shouldStop', () {
    test('停了不再发起后续任务，已完成的照常回调，Future 正常完成', () async {
      var started = 0;
      var stopped = false;
      final seen = <int>[];
      await fanoutEach<int, int>(
        [1, 2, 3, 4, 5],
        (input) async {
          started++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return input * 10;
        },
        onResult: (_, result) {
          seen.add(result);
          if (seen.length == 2) stopped = true;
        },
        concurrency: 1,
        shouldStop: () => stopped,
      );
      expect(seen, [10, 20]);
      expect(started, 2);
    });

    test('shouldStop 一开始就真：一个任务不跑，一次回调没有', () async {
      var calls = 0;
      var callbacks = 0;
      await fanoutEach<int, int>(
        [1, 2, 3],
        (input) async {
          calls++;
          return input;
        },
        onResult: (_, _) => callbacks++,
        shouldStop: () => true,
      );
      expect(calls, 0);
      expect(callbacks, 0);
    });

    test('多路并发下停了也不挂起，未取的任务不启动', () async {
      var started = 0;
      var stop = false;
      // 120ms 后喊停：50ms 一波、2 路，停时约 6 个已取，剩下不启动。
      Future<void>.delayed(const Duration(milliseconds: 120)).then((_) {
        stop = true;
      });
      await fanoutEach<int, int>(
        List<int>.generate(10, (i) => i),
        (input) async {
          started++;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return input;
        },
        onResult: (_, _) {},
        concurrency: 2,
        shouldStop: () => stop,
      ).timeout(const Duration(seconds: 5));
      expect(started, lessThan(10));
      expect(started, greaterThan(0));
    });
  });
}
