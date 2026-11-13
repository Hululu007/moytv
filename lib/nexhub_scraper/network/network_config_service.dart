// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/network/network_config_service.dart。
// 移植状态：改编——①魔蚁无 flutter_secure_storage，代理密码改存 SharedPreferences
// （安全性降级：原文存系统钥匙串，此处与魔蚁其他设置同级存放，见 _passwordKey 注）；
// ②HttpFetcher 未随本批移植，配置变更时不再重建其连接池（魔蚁的 ContentHttp 按需建
// 客户端、无共享连接池），变更通知改走既有的 effectiveConfigListeners 机制；
// ③effectiveFor 不再取 NexHub 的 PluginConfig，改为 sourceId + fileOverride 入参。
// 其余逻辑（档案合并、探测方法）与原文一致。本服务目前是独立服务，未接入魔蚁主链路。
/// 网络配置服务：全局网络配置的单例状态源 + 有效档案计算。
///
/// - 持有当前 [NetworkConfig] 与代理密码；
/// - `globalProfile` 缓存全局有效档案；
/// - `effectiveFor(sourceId)` 逐方面合并（用户覆盖 > 源文件 network 块 > 全局 > 默认）；
/// - 变更时清 DNS 缓存 + 通知订阅者，配置即时生效。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model/effective_network_profile.dart';
import 'model/network_config.dart';
import 'model/source_network_config.dart';
import 'runtime/dns_resolver.dart';
import 'runtime/network_client_builder.dart';
import 'runtime/sni_policy.dart';
import 'runtime/system_proxy_resolver.dart';
import 'source_network_override_store.dart';

/// 网络配置服务（ChangeNotifier 单例 + Provider）。
class NetworkConfigService extends ChangeNotifier {
  NetworkConfigService._();
  static final NetworkConfigService instance = NetworkConfigService._();

  static const String _prefsKey = 'network_config_v1';

  /// 魔蚁改编：原文用 flutter_secure_storage 存钥匙串；魔蚁无此依赖，改存
  /// SharedPreferences（与魔蚁其他设置同级存放，非加密存储）。
  static const String _passwordKey = 'network_proxy_password';

  NetworkConfig _config = NetworkConfig.defaults;
  String? _proxyPassword;
  bool _loaded = false;
  EffectiveNetworkProfile? _globalProfileCache;

  NetworkConfig get config => _config;
  String? get proxyPassword => _proxyPassword;
  bool get loaded => _loaded;

  /// 全局有效档案（缓存，配置变更时失效）。
  EffectiveNetworkProfile get globalProfile =>
      _globalProfileCache ??= EffectiveNetworkProfile.fromConfig(_config);

  /// 从持久化加载（幂等）。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        _config = NetworkConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      }
    } on Object catch (e) {
      debugPrint('NetworkConfigService.load config failed: $e');
      _config = NetworkConfig.defaults;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _proxyPassword = prefs.getString(_passwordKey);
    } on Object catch (e) {
      debugPrint('NetworkConfigService.load password failed: $e');
    }
    _loaded = true;
    _globalProfileCache = null;
    // 桌面「跟随系统代理」：异步探测一次（Windows 注册表），缓存后供
    // findProxy 同步回调使用；失败保持 DIRECT，不阻断启动。
    unawaited(SystemProxyResolver.refresh());
    notifyListeners();
  }

  /// 更新配置（可选更新代理密码）。
  Future<void> update(NetworkConfig config, {String? password}) async {
    _config = config;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
    } on Object catch (e) {
      debugPrint('NetworkConfigService.update persist failed: $e');
    }
    if (password != null) {
      _proxyPassword = password;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_passwordKey, password);
      } on Object catch (e) {
        debugPrint('NetworkConfigService.update password failed: $e');
      }
    }
    _onChanged();
  }

  /// 恢复默认网络设置。
  Future<void> resetToDefaults() async {
    _config = NetworkConfig.defaults;
    _proxyPassword = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
      await prefs.remove(_passwordKey);
    } on Object catch (e) {
      debugPrint('NetworkConfigService.resetToDefaults failed: $e');
    }
    _onChanged();
  }

  void _onChanged() {
    _loaded = true;
    _globalProfileCache = null;
    DnsResolver.instance.clearCache();
    // 魔蚁改编：原文此处重建 HttpFetcher 连接池；该类未移植，魔蚁抓取层按需建
    // 客户端，配置变更的即时生效改走 effectiveConfigListeners 通知。
    notifyListeners();
    _notifyEffectiveConfigListeners();
  }

  /// 源级覆盖（[SourceNetworkOverrideStore]）变更后调用：
  /// 清 DNS 缓存，使该源的新档案即时生效。
  void onSourceOverrideChanged() {
    DnsResolver.instance.clearCache();
    notifyListeners();
    _notifyEffectiveConfigListeners();
  }

  /// 有效档案变更后的附加回调。
  ///
  /// 供「需要跟随全局 / 源级网络配置变化，但不属于本层抽象」的子系统订阅。
  /// 用回调而不是让本层直接引用具体实现，避免 network 层反向依赖业务实现。
  final List<void Function()> _effectiveConfigListeners = <void Function()>[];

  /// 注册有效档案变更回调（本层不去重，幂等由调用方保证）。
  void addEffectiveConfigListener(void Function() listener) {
    _effectiveConfigListeners.add(listener);
  }

  void _notifyEffectiveConfigListeners() {
    for (final listener in _effectiveConfigListeners) {
      try {
        listener();
      } on Object catch (e) {
        // 单个订阅者异常不得影响其余订阅者：配置本身已经落盘。
        debugPrint('NetworkConfigService listener failed: $e');
      }
    }
  }

  /// 计算某源的有效档案：sourceId==null → 全局；否则逐方面合并覆盖。
  ///
  /// 魔蚁改编：原文入参是 NexHub 的 PluginConfig（取其 id 与 network 块）；
  /// 魔蚁无该模型，改为 sourceId + [fileOverride]（源文件自带的 network 块，
  /// 有则传，无则不传），合并语义不变。
  EffectiveNetworkProfile effectiveFor(
    String? sourceId, {
    SourceNetworkConfig? fileOverride,
  }) {
    if (sourceId == null) return globalProfile;
    final userOverride = SourceNetworkOverrideStore.instance.get(sourceId);
    final merged = _mergeOverrides(userOverride, fileOverride);
    if (merged == null || merged.isEmpty) return globalProfile;
    return EffectiveNetworkProfile.fromConfig(_config, override: merged);
  }

  /// 逐方面合并两个覆盖：用户覆盖某方面非 null 则优先，否则用源文件方面。
  SourceNetworkConfig? _mergeOverrides(
    SourceNetworkConfig? user,
    SourceNetworkConfig? file,
  ) {
    if (user == null) return file;
    if (file == null) return user;
    return SourceNetworkConfig(
      proxy: user.proxy ?? file.proxy,
      dns: user.dns ?? file.dns,
      hosts: user.hosts ?? file.hosts,
      sni: user.sni ?? file.sni,
      ech: user.ech ?? file.ech,
    );
  }

  // ---- 测试方法（供 UI 探测） ----

  /// 测试代理连通性：经给定配置构建的 client 请求探测 URL。
  /// 返回 (成功, 延迟ms)。
  Future<(bool, int)> testProxy(
    NetworkConfig config, {
    String? password,
    String probeUrl = 'https://www.gstatic.com/generate_204',
  }) async {
    final profile = EffectiveNetworkProfile.fromConfig(config);
    final client = NetworkClientBuilder.buildHttpClient(
      profile,
      proxyPassword: password ?? _proxyPassword,
    );
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(probeUrl))
          .timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      await resp.drain<void>();
      sw.stop();
      final ok = resp.statusCode >= 200 && resp.statusCode < 400;
      return (ok, sw.elapsedMilliseconds);
    } on Object catch (e) {
      debugPrint('NetworkConfigService.testProxy failed: $e');
      sw.stop();
      return (false, sw.elapsedMilliseconds);
    } finally {
      client.close(force: true);
    }
  }

  /// 测试 DNS 解析：返回 (解析到的 IP 列表, 耗时ms)。
  Future<(List<String>, int)> testDns(
    String host,
    DnsConfig cfg,
    List<HostsEntry> hosts,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final addrs = await DnsResolver.instance.resolve(host, cfg, hosts);
      sw.stop();
      return (addrs.map((a) => a.address).toList(), sw.elapsedMilliseconds);
    } on Object catch (e) {
      debugPrint('NetworkConfigService.testDns failed: $e');
      sw.stop();
      return (<String>[], sw.elapsedMilliseconds);
    }
  }

  /// 测试 DoH 端点：对样例域名经 DoH 解析。返回 (成功, 延迟ms)。
  Future<(bool, int)> testDoh(
    String dohUrl, {
    String sampleHost = 'www.cloudflare.com',
  }) async {
    final cfg = DnsConfig(
      mode: DnsMode.doh,
      dohUrl: dohUrl,
      cacheEnabled: false,
    );
    final (ips, ms) = await testDns(sampleHost, cfg, const <HostsEntry>[]);
    return (ips.isNotEmpty, ms);
  }

  /// 测试 SNI 握手：按档案 DNS/Hosts 定向 TCP，并按 [SniPolicy] 完成真实 TLS
  /// 握手（覆盖 / 免 SNI / 正常三种形态与运行时一致）。
  /// [override] 为源级覆盖（与 [effectiveFor] 同一合并语义）。
  /// 返回 (成功, 延迟ms, 实际使用的 TLS 名；免 SNI 为 `-`)。
  Future<(bool, int, String)> testSni(
    String host,
    NetworkConfig config, {
    SourceNetworkConfig? override,
  }) async {
    final profile = EffectiveNetworkProfile.fromConfig(
      config,
      override: override,
    );
    final sni = SniPolicy.resolve(profile.sni, host);
    String tlsName = sni ?? host;
    final sw = Stopwatch()..start();
    try {
      final addresses =
          await DnsResolver.instance.resolve(host, profile.dns, profile.hosts);
      if (addresses.isEmpty) {
        return (false, sw.elapsedMilliseconds, tlsName);
      }
      final socket = await Socket.connect(
        addresses.first,
        443,
        timeout: const Duration(seconds: 8),
      );
      try {
        tlsName = switch (sni) {
          null => host,
          '' => socket.remoteAddress.host,
          _ => sni,
        };
        await SecureSocket.secure(
          socket,
          host: tlsName,
          onBadCertificate: (_) => true,
        );
        sw.stop();
        return (
          true,
          sw.elapsedMilliseconds,
          sni == '' ? SniPolicy.noSniToken : tlsName,
        );
      } finally {
        socket.destroy();
      }
    } on Object catch (e) {
      debugPrint('NetworkConfigService.testSni($host) failed: $e');
      sw.stop();
      return (false, sw.elapsedMilliseconds, tlsName);
    }
  }
}
