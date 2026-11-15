import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyi/core_bridge.dart';
import 'package:moyi/py_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('moyi/pybridge');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    PyBridge.setTestProbe(null);
    PyBridge.setTestTimeout(null);
    PyBridge.setTestClock(null);
    PyBridge.clearTestStatus();
  });

  group('PyBridge.status', () {
    test('并发探测只发一次', () async {
      var probes = 0;
      PyBridge.setTestProbe(() async {
        probes++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return const PyRuntimeStatus(available: true, python: '3.13');
      });
      final results = await Future.wait([
        PyBridge.status(),
        PyBridge.status(),
        PyBridge.status(),
      ]);
      expect(probes, 1);
      expect(results.every((s) => s.available), isTrue);
    });

    test('可用结果永久缓存，不再探测', () async {
      var probes = 0;
      PyBridge.setTestProbe(() async {
        probes++;
        return const PyRuntimeStatus(available: true, python: '3.13');
      });
      await PyBridge.status();
      await PyBridge.status();
      expect(probes, 1);
      // force 绕过缓存，重新探测。
      await PyBridge.status(force: true);
      expect(probes, 2);
    });

    test('不可用结果 5 秒内不重复探测，过期后重探', () async {
      var probes = 0;
      var now = DateTime(2026, 11, 15, 8);
      PyBridge.setTestClock(() => now);
      PyBridge.setTestProbe(() async {
        probes++;
        return const PyRuntimeStatus(available: false, detail: '桥未就绪');
      });
      await PyBridge.status();
      await PyBridge.status();
      expect(probes, 1);
      now = now.add(const Duration(seconds: 4));
      await PyBridge.status();
      expect(probes, 1);
      now = now.add(const Duration(seconds: 2));
      await PyBridge.status();
      expect(probes, 2);
    });

    test('探测卡住时 10 秒封顶报不可用，不永久挂起', () async {
      PyBridge.setTestTimeout(const Duration(milliseconds: 100));
      PyBridge.setTestProbe(() async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return const PyRuntimeStatus(available: true);
      });
      final watch = Stopwatch()..start();
      final status = await PyBridge.status();
      watch.stop();
      expect(status.available, isFalse);
      expect(status.detail, contains('超时'));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('探测抛错按不可用回，不向外抛', () async {
      PyBridge.setTestProbe(() async => throw StateError('boom'));
      final status = await PyBridge.status();
      expect(status.available, isFalse);
    });
  });

  group('PyBridge.validate', () {
    test('运行时不可用时直接回 null，不调通道', () async {
      var channelCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        channelCalls++;
        return '{}';
      });
      PyBridge.setTestProbe(
        () async => const PyRuntimeStatus(available: false, detail: '无桥'),
      );
      expect(await PyBridge.validate('x'), isNull);
      expect(channelCalls, 0);
    });

    test('校验超时报 AppFailure', () async {
      PyBridge.setTestTimeout(const Duration(milliseconds: 100));
      PyBridge.setTestProbe(
        () async => const PyRuntimeStatus(available: true, python: '3.13'),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return jsonEncode({'ok': true, 'hasSpider': true});
      });
      await expectLater(
        PyBridge.validate('class Spider: pass'),
        throwsA(isA<AppFailure>()),
      );
    });

    test('校验正常返回解析结果', () async {
      PyBridge.setTestProbe(
        () async => const PyRuntimeStatus(available: true, python: '3.13'),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'validate');
        return jsonEncode({
          'ok': true,
          'hasSpider': true,
          'missing': <String>[],
          'error': '',
        });
      });
      final result = await PyBridge.validate('class Spider: pass');
      expect(result, isNotNull);
      expect(result!.ok, isTrue);
      expect(result.hasSpider, isTrue);
    });
  });
}
