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
  });
}
