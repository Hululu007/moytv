import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'socks5_proxy.dart';

/// 代理出口的唯一决策点：全应用所有流量共用一条优先级链。
///
/// 优先级（高到低）：代理内核运行中 > 已启用的 SOCKS5 条目 >
/// 资源设置手填地址 > 手机系统代理 > 直连。
///
/// 决策只产生两样东西：给 Dart/播放器/JVM 用的 HTTP 代理地址
/// [EgressDecision.httpProxy]（`host:port`），以及给 Go 核用的完整地址
/// [EgressDecision.goUrl]。SOCKS5 类型的地址一律先过本机 HTTP 转发器，
/// 因为 Dart 的 `HttpClient.findProxy` 只认 `PROXY`/`DIRECT`，不认 SOCKS。
/// 回环目标（127.0.0.1/localhost/::1）永远直连，不进任何出口。
enum EgressSource { kernel, socks5, manual, system, direct }

/// 一次出口决策：不可变，相等比较按字段。
class EgressDecision {
  const EgressDecision({
    required this.source,
    required this.label,
    this.httpProxy,
    this.goUrl,
  });

  /// 出口来源。
  final EgressSource source;

  /// HTTP 代理地址（`host:port`），直连时为 null。
  /// 所有 HTTP 语义的消费方（Dart HttpClient、Exo、ijk、MPV、JVM）都用它；
  /// SOCKS5 来源时这里是本机转发器的回环地址，不是 SOCKS5 原地址。
  final String? httpProxy;

  /// 给 Go 核的完整代理地址；直连与系统代理时为 null（系统代理档 Go 核
  /// 走自身的 auto 模式自己读系统设置，不需要覆盖地址）。
  final String? goUrl;

  /// 给设置页展示的中文说明，不含任何凭证。
  final String label;

  /// `http://host:port` 形式，供 MPV/ijk 这类要完整 URL 的消费方。
  String? get httpProxyUrl => httpProxy == null ? null : 'http://$httpProxy';

  bool get isDirect => source == EgressSource.direct;

  /// Dart `HttpClient.findProxy` 语义：回环目标永远直连。
  String findProxy(Uri uri) {
    if (proxyEgressIsLoopback(uri)) return 'DIRECT';
    final address = httpProxy;
    if (address == null) return 'DIRECT';
    return 'PROXY $address';
  }

  @override
  bool operator ==(Object other) =>
      other is EgressDecision &&
      other.source == source &&
      other.httpProxy == httpProxy &&
      other.goUrl == goUrl &&
      other.label == label;

  @override
  int get hashCode => Object.hash(source, httpProxy, goUrl, label);

  @override
  String toString() => 'EgressDecision($source, $label)';
}

/// 目标地址是不是回环地址（本机服务、内核控制接口、转发器都走这里直连）。
bool proxyEgressIsLoopback(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '::1' || host == '[::1]') return true;
  final parsed = InternetAddress.tryParse(uri.host);
  return parsed?.isLoopback ?? false;
}

/// 纯决策函数：给定各档已解析好的地址，按优先级链算出唯一决策。
/// 各档地址由调用方事先解析好（SOCKS5 档与手填 SOCKS5 档需先起转发器，
/// 那是异步活，不放在这个纯函数里）。
EgressDecision resolveEgressDecision({
  String? kernelHttpAddress,
  String? socks5HttpAddress,
  String? manualHttpAddress,
  String? manualGoUrl,
  String? systemHttpAddress,
}) {
  if (kernelHttpAddress != null && kernelHttpAddress.isNotEmpty) {
    return EgressDecision(
      source: EgressSource.kernel,
      httpProxy: kernelHttpAddress,
      goUrl: 'http://$kernelHttpAddress',
      label: '代理内核 $kernelHttpAddress',
    );
  }
  if (socks5HttpAddress != null && socks5HttpAddress.isNotEmpty) {
    return EgressDecision(
      source: EgressSource.socks5,
      httpProxy: socks5HttpAddress,
      goUrl: 'http://$socks5HttpAddress',
      label: 'SOCKS5 转发 $socks5HttpAddress',
    );
  }
  if (manualHttpAddress != null && manualHttpAddress.isNotEmpty) {
    return EgressDecision(
      source: EgressSource.manual,
      httpProxy: manualHttpAddress,
      goUrl: manualGoUrl ?? 'http://$manualHttpAddress',
      label: '手填地址 $manualHttpAddress',
    );
  }
  if (systemHttpAddress != null && systemHttpAddress.isNotEmpty) {
    return EgressDecision(
      source: EgressSource.system,
      httpProxy: systemHttpAddress,
      label: '系统代理 $systemHttpAddress',
    );
  }
  return const EgressDecision(source: EgressSource.direct, label: '直连');
}

/// 出口决策控制器：持有各档输入，任一档变化就重算决策并通知。
///
/// 单例 [instance] 是运行时的唯一决策点；构造器公开只为单元测试。
/// 决策变化时两件事自动发生：[decisionNotifier] 通知监听者（设置页、
/// 接线层），以及已登记的 MPV 应用器被调用（播放器配置同步刷新）。
class ProxyEgressController {
  ProxyEgressController();

  static final ProxyEgressController instance = ProxyEgressController();

  /// 只给测试用：清掉单例的全部输入与登记，回到直连。
  static void resetForTest() => instance._reset();

  final ValueNotifier<EgressDecision> decisionNotifier = ValueNotifier(
    const EgressDecision(source: EgressSource.direct, label: '直连'),
  );

  EgressDecision get decision => decisionNotifier.value;

  String? _kernelAddress;
  String? _socks5Address;
  String? _manualHttpAddress;
  String? _manualGoUrl;
  String? _systemAddress;

  int _socks5Generation = 0;
  int _manualGeneration = 0;

  final Map<Object, Future<void> Function(String?)> _mpvAppliers = {};

  void _reset() {
    _socks5Generation++;
    _manualGeneration++;
    _kernelAddress = null;
    _socks5Address = null;
    _manualHttpAddress = null;
    _manualGoUrl = null;
    _systemAddress = null;
    _mpvAppliers.clear();
    decisionNotifier.value = const EgressDecision(
      source: EgressSource.direct,
      label: '直连',
    );
  }

  /// 内核档：内核启动时传 `127.0.0.1:端口`，停止时传 null。
  /// 停止后决策自动落到链上下一档，绝不留死地址。
  void setKernelAddress(String? address) {
    if (_kernelAddress == address) return;
    _kernelAddress = address;
    _recompute();
  }

  /// SOCKS5 档：本机转发器地址，传 null 表示无可用条目。
  void setSocks5Address(String? address) {
    if (_socks5Address == address) return;
    _socks5Address = address;
    _recompute();
  }

  /// 手填档：[httpAddress] 是 HTTP 语义地址（手填 SOCKS5 时为转发器地址），
  /// [goUrl] 是给 Go 核的原始完整地址。
  void setManual({String? httpAddress, String? goUrl}) {
    if (_manualHttpAddress == httpAddress && _manualGoUrl == goUrl) return;
    _manualHttpAddress = httpAddress;
    _manualGoUrl = goUrl;
    _recompute();
  }

  /// 系统代理档：`host:port`，无系统代理时传 null。
  void setSystemAddress(String? address) {
    if (_systemAddress == address) return;
    _systemAddress = address;
    _recompute();
  }

  void _recompute() {
    final next = resolveEgressDecision(
      kernelHttpAddress: _kernelAddress,
      socks5HttpAddress: _socks5Address,
      manualHttpAddress: _manualHttpAddress,
      manualGoUrl: _manualGoUrl,
      systemHttpAddress: _systemAddress,
    );
    if (next == decisionNotifier.value) return;
    decisionNotifier.value = next;
    _applyMpvAppliers(next);
  }

  /// 刷新 SOCKS5 档：取存储顺序里第一个已启用的条目，起转发器。
  /// 无可用条目或转发器起不来时，该档视为空（落到下一档）。
  Future<void> refreshSocks5Egress() async {
    final generation = ++_socks5Generation;
    Socks5ProxyEntry? entry;
    for (final candidate in Socks5ProxyRouter.instance.proxies) {
      if (candidate.enabled) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      if (generation == _socks5Generation) setSocks5Address(null);
      return;
    }
    try {
      final port = await Socks5ForwarderPool.instance.ensurePort(entry);
      if (generation != _socks5Generation) return;
      setSocks5Address('127.0.0.1:$port');
    } catch (_) {
      if (generation == _socks5Generation) setSocks5Address(null);
    }
  }

  /// 刷新手填档：解析资源设置里的模式与地址。
  /// http/https 地址直接用；socks5/socks5h 地址起转发器给 Dart 侧用，
  /// Go 核仍拿原始 SOCKS5 地址（Go 自己会说 SOCKS5）。
  /// 模式不是 manual、地址为空/非法、转发器起不来时，该档视为空。
  Future<void> refreshManualEgress(String? mode, String? url) async {
    final generation = ++_manualGeneration;
    void clear() {
      if (generation == _manualGeneration) {
        setManual(httpAddress: null, goUrl: null);
      }
    }

    final trimmed = (url ?? '').trim();
    if (mode != 'manual' || trimmed.isEmpty) {
      clear();
      return;
    }
    final parsed = Uri.tryParse(trimmed);
    final scheme = parsed?.scheme.toLowerCase() ?? '';
    if (parsed == null ||
        parsed.host.isEmpty ||
        !const {'http', 'https', 'socks5', 'socks5h'}.contains(scheme)) {
      clear();
      return;
    }
    final port = parsed.hasPort
        ? parsed.port
        : (scheme == 'http'
              ? 80
              : scheme == 'https'
              ? 443
              : 1080);
    if (port <= 0 || port > 65535) {
      clear();
      return;
    }
    if (scheme == 'http' || scheme == 'https') {
      if (generation == _manualGeneration) {
        setManual(httpAddress: '${parsed.host}:$port', goUrl: trimmed);
      }
      return;
    }
    final userInfo = parsed.userInfo;
    var username = '';
    var password = '';
    if (userInfo.isNotEmpty) {
      final colon = userInfo.indexOf(':');
      if (colon < 0) {
        username = Uri.decodeComponent(userInfo);
      } else {
        username = Uri.decodeComponent(userInfo.substring(0, colon));
        password = Uri.decodeComponent(userInfo.substring(colon + 1));
      }
    }
    final entry = Socks5ProxyEntry(
      id: 'egress-manual',
      name: 'manual',
      host: parsed.host,
      port: port,
      username: username,
      password: password,
    );
    try {
      final forwarderPort = await Socks5ForwarderPool.instance.ensurePort(
        entry,
      );
      if (generation != _manualGeneration) return;
      setManual(httpAddress: '127.0.0.1:$forwarderPort', goUrl: trimmed);
    } catch (_) {
      clear();
    }
  }

  /// 登记一个 MPV 播放器应用器：决策变化时以新出口地址调用它
  ///（直连时传 null）。应用器抛错会被摘掉，不再重复调用。
  void registerMpvApplier(
    Object key,
    Future<void> Function(String? httpProxyUrl) apply,
  ) {
    _mpvAppliers[key] = apply;
  }

  void unregisterMpvApplier(Object key) => _mpvAppliers.remove(key);

  void _applyMpvAppliers(EgressDecision next) {
    final url = next.httpProxyUrl;
    for (final entry in _mpvAppliers.entries.toList()) {
      unawaited(
        Future(() => entry.value(url)).catchError((Object _) {
          _mpvAppliers.remove(entry.key);
        }),
      );
    }
  }
}

/// 从 `moyi/device` 通道 `systemProxy` 方法返回的映射里取出静态系统代理
/// 地址（`host:port`）。只有 http/https 静态地址算数；纯 PAC（无静态地址）
/// 时返回 null——系统代理档不跟 PAC 脚本走，Go 核 auto 模式自己报 PAC 状态。
String? systemProxyAddressFromMap(Map<String, dynamic> value) {
  for (final key in const ['http', 'https']) {
    final raw = value[key];
    if (raw is! String || raw.isEmpty) continue;
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty || !parsed.hasPort) continue;
    if (parsed.port <= 0 || parsed.port > 65535) continue;
    return '${parsed.host}:${parsed.port}';
  }
  return null;
}

/// 全局 HTTP 覆盖：所有未显式指定 `findProxy` 的 `HttpClient()` 默认
/// 走出口决策。显式指定过的客户端（规则自带 proxy、海阔转发客户端、
/// DIRECT 专用客户端、控制面直连客户端）不受影响——显式赋值会覆盖
/// 这里的默认值，优先级高于全局。
///
/// 注意：这里必须用 `super.createHttpClient`，直接 `HttpClient()` 会
/// 递归进本覆盖造成无限循环。
class ProxyEgressHttpOverrides extends HttpOverrides {
  ProxyEgressHttpOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy =
        (uri) => ProxyEgressController.instance.decision.findProxy(uri);
    return client;
  }
}
