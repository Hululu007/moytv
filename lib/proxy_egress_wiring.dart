import 'dart:async';

import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'proxy_egress.dart';
import 'py_bridge.dart';
import 'socks5_proxy.dart';

/// 出口决策点的接线层：把决策变化同步给各消费方，并把各档输入喂给决策点。
///
/// 决策变化时同步三处（全部 fire-and-forget，失败不阻塞界面）：
/// - Go 核：`repository.setEgressProxy(decision.goUrl)`；
/// - py 运行时：`PyBridge.setEgressProxy(decision.httpProxyUrl)`；
/// - 原生层（JVM 默认 ProxySelector + ijk 静态地址）：`moyi/device` 通道。
///
/// Dart HttpClient 与封面图不需要这里同步——全局 `HttpOverrides` 直接读
/// 决策；MPV 由决策点内的应用器登记表直接调用；海阔规则自带 proxy 优先
/// 于全局，由 runner 页自己的客户端处理。
///
/// 输入 feeding：
/// - 内核档：`ProxyKernelService` 启停时经 `ProxyKernelTraffic` 写决策点；
/// - SOCKS5 档：`Socks5ProxyRouter.onUpdated` 钩子触发刷新；
/// - 手填档：`NativeRepository.saveResourceSettings` 保存后刷新，
///   这里绑定时读一次存量设置；
/// - 系统档：`SystemProxyMonitor` 回调里刷新（见 `core_bridge.dart`）。
class ProxyEgressWiring {
  ProxyEgressWiring._();

  static const _deviceChannel = MethodChannel('moyi/device');

  static bool _bound = false;
  static AppRepository? _repository;
  static Future<void> Function(String? goUrl)? _goSink;
  static Future<void> Function(String? httpProxyUrl)? _pySink;
  static Future<void> Function(String? httpProxyUrl)? _nativeSink;
  static bool _pyEgressActive = false;
  static EgressDecision? _lastSynced;
  static Future<void> _syncChain = Future.value();

  /// 绑定接线（幂等）：挂 SOCKS5 钩子、监听决策变化、做一次初始同步。
  /// 在 `main.dart` 里 `repository.initialize()` 之后、内核自启之前调用。
  /// 各 sink 参数只给测试用，生产走默认实现。
  static Future<void> bind({
    required AppRepository repository,
    Future<void> Function(String? goUrl)? goSink,
    Future<void> Function(String? httpProxyUrl)? pySink,
    Future<void> Function(String? httpProxyUrl)? nativeSink,
  }) async {
    if (_bound) return;
    _bound = true;
    _repository = repository;
    _goSink = goSink;
    _pySink = pySink;
    _nativeSink = nativeSink;
    Socks5ProxyRouter.onUpdated = () {
      unawaited(ProxyEgressController.instance.refreshSocks5Egress());
    };
    ProxyEgressController.instance.decisionNotifier.addListener(
      _onDecisionChanged,
    );
    // 初始输入：手填档读存量资源设置，SOCKS5 档读当前路由快照。
    // 系统档由 SystemProxyMonitor 回调喂，内核档由启停写，这里不重复读。
    try {
      final settings = await repository.resourceSettings();
      await ProxyEgressController.instance.refreshManualEgress(
        settings.proxyMode,
        settings.proxyUrl,
      );
    } catch (_) {}
    await ProxyEgressController.instance.refreshSocks5Egress();
    await _sync(ProxyEgressController.instance.decision);
  }

  /// 只给测试用：拆掉绑定、恢复初始状态。
  static void resetForTest() {
    if (_bound) {
      ProxyEgressController.instance.decisionNotifier.removeListener(
        _onDecisionChanged,
      );
    }
    Socks5ProxyRouter.onUpdated = null;
    _bound = false;
    _repository = null;
    _goSink = null;
    _pySink = null;
    _nativeSink = null;
    _pyEgressActive = false;
    _lastSynced = null;
    _syncChain = Future.value();
  }

  static void _onDecisionChanged() {
    unawaited(_sync(ProxyEgressController.instance.decision));
  }

  /// 同步串行化：决策快速连变时（内核连点启停），各消费方按决策
  /// 产生顺序依次收到同步，最后生效的永远是最新的决策，不会乱序。
  static Future<void> _sync(EgressDecision decision) {
    final run = _syncChain.then((_) => _syncNow(decision));
    _syncChain = run.catchError((Object _) {});
    return run;
  }

  static Future<void> _syncNow(EgressDecision decision) async {
    if (decision == _lastSynced) return;
    _lastSynced = decision;
    // Go 核：goUrl 为 null 时清覆盖，恢复用户保存的资源设置。
    try {
      final sink = _goSink;
      if (sink != null) {
        await sink(decision.goUrl);
      } else {
        await _repository?.setEgressProxy(decision.goUrl);
      }
    } catch (_) {}
    // py：从未推过非空出口且当前是直连时不调用，避免无意义地
    // 启动 Python 解释器（全新解释器默认就是直连）。
    try {
      if (decision.httpProxyUrl != null || _pyEgressActive) {
        _pyEgressActive = decision.httpProxyUrl != null;
        final sink = _pySink;
        if (sink != null) {
          await sink(decision.httpProxyUrl);
        } else {
          await PyBridge.setEgressProxy(decision.httpProxyUrl);
        }
      }
    } catch (_) {}
    // 原生层：JVM 选择器与 ijk 静态地址。非 Android 平台无此方法，
    // MissingPluginException 直接吞掉（本机无 JVM/ijk 可配）。
    try {
      final sink = _nativeSink;
      if (sink != null) {
        await sink(decision.httpProxyUrl);
      } else if (decision.httpProxyUrl == null) {
        await _deviceChannel.invokeMethod('clearEgressProxy');
      } else {
        await _deviceChannel.invokeMethod('setEgressProxy', {
          'proxyUrl': decision.httpProxyUrl,
        });
      }
    } catch (_) {}
  }
}
