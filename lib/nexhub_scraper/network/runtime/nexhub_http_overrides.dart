// 移植自 NexHub（https://github.com/nexhub-app/NexHub，提交 37ddbdd，Apache-2.0）。
// 原始路径：lib/core/network/runtime/nexhub_http_overrides.dart。移植状态：原文复制（仅加本出处注），逻辑未改。
// 魔蚁改编（2026-11-18，DNS 设置）：默认档案直通。档案不需要自定义连接
// （系统 DNS + 无 Hosts + SNI 未启用，见 needsCustomConnection）时，返回不带
// 任何改动的裸 HttpClient——构建器的 badCertificateCallback=true 与代理改写
// 只在用户真配了 DNS/Hosts/SNI 后才介入，默认状态下网络行为与装覆盖前
// 完全一致。
/// 全局 HttpOverrides：覆盖所有 `dart:io HttpClient` 派生流量
/// （散落的独立 Dio/HttpClient、cached_network_image、下载器、云同步等）。
///
/// 安装点：main.dart 于 `WidgetsFlutterBinding.ensureInitialized()` 后立即
/// `HttpOverrides.global = NexHubHttpOverrides()`；真实配置在 splash 加载后
/// 即时可用。
library;

import 'dart:io';

import '../network_config_service.dart';
import 'network_client_builder.dart';

/// NexHub 全局网络覆盖。
class NexHubHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final service = NetworkConfigService.instance;
    final profile = service.globalProfile;
    if (!profile.needsCustomConnection) {
      // 默认档案：裸客户端直通，不改证书校验、不改代理决策。
      // 经空覆盖 zone 建，避免再次命中全局覆盖造成递归。
      return HttpOverrides.runWithHttpOverrides<HttpClient>(
        () => HttpClient(context: context),
        _PassthroughHttpOverrides(),
      );
    }
    return NetworkClientBuilder.buildHttpClient(
      profile,
      ctx: context,
      proxyPassword: service.proxyPassword,
    );
  }
}

/// 空覆盖：`createHttpClient` 沿用基类实现（直接创建真实客户端），
/// 供默认档案直通时在 zone 内临时替换全局覆盖，避免递归。
class _PassthroughHttpOverrides extends HttpOverrides {}
