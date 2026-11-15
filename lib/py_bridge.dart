import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';

class PyRuntimeStatus {
  const PyRuntimeStatus({
    required this.available,
    this.python = '',
    this.detail = '',
  });

  final bool available;
  final String python;
  final String detail;

  String get notReadyMessage =>
      'Python 运行时未就绪：当前安装包未包含可用的 CPython 运行时。'
      '该站已导入并可见，但需要使用带 Python 桥的安装包打开。'
      '${detail.isEmpty ? '' : '（$detail）'}';
}

class PyValidation {
  const PyValidation({
    required this.ok,
    required this.hasSpider,
    required this.missing,
    required this.error,
  });

  final bool ok;
  final bool hasSpider;
  final List<String> missing;
  final String error;

  factory PyValidation.fromJson(Map<String, dynamic> json) => PyValidation(
    ok: json['ok'] == true,
    hasSpider: json['hasSpider'] == true,
    missing: (json['missing'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(),
    error: json['error'] as String? ?? '',
  );
}

class PyBridge {
  PyBridge._();

  static const _channel = MethodChannel('moyi/pybridge');

  /// 状态探测超时：callRaw 的 70 秒超时只包住 'call' 调用，包不住
  /// 前面的 ensureReady→status 探测；探测卡住时整个 py 调用永久挂起。
  /// 现探测本身 10 秒封顶，超时按“不可用”回。
  static const probeTimeout = Duration(seconds: 10);

  /// 校验调用超时：原先 validate 的通道调用不挂超时。
  static const validateTimeout = Duration(seconds: 30);

  /// “不可用”结果短缓存：原先只有可用结果进缓存，不可用时每次调用
  /// 都重新探测——全局搜索扇出几十个 py 站就是几十次重复探测。
  /// 不可用结果缓存 5 秒，force 可绕过。
  static const negativeStatusTtl = Duration(seconds: 5);

  static PyRuntimeStatus? _statusCache;
  static DateTime? _statusCachedAt;
  static Future<PyRuntimeStatus>? _statusInflight;
  static Future<PyRuntimeStatus> Function()? _testProbe;
  static Duration? _testTimeout;
  static DateTime Function()? _testClock;

  static Duration get _effectiveProbeTimeout =>
      _testTimeout ?? probeTimeout;
  static Duration get _effectiveValidateTimeout =>
      _testTimeout ?? validateTimeout;
  static DateTime _now() => _testClock?.call() ?? DateTime.now();

  /// 测试缝：覆盖状态探测实现（传 null 恢复真实探测）。
  @visibleForTesting
  static void setTestProbe(Future<PyRuntimeStatus> Function()? probe) {
    _testProbe = probe;
  }

  /// 测试缝：覆盖探测/校验超时（传 null 恢复默认）。
  @visibleForTesting
  static void setTestTimeout(Duration? timeout) => _testTimeout = timeout;

  /// 测试缝：覆盖时钟（传 null 恢复真实时钟），供失败缓存 TTL 测试。
  @visibleForTesting
  static void setTestClock(DateTime Function()? clock) => _testClock = clock;

  /// 测试缝：清状态缓存与在途探测，供测试隔离。
  @visibleForTesting
  static void clearTestStatus() {
    _statusCache = null;
    _statusCachedAt = null;
    _statusInflight = null;
  }

  static Future<PyRuntimeStatus> status({bool force = false}) async {
    if (!force && _statusCache != null && _statusCachedAt != null) {
      final cached = _statusCache!;
      final fresh =
          cached.available ||
          _now().difference(_statusCachedAt!) < negativeStatusTtl;
      if (fresh) return cached;
    }
    // 在途去重：并发的 status() 只发一次探测，后到的等同一单。
    // force 跳过缓存读，但同样复用在途探测（探测结果本就是现取的）。
    final inflight = _statusInflight;
    if (inflight != null) return inflight;
    final future = _probeBounded();
    _statusInflight = future;
    try {
      final result = await future;
      _statusCache = result;
      _statusCachedAt = _now();
      return result;
    } finally {
      if (identical(_statusInflight, future)) _statusInflight = null;
    }
  }

  static Future<PyRuntimeStatus> _probeBounded() async {
    try {
      return await _probe().timeout(
        _effectiveProbeTimeout,
        onTimeout: () => const PyRuntimeStatus(
          available: false,
          detail: '桥状态探测超时',
        ),
      );
    } catch (error) {
      return PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  static Future<PyRuntimeStatus> _probe() async {
    final override = _testProbe;
    if (override != null) return override();
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const PyRuntimeStatus(
        available: false,
        detail: '非 Android/iOS 平台',
      );
    }
    try {
      final raw = await _channel.invokeMethod<String>('status');
      final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      if (decoded['available'] == true) {
        return PyRuntimeStatus(
          available: true,
          python: decoded['python'] as String? ?? '',
        );
      }
      return const PyRuntimeStatus(available: false, detail: '桥未报告可用');
    } on MissingPluginException {
      return const PyRuntimeStatus(available: false, detail: '安装包未集成 Python 桥');
    } on PlatformException catch (error) {
      return PyRuntimeStatus(
        available: false,
        detail: error.message ?? '桥启动失败',
      );
    } catch (error) {
      return PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  static Future<void> ensureReady() async {
    final status = await PyBridge.status();
    if (!status.available) throw AppFailure(status.notReadyMessage);
  }

  static Future<PyValidation?> validate(String source) async {
    final status = await PyBridge.status();
    if (!status.available) return null;
    try {
      final raw = await _channel
          .invokeMethod<String>('validate', {'source': source})
          .timeout(_effectiveValidateTimeout);
      return PyValidation.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map),
      );
    } on TimeoutException {
      throw AppFailure('蜘蛛校验超时，请重试');
    } on PlatformException catch (error) {
      throw AppFailure('蜘蛛校验失败：${error.message ?? error.code}');
    }
  }

  static Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> request,
  ) async {
    final data = await callRaw(path, request);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static Future<dynamic> callRaw(
    String path,
    Map<String, dynamic> request,
  ) async {
    await ensureReady();
    final action = request['action']?.toString() ?? '';
    try {
      final raw = await _channel
          .invokeMethod<String>('call', {
            'path': path,
            'request': jsonEncode(request),
          })
          .timeout(const Duration(seconds: 70));
      final decoded = Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
      if (decoded['ok'] != true) {
        throw AppFailure(
          'py 蜘蛛执行失败（步骤=$path/$action）：${decoded['error'] ?? '未知错误'}',
        );
      }
      return decoded['data'];
    } on TimeoutException {
      unawaited(dispose(path));
      throw AppFailure(
        'py 蜘蛛执行超时（70 秒，步骤=$path/$action）：蜘蛛可能在等上游响应，请重试或换集',
      );
    } on PlatformException catch (error) {
      throw AppFailure(
        'py 蜘蛛执行失败（步骤=$path/$action）：${error.message ?? error.code}',
      );
    }
  }

  static Future<void> setCfDisguise(bool enabled) async {
    try {
      await callRaw('', {'action': 'setCfDisguise', 'enabled': enabled});
    } catch (_) {}
  }

  static Future<void> dispose(String path) async {
    try {
      await _channel.invokeMethod<String>('dispose', {'path': path});
    } catch (_) {}
  }

  static Future<void> disposeAll() async {
    try {
      await _channel.invokeMethod<String>('disposeAll');
    } catch (_) {}
  }
}
